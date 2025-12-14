#!/bin/bash
set -euo pipefail

# Create S3 bucket
awslocal s3 mb s3://task-images

# Create SNS topic and SQS queue, then subscribe queue to topic
TOPIC_ARN=$(awslocal sns create-topic --name task-events --query 'TopicArn' --output text)
awslocal sqs create-queue --queue-name task-queue
QUEUE_URL=$(awslocal sqs get-queue-url --queue-name task-queue --query 'QueueUrl' --output text)
QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
awslocal sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QUEUE_ARN"

# Create DynamoDB table
awslocal dynamodb create-table \
  --table-name Tasks \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

echo "LocalStack resources initialized: S3 bucket, SNS/SQS, DynamoDB"