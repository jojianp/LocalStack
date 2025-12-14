import express from 'express';
import dotenv from 'dotenv';
import multer from 'multer';
import AWS from 'aws-sdk';
import { v4 as uuidv4 } from 'uuid';

dotenv.config();

const app = express();
const port = process.env.PORT || 3001;

app.use(express.json({ limit: '10mb' }));

const storage = multer.memoryStorage();
const upload = multer({ storage });

const awsConfig = {
  accessKeyId: process.env.AWS_ACCESS_KEY_ID || 'test',
  secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || 'test',
  region: process.env.AWS_REGION || 'us-east-1',
  s3ForcePathStyle: true,
  endpoint: process.env.AWS_ENDPOINT || 'http://localhost:4566'
};

AWS.config.update(awsConfig);
const s3 = new AWS.S3(awsConfig);
const dynamodb = new AWS.DynamoDB.DocumentClient({ service: new AWS.DynamoDB(awsConfig) });
const sns = new AWS.SNS(awsConfig);

const BUCKET = process.env.S3_BUCKET || 'task-images';
const TABLE = process.env.DYNAMO_TABLE || 'Tasks';
const TOPIC_ARN = process.env.SNS_TOPIC_ARN || 'arn:aws:sns:us-east-1:000000000000:task-events';

app.get('/health', (_req, res) => res.json({ ok: true }));

const tasks = new Map();

app.post('/tasks', async (req, res) => {
  try {
    const payload = req.body || {};
    const id = String(payload.id ?? Date.now()); 
    const now = new Date().toISOString();
    const serverObj = { ...payload, id, createdAt: payload.createdAt || now, updatedAt: payload.updatedAt || null };
    tasks.set(id, serverObj);
    await dynamodb.put({ TableName: TABLE, Item: serverObj }).promise();
    res.json(serverObj);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'Failed to create task', detail: String(e) });
  }
});

app.get('/tasks/:id', async (req, res) => {
  const id = String(req.params.id);
  const obj = tasks.get(id);
  if (!obj) return res.status(404).json({ error: 'Not found' });
  res.json(obj);
});

app.put('/tasks/:id', async (req, res) => {
  try {
    const id = String(req.params.id);
    const payload = req.body || {};
    const now = new Date().toISOString();
    const prev = tasks.get(id) || {};
    const merged = { ...prev, ...payload, id, updatedAt: now };
    tasks.set(id, merged);
    await dynamodb.put({ TableName: TABLE, Item: merged }).promise();
    res.json(merged);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'Failed to update task' });
  }
});


app.post('/upload', upload.single('file'), async (req, res) => {
  try {
    const file = req.file;
    if (!file) return res.status(400).json({ error: 'Missing file' });
    const id = uuidv4();
    const key = `${id}.jpg`;

    await s3.putObject({
      Bucket: BUCKET,
      Key: key,
      Body: file.buffer,
      ContentType: file.mimetype
    }).promise();

    res.json({ id, key, bucket: BUCKET });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Upload failed', detail: String(err) });
  }
});

// Upload via base64 JSON 
app.post('/upload-base64', async (req, res) => {
  try {
    const { data, title } = req.body || {};
    if (!data) return res.status(400).json({ error: 'Missing base64 data' });

    const id = uuidv4();
    const key = `${id}.jpg`;

    const base64Data = data.split(',')[1] || data; 
    const buffer = Buffer.from(base64Data, 'base64');

    await s3.putObject({
      Bucket: BUCKET,
      Key: key,
      Body: buffer,
      ContentType: 'image/jpeg'
    }).promise();

    // Only return image metadata
    res.json({ id, key, bucket: BUCKET });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Upload failed', detail: String(err) });
  }
});

// Delete task and associated image
app.delete('/tasks/:id', async (req, res) => {
  try {
    const id = String(req.params.id);
    const obj = tasks.get(id);
    if (!obj) return res.status(404).json({ error: 'Not found' });

    // Delete image from S3 
    if (obj.imageKey) {
      try {
        await s3.deleteObject({
          Bucket: BUCKET,
          Key: obj.imageKey
        }).promise();
        console.log(`Deleted image ${obj.imageKey} from S3`);
      } catch (e) {
        console.warn(`Failed to delete image ${obj.imageKey}:`, e);
      }
    }

    // Delete dynamo
    await dynamodb.delete({ TableName: TABLE, Key: { id } }).promise();
    tasks.delete(id);

    res.json({ success: true, id });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'Failed to delete task', detail: String(e) });
  }
});

app.listen(port, () => {
  console.log(`Backend listening on http://localhost:${port}`);
});
