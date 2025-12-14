# recursos_nativos

Projeto Flutter com câmera, sensores, geolocalização, persistência local (SQLite) e sincronização.

## Simulação de Cloud com LocalStack

Simula serviços AWS (S3, SQS/SNS, DynamoDB) com LocalStack e um backend Node.js para upload e registro de tarefas.

### Estrutura
- `docker-compose.yml`: container `localstack-task-manager` com serviços S3, SQS, SNS e DynamoDB.
- `localstack/01-init.sh`: cria `task-images` (S3), `task-events` (SNS), `task-queue` (SQS), `Tasks` (DynamoDB).
- `backend/`: API Node.js com `POST /upload`, `POST /upload-base64`, `POST /tasks`, `GET /tasks/:id`, `PUT /tasks/:id`.

### Executar
1. Subir LocalStack:
	```bash
	docker-compose up -d
	```
2. Backend:
	```bash
	cd backend
	npm install
	npm run deploy
	npm start
	```

### Verificar
```bash
docker exec localstack-task-manager awslocal s3 ls
docker exec localstack-task-manager awslocal s3 ls s3://task-images/
docker exec localstack-task-manager awslocal dynamodb scan --table-name Tasks --output json
```