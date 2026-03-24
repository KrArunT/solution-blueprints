# Major Changes in DocChat Compared to talk-to-your-documents

This document summarizes the major changes introduced in `DocChat` relative to `talk-to-your-documents`.

## Summary

`DocChat` keeps the same overall RAG pattern as the original app: a FastAPI + Gradio frontend/backend, an embedding service, and an LLM used to answer questions over uploaded documents. The main changes are in the storage layer, document handling, deployment model, and operational tooling.

## 1. Vector Database Changed from ChromaDB to Qdrant

The largest architectural change is the replacement of **ChromaDB** with **Qdrant**.

- `talk-to-your-documents` used `chromadb` and `langchain-chroma`.
- `DocChat` uses `qdrant-client` and `langchain-qdrant`.
- Runtime configuration changed from `CHROMADB_URL/HOST/PORT` to `QDRANT_URL/HOST/PORT`.
- Helm chart dependencies were updated to remove the ChromaDB subchart, and `DocChat` now defines its own Qdrant deployment templates.

Why this matters:

- Qdrant is now the default vector store for indexing and retrieval.
- The chart can target either a bundled in-cluster Qdrant instance or an external Qdrant endpoint.
- Qdrant is treated as a first-class deployment component rather than just a drop-in backend swap.

## 2. Document Sources Are Tracked and Exposed

`DocChat` adds explicit tracking of indexed document sources.

- During indexing, document metadata now stores both `source` and `source_name`.
- The backend can enumerate indexed documents from Qdrant.
- The app can resolve a document name back to its stored source.
- New API routes were added:
  - `GET /documents`
  - `GET /documents/{document_name}`

Why this matters:

- The original app focused on upload-and-ask behavior only.
- `DocChat` adds a document inventory layer on top of retrieval.
- Indexed files are now discoverable and can be fetched back through the app.

## 3. UI Adds Indexed Document Browsing and Preview

The Gradio UI is extended beyond simple upload + question answering.

- A dropdown lists indexed documents already known to the system.
- A refresh action reloads the indexed document list.
- The UI shows selected-document status.
- PDF files can be previewed inline in an iframe.
- Text files can be previewed inline in a formatted text block.
- Clearing the app now resets document-selection state as well as question/answer state.

Why this matters:

- `DocChat` behaves more like a document workspace than a one-shot upload form.
- Users can inspect what has already been indexed before asking questions.
- The app now supports a lightweight review workflow for stored source files.

## 4. Optional Source Storage via MinIO / S3

`DocChat` introduces optional object-storage support for original source documents.

- New config keys exist for `MINIO_ENABLED`, endpoint, credentials, bucket, region, and prefix.
- When enabled, uploaded source files can be copied into MinIO/S3-compatible storage before indexing.
- Document fetch operations can read back file contents either from local pod storage or from MinIO.

Why this matters:

- The original app only indexed local files for retrieval.
- `DocChat` adds a path toward durable source-file management, not just vector storage.
- This makes document preview/download features possible even when the app pod is not the long-term source of truth.

## 5. Deployment Workflow Became Much More Operationally Focused

`DocChat` significantly expands deployment and bootstrap automation.

- New scripts were added:
  - `deploy.sh`
  - `cleanup_redeploy.sh`
  - `clean.sh`
  - `run.sh`
  - `generate_configure_tls_cert.sh`
- The deployment flow now supports:
  - syncing documents from an ONTAP FlexCache mount over SSH/`rsync`
  - copying staged documents into the app pod
  - automatically calling the app’s `/process` API to pre-index those documents
  - optional local model-cache host mounts
  - automatic namespace and Hugging Face secret setup

Why this matters:

- The original blueprint was a relatively simple Helm deployment.
- `DocChat` is closer to an end-to-end deploy-and-bootstrap system.
- The app is designed for preloaded enterprise document sources, not just manual uploads from the browser.

