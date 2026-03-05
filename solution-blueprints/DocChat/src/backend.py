# Copyright © Advanced Micro Devices, Inc., or its affiliates.
#
# SPDX-License-Identifier: MIT

import logging
import mimetypes
import os
import urllib.parse
from typing import Dict, List, Optional, Tuple

import boto3
import config
import requests
from botocore.exceptions import BotoCoreError, ClientError
from langchain.embeddings.base import Embeddings
from langchain_community.document_loaders import PyMuPDFLoader, TextLoader
from langchain_qdrant import QdrantVectorStore
from langchain_text_splitters import RecursiveCharacterTextSplitter
from qdrant_client import QdrantClient, models

logger = logging.getLogger(__name__)


# Embedding Service Logic
class CustomEmbeddings(Embeddings):
    def embed_query(self, text: str) -> List[float]:
        payload = {"model": config.EMBED_MODEL, "input": [text]}
        try:
            logger.info(f"Sending embedding request to {config.INFINITY_EMBEDDING_URL}")
            resp = requests.post(config.INFINITY_EMBEDDING_URL, json=payload, timeout=30)
            resp.raise_for_status()
            logger.info("Embedding request successful")
            return resp.json()["data"][0]["embedding"]
        except Exception as e:
            logger.error(f"Embedding failed: {e}", exc_info=True)
            raise

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        return [self.embed_query(t) for t in texts]


