---
description: >
  Use when writing code that calls the as-vectordb service, indexing documents into the
  vector DB, querying for semantically similar content, managing collections, or
  integrating with as-vectordb from any other project (as_agents, as_extractor, etc.).
  Also use when sending requests to port 8002 or implementing an as-vectordb client.
---

# as-vectordb — API Reference

**Base URL**: `http://localhost:8002` (configurable via `vectordb.port` in `config.yaml`)  
Full spec: `as_vectordb/INTERFACE_SPEC.md`

---

## Endpoints at a glance

| Method | Path | Behaviour |
|--------|------|-----------|
| POST | `/index` | **Queued** — returns `job_id`, poll `/jobs/{job_id}` |
| POST | `/unload` | **Queued** — unloads models from VRAM |
| POST | `/query` | **Direct** — returns results inline |
| POST | `/collections` | **Direct** — list all collections |
| POST | `/collection_exists` | **Direct** — check if collection exists |
| POST | `/reset_collection` | **Direct** — wipe + recreate collection |
| POST | `/get_unique_metadata` | **Direct** — discover unique metadata values |
| POST | `/delete_by_metadata` | **Direct** — delete points by filter |
| GET | `/health` | Service status + queue state |
| GET | `/config` | Active model/Qdrant config |
| GET | `/jobs` | List retained jobs |
| GET | `/jobs/{job_id}` | Poll job status and result |

---

## POST /index

Queue documents for embedding + storage. Returns immediately; poll for completion.

```json
{
  "data": {
    "document_title": "Q3 Report",
    "document_type": "document",
    "full_path": "/data/reports/q3.pdf",
    "file_date": "2024-09-30",
    "pages": [
      { "page_number": 1, "page_content": "..." }
    ]
  },
  "collection_name": "my_collection",
  "reset": false,
  "force": false
}
```

`data` can be a single dict or a list of dicts.

**Required fields per document:**

| Field | Description |
|-------|-------------|
| `document_title` | Human-readable title |
| `document_type` | `"video"`, `"audio"`, `"pdf"`, `"markdown"`, `"document"` — drives chunker selection |
| `full_path` | Canonical path — used for deduplication (skip re-index unless `force=true`) |
| `pages` | `[{page_number: int, page_content: str}]` |

**Optional fields** (`file_date`, `category`, `sub_category`, `content_type`, any extra key) are stored as metadata on every chunk.

**Chunking:** `audio`/`video` → transcript chunker (time windows); everything else → markdown chunker (heading-aware).

**Parameters:**

| Param | Default | Description |
|-------|---------|-------------|
| `reset` | `false` | Wipe collection before indexing |
| `force` | `false` | Re-index even if `full_path` already exists |
| `max_chunk_size` | 1000 | Max chars per chunk (markdown docs) |
| `chunk_overlap` | 200 | Char overlap between chunks |
| `transcript_window_seconds` | 60 | Time window for transcript chunks |
| `transcript_overlap_seconds` | 15 | Time overlap for transcript chunks |
| `config` | — | Optional [ConfigOverride](#configoverride) |

**Response:**

```json
{ "job_id": "uuid", "status": "queued", "queue_size": 1, "position": 1 }
```

Poll `GET /jobs/{job_id}` until `status == "completed"`. `result` = chunk count (int).

---

## POST /query

Query for semantically similar chunks. Returns directly — no polling needed.

```json
{
  "questions": "What was the revenue in Q3?",
  "collection_name": "my_collection",
  "n_results": 10,
  "rerank": false,
  "condense": false,
  "filter_metadata": { "document_type": "document" }
}
```

`questions` can be a string or a list of related query expansions (paraphrases / sub-questions).

**Parameters:**

| Param | Default | Description |
|-------|---------|-------------|
| `n_results` | 10 | Max results to return |
| `mmr` | `true` | Maximal Marginal Relevance — diverse result set |
| `diversity` | 0.6 | MMR diversity weight (0.0 = pure relevance, 1.0 = pure diversity) |
| `rerank` | `false` | Cross-encoder reranking for higher precision |
| `condense` | `false` | `true` → formatted string; `false` → `List[Hit]` |
| `filter_metadata` | — | Exact-match filter e.g. `{"document_type": "audio"}` |
| `auto_unload` | `false` | Unload models after query completes |
| `config` | — | Optional [ConfigOverride](#configoverride) |

**Response** (`condense=false`):

```json
[
  {
    "id": "abc123",
    "text": "chunk content...",
    "score": 0.92,
    "_rerank_score": 0.87,
    "metadata": {
      "document_title": "Q3 Report",
      "document_type": "document",
      "full_path": "/data/reports/q3.pdf",
      "page_number": 5,
      "chunk_index": 0,
      "file_date": "2024-09-30"
    }
  }
]
```

`_rerank_score` only present when `rerank=true`.  
`condense=true` returns a single formatted string with source headers.

---

## Collection management

```json
// POST /collection_exists
{ "name": "my_collection" }
// → { "exists": true }

// POST /collections
{}
// → { "collections": ["col_a", "col_b"] }

// POST /reset_collection
{ "collection_name": "my_collection" }
// → { "status": "success", "message": "..." }

// POST /get_unique_metadata
{ "collection_name": "my_collection", "keys": ["document_type", "category"] }
// → { "document_type": ["document", "audio"], "category": ["finance"] }

// POST /delete_by_metadata
{ "collection_name": "my_collection", "filter_metadata": { "document_title": "Q3 Report" } }
// → { "status": "success", "count": 1 }
```

---

## Job polling

```
GET /jobs/{job_id}
```

| Field | Description |
|-------|-------------|
| `status` | `queued` \| `running` \| `completed` \| `failed` |
| `result` | Chunk count (int) for `index`; `{"status":"success"}` for `unload` |
| `error` | Error message if `failed` |
| `progress_done` / `progress_total` | Progress counters while running |

---

## ConfigOverride

Pass as `"config": {...}` in any request to override models for that request only.

```json
{
  "config": {
    "embedding_model": "BAAI/bge-m3",
    "rerank_model": "BAAI/bge-reranker-v2-m3",
    "device": "cuda",
    "llm_settings": {
      "provider": "ollama",
      "model_name": "qwen3:14b",
      "temperature": 0.0
    }
  }
}
```

`llm_settings` enables dual-vector indexing (text + LLM summary vectors).

---

## Error codes

| Status | Meaning |
|--------|---------|
| 400 | Invalid LLM config in request |
| 404 | Job or collection not found |
| 422 | Validation error (missing required fields) |
| 500 | Server / Qdrant error |
| 503 | Qdrant unreachable |