## 6. Helm Chart Was Reworked for Enterprise Routing and Service Control

The Kubernetes packaging is more elaborate in `DocChat`.

- `service` settings are now configurable in `values.yaml` instead of fixed.
- A new `HTTPRoute` exposes the app through Gateway API.
- A separate `qdrant-httproute.yaml` can expose Qdrant through the gateway when needed.
- `qdrant.yaml` adds bundled Qdrant `Service`, `Deployment`, and `PersistentVolumeClaim`.
- Init-container readiness checks were changed to wait for Qdrant instead of ChromaDB.
- Values were added for external Qdrant usage, fallback Qdrant behavior, and gateway hostnames.

Why this matters:

- `DocChat` is built for a more production-style Kubernetes environment.
- External access is now part of the default design through `kgateway`/Gateway API.
- Storage and service exposure are more configurable than in the original app.

## 7. LLM Packaging and Runtime Configuration Were Expanded

`DocChat` also makes LLM deployment more flexible.

- The chart now points to a local `charts/aimchart-llm-local` dependency instead of the previous OCI LLM chart reference.
- New values support GPU count overrides and local model-cache mounts.
- `GEN_MODEL` is explicitly configurable in `values.yaml`.
- `EMBED_MODEL` and `GEN_MODEL` can now be overridden directly from environment variables instead of always being discovered dynamically at startup.

Why this matters:

- The modified app is easier to tune for specific hardware and model-cache layouts.
- It is better suited for controlled deployments where model identity is known ahead of time.

## 8. Documentation Was Expanded from Basic Helm Notes to Full Deployment Guides

`DocChat` adds much more operational documentation.

- New documents describe architecture and deployment end-to-end.
- The old short Helm deployment notes were replaced by a canonical deployment guide.
- A build guide was added for AMD AIMs, Qdrant, FlexCache, SSH setup, TLS, and verification.
- New diagrams and Mermaid sources were added for architecture/deployment flow.

Why this matters:

- `DocChat` is documented as a full solution deployment, not just a reusable sample chart.
- The documentation reflects real infrastructure assumptions and bootstrap steps.

## Overall Assessment

Compared to `talk-to-your-documents`, `DocChat` is not just a rename or a small customization. It is a more opinionated enterprise-oriented variant with:

- a new vector database stack based on Qdrant
- document catalog and preview capabilities
- optional object storage for source files
- stronger Kubernetes routing and persistence support
- deployment automation for FlexCache-based document ingestion
- more explicit model and infrastructure configuration

In short, `talk-to-your-documents` is a simpler RAG blueprint, while `DocChat` turns that blueprint into a more complete document-chat deployment platform.

## Appendix: Modified Files and Representative Excerpts

This appendix lists the files that differ between `talk-to-your-documents` and `DocChat`. Excerpts are representative snippets, not full diffs.

### Files Modified in Both Folders

#### `Chart.yaml`

Switches the stack from ChromaDB to Qdrant and replaces the remote LLM chart dependency with a local chart.

```diff
- repository: "oci://registry-1.docker.io/amdenterpriseai"
+ repository: "file://charts/aimchart-llm-local"
- name: aimchart-chromadb
+ com.amd.aim.description.full: "... uses a vector database (Qdrant) ..."
```

#### `README.md`

Moves from a minimal Helm example to script-driven deployment and indexing workflows.

```diff
- helm template $name . | kubectl apply -f -
+ ./deploy.sh \
+   --flex-docs-path /mnt/Flexcache_Site2 \
+   --gateway-host my-rag-app.45.63.79.40.nip.io \
+   --qdrant-url http://45.63.92.22:6333/
```

#### `docs/DEPLOYMENT.md`

Replaces the older short Helm deployment notes with a pointer to the new canonical deployment guide.

```diff
-- The recommended approach to deploy them is to pipe the output of `helm template` to `kubectl apply -f -`.
+- [ARCHITECTURE_AND_DEPLOYMENT.md](ARCHITECTURE_AND_DEPLOYMENT.md)
```

