import AWS from 'aws-sdk';
import dotenv from 'dotenv';

dotenv.config();

const config = {
  accessKeyId: process.env.AWS_ACCESS_KEY_ID || 'test',
  secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || 'test',
  region: process.env.AWS_REGION || 'us-east-1',
  s3ForcePathStyle: true,
  endpoint: process.env.AWS_ENDPOINT || 'http://localhost:4566'
};

AWS.config.update(config);
const s3 = new AWS.S3(config);
const dynamodb = new AWS.DynamoDB(config);
const sns = new AWS.SNS(config);
const sqs = new AWS.SQS(config);

const BUCKET = process.env.S3_BUCKET || 'task-images';
const TABLE = process.env.DYNAMO_TABLE || 'Tasks';
const TOPIC_NAME = 'task-events';
const QUEUE_NAME = 'task-queue';

async function ensureResources() {
  try {
    // S3
    const buckets = await s3.listBuckets().promise();
    const exists = buckets.Buckets?.some(b => b.Name === BUCKET);
    if (!exists) {
      await s3.createBucket({ Bucket: BUCKET }).promise();
      console.log('Created bucket', BUCKET);
    } else {
      console.log('Bucket exists', BUCKET);
    }

    // DynamoDB
    const tables = await dynamodb.listTables().promise();
    if (!tables.TableNames.includes(TABLE)) {
      await dynamodb.createTable({
        TableName: TABLE,
        BillingMode: 'PAY_PER_REQUEST',
        AttributeDefinitions: [{ AttributeName: 'id', AttributeType: 'S' }],
        KeySchema: [{ AttributeName: 'id', KeyType: 'HASH' }]
      }).promise();
      console.log('Created table', TABLE);
    } else {
      console.log('Table exists', TABLE);
    }

    // SNS topic
    const topicArn = await sns.createTopic({ Name: TOPIC_NAME }).promise().then(r => r.TopicArn);
    console.log('SNS topic', topicArn);

    // SQS queue
    const queueUrl = await sqs.createQueue({ QueueName: QUEUE_NAME }).promise().then(r => r.QueueUrl);
    const queueArn = await sqs.getQueueAttributes({ QueueUrl: queueUrl, AttributeNames: ['QueueArn'] }).promise().then(r => r.Attributes.QueueArn);
    // subscribe
    await sns.subscribe({ TopicArn: topicArn, Protocol: 'sqs', Endpoint: queueArn }).promise();
    console.log('Subscribed SQS to SNS');

    console.log('Bootstrap completed');
  } catch (e) {
    console.error('Bootstrap error:', e);
    process.exitCode = 1;
  }
}

ensureResources();