# Knowledge Base Logic
class KnowledgeBase:
    def __init__(self):
        self._client = None
        self._s3_client = None
        self._bucket_ready = False
        self.vector_store = None
        self.collection_name = "rag_collection"

    @property
    def client(self):
        if not self._client:
            if config.QDRANT_URL:
                parsed = urllib.parse.urlparse(config.QDRANT_URL)
                host = parsed.hostname or "localhost"
                port = parsed.port or (443 if parsed.scheme == "https" else 80)
                self._client = QdrantClient(host=host, port=port, https=(parsed.scheme == "https"))
            else:
                self._client = QdrantClient(host=config.QDRANT_HOST, port=config.QDRANT_PORT)
        return self._client

    @property
    def s3_client(self):
        if not config.MINIO_ENABLED:
            return None
        if self._s3_client is None:
            if not (config.MINIO_ENDPOINT and config.MINIO_ACCESS_KEY and config.MINIO_SECRET_KEY and config.MINIO_BUCKET):
                logger.warning("MinIO is enabled but missing endpoint/credentials/bucket configuration.")
                return None
            self._s3_client = boto3.client(
                "s3",
                endpoint_url=config.MINIO_ENDPOINT,
                aws_access_key_id=config.MINIO_ACCESS_KEY,
                aws_secret_access_key=config.MINIO_SECRET_KEY,
                region_name=config.MINIO_REGION,
            )
        return self._s3_client

    def _ensure_bucket(self):
        if self._bucket_ready or self.s3_client is None:
            return
        try:
            self.s3_client.head_bucket(Bucket=config.MINIO_BUCKET)
        except ClientError:
            self.s3_client.create_bucket(Bucket=config.MINIO_BUCKET)
        self._bucket_ready = True

    def _upload_source_to_minio(self, file_path: str) -> str:
        if self.s3_client is None:
            return file_path
        self._ensure_bucket()
        filename = os.path.basename(file_path)
        object_key = f"{config.MINIO_PREFIX.strip('/')}/{filename}".lstrip("/")
        guessed_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        with open(file_path, "rb") as f:
            self.s3_client.put_object(
                Bucket=config.MINIO_BUCKET,
                Key=object_key,
                Body=f,
                ContentType=guessed_type,
            )
        return f"s3://{config.MINIO_BUCKET}/{object_key}"

    def build(self, file_paths: List[str]):
        """Process files and upload to Qdrant"""
        self.clear()  # Reset before build
        all_docs = []
        for path in file_paths:
            source_ref = path
            if config.MINIO_ENABLED:
                try:
                    source_ref = self._upload_source_to_minio(path)
                except (OSError, ClientError, BotoCoreError) as e:
                    logger.error(f"Failed to upload '{path}' to MinIO: {e}", exc_info=True)
            if path.endswith(".pdf"):
                docs = PyMuPDFLoader(path).load()
                for d in docs:
                    d.metadata = dict(d.metadata or {})
                    d.metadata["source"] = source_ref
                    d.metadata["source_name"] = os.path.basename(path)
                all_docs.extend(docs)
            elif path.endswith(".txt"):
                docs = TextLoader(path).load()
                for d in docs:
                    d.metadata = dict(d.metadata or {})
                    d.metadata["source"] = source_ref
                    d.metadata["source_name"] = os.path.basename(path)
                all_docs.extend(docs)

        splitter = RecursiveCharacterTextSplitter(chunk_size=config.CHUNK_SIZE, chunk_overlap=config.CHUNK_OVERLAP)
        chunks = splitter.split_documents(all_docs)

        if chunks:
            logger.info(f"Embedding {len(chunks)} chunks...")
            embeddings = CustomEmbeddings()
            vector_size = len(embeddings.embed_query(chunks[0].page_content))
            self.client.create_collection(
                collection_name=self.collection_name,
                vectors_config=models.VectorParams(size=vector_size, distance=models.Distance.COSINE),
            )
            self.vector_store = QdrantVectorStore(
                client=self.client,
                collection_name=self.collection_name,
                embedding=embeddings,
            )
            self.vector_store.add_documents(chunks)
            logger.info("Build complete.")
            return f"Processed {len(chunks)} chunks."
        return "No text found."

    def retrieve(self, query: str, k: int = 5) -> str:
        """Returns formatted string of context"""
        safe_query = query.replace("\r", "").replace("\n", "")
        logger.info(f"Retrieving documents for query: {safe_query}")
        if not self.vector_store:
            try:
                self.vector_store = QdrantVectorStore(
                    client=self.client,
                    collection_name=self.collection_name,
                    embedding=CustomEmbeddings(),
                )
            except Exception:
                logger.error("Could not reconnect to Qdrant.", exc_info=True)

        if self.vector_store is None:
            logger.warning("Vector store is None, returning empty result.")
            return "No documents uploaded. Please upload a document first."

        logger.info("Invoking retriever...")
        docs = self.vector_store.as_retriever(search_kwargs={"k": k}).invoke(query)
        logger.info(f"Retrieved {len(docs)} documents.")
        return "\n\n---\n\n".join([d.page_content for d in docs])

    def clear(self):
        try:
            self.client.delete_collection(collection_name=self.collection_name)
            self.vector_store = None
        except Exception as e:
            # Qdrant returns an error when the collection does not exist.
            if "doesn't exist" in str(e).lower() or "not found" in str(e).lower():
                logger.warning(f"Collection '{self.collection_name}' not found for deletion, skipping.")
                return
            logger.error(f"Failed to clear collection '{self.collection_name}': {e}", exc_info=True)

    def _document_sources(self) -> Dict[str, str]:
        """Return basename -> source path map for indexed documents."""
        try:
            self.client.get_collection(self.collection_name)
        except Exception as e:
            if "doesn't exist" in str(e).lower() or "not found" in str(e).lower():
                return {}
            logger.error(f"Failed to inspect collection '{self.collection_name}': {e}", exc_info=True)
            return {}

        docs: Dict[str, str] = {}
        offset = None

        while True:
            points, next_offset = self.client.scroll(
                collection_name=self.collection_name,
                offset=offset,
                limit=256,
                with_payload=True,
                with_vectors=False,
            )
            for point in points:
                payload = point.payload or {}
                source = ""
                source_name = ""
                metadata = payload.get("metadata")
                if isinstance(metadata, dict):
                    source = str(metadata.get("source") or "")
                    source_name = str(metadata.get("source_name") or "")
                if not source:
                    source = str(payload.get("source") or "")
                if source:
                    basename = source_name or os.path.basename(source)
                    if basename and basename not in docs:
                        docs[basename] = source

            if next_offset is None:
                break
            offset = next_offset

        return docs

    def list_documents(self) -> List[str]:
        """Return unique source filenames currently indexed in Qdrant."""
        return sorted(self._document_sources().keys())

    def get_document_source(self, document_name: str) -> Optional[str]:
        """Return source path in pod storage for a given indexed document name."""
        clean_name = os.path.basename(document_name)
        if not clean_name:
            return None
        return self._document_sources().get(clean_name)

    def _split_s3_source(self, source: str) -> Optional[Tuple[str, str]]:
        if not source.startswith("s3://"):
            return None
        parsed = urllib.parse.urlparse(source)
        bucket = parsed.netloc
        key = parsed.path.lstrip("/")
        if not bucket or not key:
            return None
        return bucket, key

    def get_document_bytes(self, document_name: str) -> Optional[bytes]:
        """Return raw document bytes from local storage or MinIO."""
        source = self.get_document_source(document_name)
        if not source:
            return None
        s3_ref = self._split_s3_source(source)
        if s3_ref:
            if self.s3_client is None:
                return None
            bucket, key = s3_ref
            try:
                obj = self.s3_client.get_object(Bucket=bucket, Key=key)
                return obj["Body"].read()
            except (ClientError, BotoCoreError) as e:
                logger.error(f"Failed to fetch '{source}' from MinIO: {e}", exc_info=True)
                return None

        if not os.path.isfile(source):
            return None
        try:
            with open(source, "rb") as f:
                return f.read()
        except Exception as e:
            logger.error(f"Failed to read document '{document_name}': {e}", exc_info=True)
            return None

    def read_text_document(self, document_name: str, max_chars: int = 12000) -> str:
        """Return a bounded text preview for an indexed .txt document."""
        if not document_name.lower().endswith(".txt"):
            return ""
        raw = self.get_document_bytes(document_name)
        if raw is None:
            return ""
        return raw.decode("utf-8", errors="replace")[:max_chars]