#### `docs/README.md`

Updates the docs landing page from a ChromaDB architecture page to a Qdrant + Gateway API architecture page.

```diff
-- **ChromaDB vector store**: A deployment with ChromaDB vector database ...
+- **Qdrant vector store**: A deployment with Qdrant vector database ...
+- **Gateway API route**: External routing via `kgateway` + `HTTPRoute` ...
```

#### `src/app.py`

Adds document listing, document fetch APIs, and UI for indexed-document browsing and preview.

```diff
+ @app.get("/documents")
+ async def api_documents():
+     ...
+
+ @app.get("/documents/{document_name:path}")
+ async def api_document_content(document_name: str):
+     ...
```

```diff
+ indexed_docs_dropdown = gr.Dropdown(...)
+ refresh_docs_btn = gr.Button("Refresh Documents", variant="secondary")
+ document_preview = gr.HTML("<p>Select a document to preview.</p>")
```

#### `src/backend.py`

Replaces ChromaDB with Qdrant and adds source tracking plus optional MinIO/S3-backed source storage.

```diff
- import chromadb
- from langchain_chroma import Chroma
+ import boto3
+ from langchain_qdrant import QdrantVectorStore
+ from qdrant_client import QdrantClient, models
```

```diff
- self.vector_store = Chroma.from_documents(...)
+ self.client.create_collection(...)
+ self.vector_store = QdrantVectorStore(...)
+ self.vector_store.add_documents(chunks)
```

```diff
+ def list_documents(self) -> List[str]:
+     return sorted(self._document_sources().keys())
+
+ def get_document_bytes(self, document_name: str) -> Optional[bytes]:
+     ...
```

#### `src/config.py`

Replaces Chroma config with Qdrant config and adds MinIO plus explicit model override support.

```diff
- CHROMADB_URL = os.getenv("CHROMADB_URL", "")
- CHROMADB_HOST = os.getenv("CHROMADB_HOST", "chromadb-store")
- CHROMADB_PORT = int(os.getenv("CHROMADB_PORT", "8000"))
+ QDRANT_URL = os.getenv("QDRANT_URL", "")
+ QDRANT_HOST = os.getenv("QDRANT_HOST", "qdrant")
+ QDRANT_PORT = int(os.getenv("QDRANT_PORT", "6333"))
```

```diff
+ MINIO_ENABLED = os.getenv("MINIO_ENABLED", "false").lower() in {"1", "true", "yes", "on"}
+ MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "")
+ MINIO_BUCKET = os.getenv("MINIO_BUCKET", "rag-docs")
```

```diff
- EMBED_MODEL = init_embed_model()
+ EMBED_MODEL = os.getenv("EMBED_MODEL", "").strip() or init_embed_model()
- GEN_MODEL = init_gen_model()
+ GEN_MODEL = os.getenv("GEN_MODEL", "").strip() or init_gen_model()
```

#### `src/requirements.txt`

Dependency set updated for Qdrant and MinIO support.

```diff
- chromadb==1.3.5
- langchain-chroma==1.0.0
+ boto3==1.40.31
+ langchain-qdrant==1.1.0
+ qdrant-client==1.15.1
```

#### `templates/_helpers.tpl`

Container env wiring now points to Qdrant instead of ChromaDB and adds Qdrant URL helpers.

```diff
-- name: CHROMADB_URL
-  value: {{ include "aim-chromadb.url" $sub | quote }}
+- name: QDRANT_URL
+  value: {{ include "aim-qdrant.url" . | quote }}
```

#### `templates/deployment.yaml`

Init container readiness checks were changed from ChromaDB to Qdrant.

