provider "aws" {
  region = "us-east-1"
  alias = "AccountB"
  profile = "Account_B"
}

resource "aws_sqs_queue" "ServerB" {
  provider = aws.AccountB
  name     = "ServerB"
}

resource "aws_sns_topic_subscription" "sqs_subscription" {
  provider = aws.AccountB
  topic_arn = "arn:aws:sns:us-east-1:394953618631:ServerA"
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.ServerB.arn
}


resource "aws_sqs_queue_policy" "sqs_policy" {
  provider = aws.AccountB
  queue_url = aws_sqs_queue.ServerB.id

  policy = jsonencode({
    Version = "2012-10-17",
    "Id": "test",
    Statement = [
      {
        Effect    = "Allow",
        Principal = "*",
        Action    = "sqs:SendMessage",
        Resource  = aws_sqs_queue.ServerB.arn,
        Condition = {
          ArnEquals = {
            "aws:SourceArn": "arn:aws:sns:us-east-1:394953618631:ServerA"
          }
        }
      }
    ],
  })
}

resource "aws_key_pair" "login1" {
  provider = aws.AccountB
  key_name   = "login1"
  public_key = file("C:/Users/vithalraddi/.ssh/id_rsa.pub")
}

resource "aws_instance" "server_b" {
  provider = aws.AccountB
  ami           = "ami-0d191299f2822b1fa"
  instance_type = "t2.micro"
  iam_instance_profile = aws_iam_instance_profile.ec2_role.name
  key_name = aws_key_pair.login1.key_name
  vpc_security_group_ids = [aws_security_group.ssh1.id]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y python3
              pip3 install boto3

              cat << 'EOP' > /home/ec2-user/process_message.py
              import boto3
              import os
              from datetime import datetime

              s3_client = boto3.client('s3', region_name='us-east-1')
              sqs_client = boto3.client('sqs', region_name='us-east-1')

              QUEUE_URL = '$(aws_sqs_queue.ServerB.id)'
              BUCKET_NAME = 'sns-sqs-vk'

              def process_messages():
                  messages = sqs_client.receive_message(
                      QueueUrl=QUEUE_URL,
                      MaxNumberOfMessages=10,
                      WaitTimeSeconds=10
                  ).get('Messages', [])

                  for message in messages:
                      body = message['Body']
                      timestamp = body.split(' at ')[-1]
                      filename = f"{timestamp}-message.log"
                      with open(filename, 'w') as file:
                          file.write(body)
                      
                      s3_client.upload_file(filename, BUCKET_NAME, filename)
                      os.remove(filename)
                      sqs_client.delete_message(
                          QueueUrl=QUEUE_URL,
                          ReceiptHandle=message['ReceiptHandle']
                      )

              if __name__ == "__main__":
                  process_messages()
              EOP

              chown ec2-user:ec2-user /home/ec2-user/process_message.py
              chmod +x /home/ec2-user/process_message.py

              (crontab -l 2>/dev/null; echo "* * * * * /usr/bin/python3 /home/ec2-user/process_message.py") | crontab -
              EOF

  tags = {
    Name = "ServerB"
  }
}

resource "aws_security_group" "ssh1" {
  provider = aws.AccountB
  name_prefix = "allow_ssh"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" 
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ec2_role" {
  provider = aws.AccountB
  name     = "ec2_process_sqs_s3_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com",
      },
    }],
  })
}

resource "aws_iam_role_policy" "ec2_role_policy" {
  provider = aws.AccountB
  name     = "ec2_process_sqs_s3_policy"
  role     = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ],
        Resource = aws_sqs_queue.ServerB.arn,
      },
      {
        Effect   = "Allow",
        Action   = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:List*"
        ],
        Resource = "arn:aws:s3:::sns-sqs-vk/*",
      },
    ],
  })
}

resource "aws_iam_instance_profile" "ec2_role" {
  provider = aws.AccountB
  name     = "ec2_role"
  role     = aws_iam_role.ec2_role.name
}
