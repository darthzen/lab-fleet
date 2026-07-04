#!/usr/bin/env python3
"""
index_k8s_docs.py

Index the Kubernetes documentation (kubernetes/website -> content/en/docs)
into Milvus, in a repeatable + updatable way.

Design for idempotent, incremental updates:
  - Deterministic chunk IDs (hash of filepath + chunk index) -> re-runs upsert
    the same rows instead of creating duplicates.
  - Per-file content hashing in a manifest -> only changed files are re-embedded
    and re-upserted on subsequent runs.
  - Deletion handling -> files removed upstream have their chunks deleted from
    Milvus, so the index doesn't accumulate stale content.

Embeddings: Ollama 'nomic-embed-text' (768-dim). MUST match the embedding model
used by the rest of the RAG stack, or query vectors won't be comparable.

Connections use in-cluster service DNS by default; override via env vars.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import requests
from pymilvus import MilvusClient, DataType

# ---------------------------------------------------------------------------
# Config (env-overridable)
# ---------------------------------------------------------------------------
REPO_URL        = os.getenv("REPO_URL", "https://github.com/kubernetes/website.git")
REPO_BRANCH     = os.getenv("REPO_BRANCH", "main")
DOCS_SUBPATH    = os.getenv("DOCS_SUBPATH", "content/en/docs")

OLLAMA_URL      = os.getenv("OLLAMA_URL", "http://ollama.ai.svc.cluster.local:11434")
MILVUS_URI      = os.getenv("MILVUS_URI", "http://milvus.ai.svc.cluster.local:19530")

EMBED_MODEL     = os.getenv("EMBED_MODEL", "nomic-embed-text")
EMBED_DIM       = int(os.getenv("EMBED_DIM", "768"))   # MUST match EMBED_MODEL output
COLLECTION      = os.getenv("COLLECTION", "k8s_docs")

# Working dirs. WORKDIR holds the clone; STATE_DIR holds the manifest (persist
# STATE_DIR on a PVC so change-detection survives across CronJob runs).
WORKDIR         = Path(os.getenv("WORKDIR", "/work"))
STATE_DIR       = Path(os.getenv("STATE_DIR", "/state"))
MANIFEST_PATH   = STATE_DIR / f"{COLLECTION}_manifest.json"

# Chunking
CHUNK_MAX_CHARS = int(os.getenv("CHUNK_MAX_CHARS", "1500"))   # ~ a few hundred tokens
CHUNK_OVERLAP   = int(os.getenv("CHUNK_OVERLAP", "200"))

# Embedding batch pacing (avoid hammering Ollama)
EMBED_RETRIES   = int(os.getenv("EMBED_RETRIES", "3"))


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# 1. Fetch — git clone (shallow) the repo
# ---------------------------------------------------------------------------
def clone_repo() -> Path:
    # /work may be a mounted volume (emptyDir) — we must NOT rmtree the mount
    # point itself (EBUSY). Clear its CONTENTS and clone into a subdir.
    WORKDIR.mkdir(parents=True, exist_ok=True)
    for child in WORKDIR.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child, ignore_errors=True)
        else:
            child.unlink(missing_ok=True)

    clone_dir = WORKDIR / "repo"          # clone into a subdir, not /work directly
    log(f"Cloning {REPO_URL} (branch {REPO_BRANCH}, shallow)...")
    subprocess.run(
        ["git", "clone", "--depth", "1", "--branch", REPO_BRANCH, REPO_URL, str(clone_dir)],
        check=True,
    )
    docs_root = clone_dir / DOCS_SUBPATH
    if not docs_root.is_dir():
        log(f"ERROR: docs subpath not found: {docs_root}")
        sys.exit(1)
    return docs_root

# ---------------------------------------------------------------------------
# 2. Chunk — markdown-aware, strips Hugo frontmatter + common shortcodes
# ---------------------------------------------------------------------------
FRONTMATTER_RE = re.compile(r"^---\n.*?\n---\n", re.DOTALL)
SHORTCODE_RE   = re.compile(r"{{[%<].*?[%>]}}", re.DOTALL)   # Hugo {{< >}} / {{% %}}
HEADING_RE     = re.compile(r"^#{1,6}\s", re.MULTILINE)


def clean_markdown(text: str) -> str:
    text = FRONTMATTER_RE.sub("", text)        # drop YAML frontmatter
    text = SHORTCODE_RE.sub("", text)          # drop Hugo shortcodes
    return text.strip()


def chunk_text(text: str) -> list[str]:
    """Split on heading boundaries, then pack into <= CHUNK_MAX_CHARS windows
    with overlap. Keeps related content together rather than blind slicing."""
    # Split into sections at headings (keep the heading with its section).
    parts, last = [], 0
    for m in HEADING_RE.finditer(text):
        if m.start() > last:
            parts.append(text[last:m.start()].strip())
            last = m.start()
    parts.append(text[last:].strip())
    sections = [p for p in parts if p]

    # Pack sections into windows; split oversized sections with overlap.
    chunks: list[str] = []
    buf = ""
    for sec in sections:
        if len(sec) > CHUNK_MAX_CHARS:
            if buf:
                chunks.append(buf); buf = ""
            start = 0
            while start < len(sec):
                end = start + CHUNK_MAX_CHARS
                chunks.append(sec[start:end])
                start = end - CHUNK_OVERLAP
        elif len(buf) + len(sec) + 1 <= CHUNK_MAX_CHARS:
            buf = f"{buf}\n{sec}".strip()
        else:
            if buf:
                chunks.append(buf)
            buf = sec
    if buf:
        chunks.append(buf)
    return [c for c in chunks if c.strip()]


# ---------------------------------------------------------------------------
# 3. Identify — deterministic int64 ID from filepath + chunk index
# ---------------------------------------------------------------------------
def chunk_id(rel_path: str, idx: int) -> int:
    h = hashlib.sha1(f"{rel_path}#{idx}".encode()).hexdigest()
    # Milvus INT64 primary key: take 63 bits of the hash for a stable positive id.
    return int(h[:16], 16) & 0x7FFFFFFFFFFFFFFF


def file_hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


# ---------------------------------------------------------------------------
# 4. Embed — via Ollama
# ---------------------------------------------------------------------------
def embed(text: str) -> list[float]:
    last_err = None
    for attempt in range(EMBED_RETRIES):
        try:
            r = requests.post(
                f"{OLLAMA_URL}/api/embeddings",
                json={"model": EMBED_MODEL, "prompt": text},
                timeout=120,
            )
            r.raise_for_status()
            vec = r.json()["embedding"]
            if len(vec) != EMBED_DIM:
                raise ValueError(
                    f"Embedding dim {len(vec)} != expected {EMBED_DIM}. "
                    f"Model/collection mismatch."
                )
            return vec
        except Exception as e:  # noqa: BLE001
            last_err = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"Embedding failed after {EMBED_RETRIES} tries: {last_err}")


# ---------------------------------------------------------------------------
# 5/6. Milvus — ensure collection, upsert, delete
# ---------------------------------------------------------------------------
def ensure_collection(client: MilvusClient) -> None:
    if client.has_collection(COLLECTION):
        return
    log(f"Creating collection '{COLLECTION}' (dim={EMBED_DIM})...")
    schema = client.create_schema(auto_id=False, enable_dynamic_field=True)
    schema.add_field("id", DataType.INT64, is_primary=True)
    schema.add_field("vector", DataType.FLOAT_VECTOR, dim=EMBED_DIM)
    schema.add_field("text", DataType.VARCHAR, max_length=65535)
    schema.add_field("path", DataType.VARCHAR, max_length=1024)
    schema.add_field("chunk_index", DataType.INT64)

    index_params = client.prepare_index_params()
    index_params.add_index(
        field_name="vector",
        index_type="HNSW",
        metric_type="COSINE",
        params={"M": 16, "efConstruction": 200},
    )
    client.create_collection(
        collection_name=COLLECTION,
        schema=schema,
        index_params=index_params,
    )


def load_manifest() -> dict:
    if MANIFEST_PATH.exists():
        return json.loads(MANIFEST_PATH.read_text())
    return {}   # { rel_path: {"hash": "...", "ids": [int, ...]} }


def save_manifest(manifest: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))


# ---------------------------------------------------------------------------
# Main incremental index
# ---------------------------------------------------------------------------
def main() -> None:
    docs_root = clone_repo()
    client = MilvusClient(uri=MILVUS_URI)
    ensure_collection(client)

    old_manifest = load_manifest()
    new_manifest: dict = {}

    # Gather current markdown files
    md_files = sorted(docs_root.rglob("*.md"))
    log(f"Found {len(md_files)} markdown files under {DOCS_SUBPATH}")

    current_paths = set()
    changed, unchanged = 0, 0

    for fp in md_files:
        rel = str(fp.relative_to(WORKDIR))
        current_paths.add(rel)
        raw = fp.read_text(errors="ignore")
        cleaned = clean_markdown(raw)
        if not cleaned:
            continue
        fhash = file_hash(cleaned)

        # Unchanged since last run? Keep its manifest entry, skip embedding.
        prev = old_manifest.get(rel)
        if prev and prev.get("hash") == fhash:
            new_manifest[rel] = prev
            unchanged += 1
            continue

        # Changed (or new): re-chunk, embed, upsert.
        chunks = chunk_text(cleaned)
        rows, ids = [], []
        for idx, ch in enumerate(chunks):
            cid = chunk_id(rel, idx)
            ids.append(cid)
            rows.append({
                "id": cid,
                "vector": embed(ch),
                "text": ch,
                "path": rel,
                "chunk_index": idx,
            })

        # If this file previously had MORE chunks than now, delete the stragglers.
        if prev:
            stale = set(prev.get("ids", [])) - set(ids)
            if stale:
                client.delete(collection_name=COLLECTION,
                              filter=f"id in {list(stale)}")

        if rows:
            client.upsert(collection_name=COLLECTION, data=rows)
        new_manifest[rel] = {"hash": fhash, "ids": ids}
        changed += 1
        log(f"  indexed {rel} ({len(chunks)} chunks)")

    # Deletion handling: files that existed last run but are gone now.
    removed_paths = set(old_manifest.keys()) - current_paths
    for rel in removed_paths:
        ids = old_manifest[rel].get("ids", [])
        if ids:
            client.delete(collection_name=COLLECTION, filter=f"id in {ids}")
        log(f"  removed {rel} ({len(ids)} chunks deleted)")

    save_manifest(new_manifest)
    log(f"Done. changed={changed} unchanged={unchanged} "
        f"removed={len(removed_paths)} total_files={len(current_paths)}")


if __name__ == "__main__":
    main()