```diff
- CHROMADB_URL="{{ include "aim-chromadb.url" $sub }}/api/v2/heartbeat"
- echo "Waiting for ChromaDB ($CHROMADB_URL)..."
+ QDRANT_URL="{{ include "aim-qdrant.url" . }}/readyz"
+ echo "Waiting for Qdrant ($QDRANT_URL)..."
```

#### `templates/service.yaml`

The app service became configurable instead of being hard-coded as `ClusterIP:80`.

```diff
-  type: ClusterIP
+  type: {{ .Values.service.type }}
-      port: 80
+      port: {{ .Values.service.port }}
```

#### `values.yaml`

Adds service settings, gateway routing, Qdrant, GPU/model-cache options, and explicit model defaults.

```diff
+ service:
+   type: ClusterIP
+   port: 80
+
+ gatewayRoute:
+   enabled: true
```

```diff
- chromadb:
+ qdrant:
+   image:
+     repository: "qdrant/qdrant"
+     tag: "v1.15.4"
```

```diff
+ llm:
+   gpus: 2
+   localModelCache:
+     enabled: false
```

### Files Added in `DocChat`

These files do not exist in `talk-to-your-documents` and were added as part of the `DocChat` variant.

#### Root-level additions

- `.env.example`
  - Example excerpt: `HF_TOKEN=""`
- `.gitignore`
  - Git ignore rules for local development artifacts.
- `.helmignore`
  - Helm packaging ignore rules.
- `BUILD-GUIDE.md`
  - Example excerpt: `# Build Guide: Deploy “Chat with Your Documents” on AMD Enterprise AI Platform (RAG + Qdrant + ONTAP FlexCache)`
- `clean.sh`
  - Cleanup helper for release resources.
- `cleanup_redeploy.sh`
  - Cleanup + redeploy wrapper around `deploy.sh`.
- `deploy.sh`
  - Automates namespace creation, Helm deployment, FlexCache sync, pod copy, and document indexing.
- `generate_configure_tls_cert.sh`
  - TLS helper for the gateway/nip.io setup.
- `run.sh`
  - Convenience wrapper for local deployment invocation.

#### Documentation additions

- `docs/ARCHITECTURE_AND_DEPLOYMENT.md`
  - Canonical architecture and end-to-end Kubernetes deployment guide.
- `docs/architecture-deployment.mmd`
  - Mermaid source for the updated deployment diagram.
- `docs/architecture-deployment.png`
  - Rendered architecture/deployment diagram.

#### Helm and runtime additions

- `charts/aimchart-llm-local/`
  - Local LLM chart used instead of the prior OCI chart reference.
- `profiles/vllm-mi325x-fp16-tp4-latency.yaml`
  - Hardware/runtime profile for LLM deployment.
- `templates/httproute.yaml`
  - Gateway API route for the app service.
- `templates/qdrant-httproute.yaml`
  - Optional Gateway API route for Qdrant.
- `templates/qdrant.yaml`
  - Bundled Qdrant `Service`, `Deployment`, and `PersistentVolumeClaim`.

### Quick Inventory From the Folder Diff

The following paths were reported as different between the two folders:

- `Chart.yaml`
- `README.md`
- `docs/DEPLOYMENT.md`
- `docs/README.md`
- `src/app.py`
- `src/backend.py`
- `src/config.py`
- `src/requirements.txt`
- `templates/_helpers.tpl`
- `templates/deployment.yaml`
- `templates/service.yaml`
- `values.yaml`
- `.env.example`
- `.gitignore`
- `.helmignore`
- `BUILD-GUIDE.md`
- `charts/`
- `clean.sh`
- `cleanup_redeploy.sh`
- `deploy.sh`
- `docs/ARCHITECTURE_AND_DEPLOYMENT.md`
- `docs/architecture-deployment.mmd`
- `docs/architecture-deployment.png`
- `generate_configure_tls_cert.sh`
- `profiles/`
- `run.sh`
- `templates/httproute.yaml`
- `templates/qdrant-httproute.yaml`
- `templates/qdrant.yaml`
