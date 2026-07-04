#!/usr/bin/env python3
"""
retrieval_tool.py

Multi-source semantic retrieval over Milvus, exposed as an OpenAPI service so it
plugs into your existing mcpo -> Open-WebUI tool setup alongside the k8s and
systemd MCP tools.

Design goals (per the single-V100 discussion):
  - GPU-light: embeddings use the small nomic-embed-text via Ollama; vector search
    is Milvus (CPU). The big chat model (Qwen) is never involved in retrieval, so
    this adds no GPU/model-switching pressure.
  - Multi-source: one parameterized endpoint queries any configured collection
    (k8s_docs now; add distro docs, codebase later by adding a collection entry).
  - Two usage modes:
      * single-source ("search the k8s docs")  -> fast, one call
      * multi-source  ("search everything")    -> one call fans out to all sources
    so the LLM can do cheap single-hop OR broad fan-out, and chain calls itself
    for multi-hop correlation when a hard problem warrants it.

Endpoints (what mcpo will expose as tools):
  GET  /sources                      -> list configured sources
  POST /search                       -> search ONE source
  POST /search_all                   -> search ALL sources (fan-out), merged + ranked
"""

import os
from typing import Optional

import requests
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from pymilvus import MilvusClient

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama.ai.svc.cluster.local:11434")
MILVUS_URI = os.getenv("MILVUS_URI", "http://milvus.ai.svc.cluster.local:19530")
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")
EMBED_DIM = int(os.getenv("EMBED_DIM", "768"))

# Configured sources: logical name -> Milvus collection name.
# Add distro docs / codebase here later; the tool picks them up with no code change.
# Format: "name:collection,name2:collection2" via env, or edit DEFAULT_SOURCES.
DEFAULT_SOURCES = {
    "k8s_docs": "k8s_docs",
    # "distro_docs": "distro_docs",
    # "codebase": "codebase",
}


def _load_sources() -> dict[str, str]:
    raw = os.getenv("SOURCES", "")
    if not raw.strip():
        return DEFAULT_SOURCES
    out = {}
    for pair in raw.split(","):
        if ":" in pair:
            name, coll = pair.split(":", 1)
            out[name.strip()] = coll.strip()
    return out or DEFAULT_SOURCES


SOURCES = _load_sources()

app = FastAPI(
    title="Multi-Source Retrieval",
    description="Semantic search over Milvus document collections (k8s docs, "
                "distro docs, codebase). Use /search for one source, /search_all "
                "to fan out across all sources for cross-source correlation.",
    version="1.0.0",
)

_milvus = MilvusClient(uri=MILVUS_URI)


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
class SearchRequest(BaseModel):
    query: str = Field(..., description="The natural-language search query.")
    source: str = Field(..., description="Which source to search. Call /sources "
                                         "to see valid names.")
    limit: int = Field(5, ge=1, le=20, description="Max chunks to return.")


class SearchAllRequest(BaseModel):
    query: str = Field(..., description="The natural-language search query.")
    limit_per_source: int = Field(3, ge=1, le=10,
                                  description="Max chunks to return per source.")


class Hit(BaseModel):
    source: str
    text: str
    path: Optional[str] = None
    score: float


class SearchResponse(BaseModel):
    query: str
    hits: list[Hit]


# ---------------------------------------------------------------------------
# Embedding (small model, GPU-light)
# ---------------------------------------------------------------------------
def embed(text: str) -> list[float]:
    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/embeddings",
            json={"model": EMBED_MODEL, "prompt": text},
            timeout=60,
        )
        r.raise_for_status()
        vec = r.json()["embedding"]
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502,
                            detail=f"Embedding via Ollama failed: {e}")
    if len(vec) != EMBED_DIM:
        raise HTTPException(
            status_code=500,
            detail=f"Embedding dim {len(vec)} != expected {EMBED_DIM}; "
                   f"model/collection mismatch.",
        )
    return vec


def _search_collection(collection: str, qvec: list[float], limit: int,
                       source_name: str) -> list[Hit]:
    try:
        res = _milvus.search(
            collection_name=collection,
            data=[qvec],
            limit=limit,
            output_fields=["text", "path"],
        )
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502,
                            detail=f"Milvus search on '{collection}' failed: {e}")
    hits: list[Hit] = []
    for h in res[0]:
        ent = h.get("entity", {})
        hits.append(Hit(
            source=source_name,
            text=ent.get("text", ""),
            path=ent.get("path"),
            # Milvus COSINE distance: higher = more similar in MilvusClient results.
            score=float(h.get("distance", 0.0)),
        ))
    return hits


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/sources", summary="List available document sources",
         description="Returns the configured source names you can pass to /search.")
def list_sources() -> dict:
    return {"sources": list(SOURCES.keys())}


@app.post("/search", response_model=SearchResponse,
          summary="Search a single document source",
          description="Embeds the query and returns the most semantically similar "
                      "chunks from ONE source. Use this for targeted lookups "
                      "(e.g. 'search the k8s docs for liveness probes').")
def search(req: SearchRequest) -> SearchResponse:
    if req.source not in SOURCES:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown source '{req.source}'. Valid: {list(SOURCES.keys())}",
        )
    qvec = embed(req.query)
    hits = _search_collection(SOURCES[req.source], qvec, req.limit, req.source)
    return SearchResponse(query=req.query, hits=hits)


@app.post("/search_all", response_model=SearchResponse,
          summary="Search all document sources at once",
          description="Embeds the query ONCE and fans out across every configured "
                      "source, merging results ranked by similarity. Use this for "
                      "cross-source correlation (e.g. debugging an issue that may "
                      "span k8s docs, distro docs, and the codebase).")
def search_all(req: SearchAllRequest) -> SearchResponse:
    qvec = embed(req.query)               # embed once, reuse across sources
    all_hits: list[Hit] = []
    for name, coll in SOURCES.items():
        try:
            all_hits.extend(
                _search_collection(coll, qvec, req.limit_per_source, name)
            )
        except HTTPException:
            # One source failing (e.g. collection not created yet) shouldn't kill
            # the whole fan-out; skip it and return what we have.
            continue
    # Merge + rank by score descending (COSINE: higher = closer).
    all_hits.sort(key=lambda h: h.score, reverse=True)
    return SearchResponse(query=req.query, hits=all_hits)


@app.get("/healthz", summary="Health check")
def healthz() -> dict:
    return {"status": "ok", "sources": list(SOURCES.keys())}
