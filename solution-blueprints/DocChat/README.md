<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# Talk to your documents

This blueprint deploys a Retrieval-Augmented Generation (RAG) application which allows you to talk to your documents. It uses a vector database (Qdrant) to store document embeddings and a large language model (LLM) to answer questions based on the retrieved context.

## Deploying

Use the canonical guide for architecture and end-to-end Kubernetes deployment:

- [docs/ARCHITECTURE_AND_DEPLOYMENT.md](docs/ARCHITECTURE_AND_DEPLOYMENT.md)
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)

## Scripts And Examples

Run from this chart root directory.

### 1) Deploy + index from Flex mount

```bash
./deploy.sh \
  --flex-docs-path /mnt/Flexcache_Site2 \
  --gateway-host my-rag-app.45.63.79.40.nip.io \
  --qdrant-url http://45.63.92.22:6333/
```

Default LLM profile in `values.yaml` is now `llama-3-3-70b-instruct` with `llm.gpus=4`.

### 2) Deploy using fallback Qdrant service (in-cluster)

```bash
./deploy.sh \
  --flex-docs-path /mnt/Flexcache_Site2 \
  --gateway-host my-rag-app.45.63.79.40.nip.io \
  --qdrant-url http://my-rag-app-qdrant:6333
```

### 3) Clean + redeploy in one command

```bash
./cleanup_redeploy.sh \
  --flex-docs-path /mnt/Flexcache_Site2 -- \
  --gateway-host my-rag-app.45.63.79.40.nip.io \
  --qdrant-url http://45.63.92.22:6333/
```

### 4) Clean only (no redeploy)

```bash
./clean.sh
```

Optional namespace purge:

```bash
./clean.sh --purge-namespace
```

### 5) Deploy with MinIO sync in deploy.sh

```bash
./deploy.sh \
  --flex-docs-path /mnt/Flexcache_Site2 \
  --gateway-host my-rag-app.45.63.79.40.nip.io \
  --qdrant-url http://45.63.92.22:6333/ \
  --minio-endpoint https://my-rag-app-minio-api.45.63.79.40.nip.io \
  --minio-bucket rag-docs \
  --minio-access-key '<accesskey>' \
  --minio-secret-key '<secretkey>' \
  --minio-prefix rag
```

### 6) Deploy with generic local model-cache mount

```bash
./deploy.sh \
  --flex-docs-path /mnt/Flexcache_Site2 \
  --gateway-host my-rag-app.45.63.79.40.nip.io \
  --model-cache-path /path/to/model-cache
```

You can also select a different values file:

```bash
./deploy.sh --values-file values.yaml --flex-docs-path /mnt/Flexcache_Site2
```

### 7) MinIO console and API URLs

- Console: `https://my-rag-app-minio-console.45.63.79.40.nip.io`
- API: `https://my-rag-app-minio-api.45.63.79.40.nip.io`

### 8) App and Qdrant URLs

- App UI/API: `https://my-rag-app.45.63.79.40.nip.io`
- Documents API: `https://my-rag-app.45.63.79.40.nip.io/documents`
- Fallback Qdrant endpoint: `https://my-rag-app-qdrant.45.63.79.40.nip.io`
