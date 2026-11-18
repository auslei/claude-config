---
description: >
  Use when writing code that calls the as-extractor service, submitting files or URLs for
  content extraction, polling extraction job results, or integrating with as-extractor from
  any other project (as_agents, as_vectordb, etc.).
  Also use when sending requests to port 8001 or implementing an as-extractor client.
---

# as-extractor — API Reference

**Base URL**: `http://localhost:8001`  
Full spec: `as_extractor/INTERFACE_SPEC.md`

**Purpose**: Extracts and normalizes content from files and URLs into structured JSON for downstream indexing (e.g. into as-vectordb).

---

## Endpoints at a glance

| Method | Path | Behaviour |
|--------|------|-----------|
| POST | `/analyze_image` | **Synchronous** — OCR a single image/PDF with optional custom prompt, returns text directly |
| POST | `/process_files` | **Queued** — upload files via multipart, returns `job_id` |
| POST | `/process_urls` | **Queued** — submit remote URLs, returns `job_id` |
| POST | `/unload` | **Queued** — unload models from VRAM |
| GET | `/jobs` | List retained jobs |
| GET | `/jobs/{job_id}` | Poll job status and result |
| GET | `/health` | Service status + queue state |
| GET | `/config` | Active configuration |
| GET | `/logs` | Recent log lines |

Queued extraction endpoints return immediately with a `job_id`. Poll `GET /jobs/{job_id}` until `status == "completed"`.

---

## POST /analyze_image

Synchronous OCR on a single image or PDF. Use this when you want an immediate answer with a custom prompt — no polling required.

```bash
curl -X POST http://localhost:8001/analyze_image \
  -F "file=@slide.png" \
  -F "prompt=List every metric, KPI, and number you can see with its unit and context."
```

**Form fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `file` | file | required | Image (jpg/png/bmp/tiff/webp) or PDF |
| `prompt` | string | default OCR prompt | Custom prompt — overrides the built-in verbatim-transcription prompt |
| `model` | string | config default | Override the Ollama vision model for this request |
| `dpi` | int | `100` | PDF rasterisation DPI |

**Response:**
```json
{ "pages": ["page 1 text", "page 2 text"], "page_count": 2 }
```

**Python example:**
```python
import httpx

with open("slide.png", "rb") as f:
    resp = httpx.post(
        "http://localhost:8001/analyze_image",
        files={"file": ("slide.png", f, "image/png")},
        data={"prompt": "What products and prices are shown?"},
    )
result = resp.json()  # {"pages": [...], "page_count": 1}
```

---

## POST /process_files

Upload files via `multipart/form-data`.

```
POST /process_files
Content-Type: multipart/form-data

files=@report.pdf
force=false
category=finance
sub_category=reports
file_date=2024-09-30
config={"pdf_process_method": "OCR"}
```

**Form fields:**

| Field | Type | Description |
|-------|------|-------------|
| `files` | file[] | One or more files to extract (required) |
| `force` | bool | Re-process even if cached (default: `false`) |
| `relative_paths` | string[] or JSON array string | Override relative paths for each uploaded file |
| `category` | string | Optional category tag — stored in result metadata |
| `sub_category` | string | Optional sub-category tag |
| `file_date` | string | Date override in ISO 8601 (`YYYY-MM-DD`) |
| `config` | string (JSON) | Optional [Config Override](#config-override) |

**Python example:**

```python
import httpx

with open("report.pdf", "rb") as f:
    resp = httpx.post(
        "http://localhost:8001/process_files",
        files={"files": ("report.pdf", f, "application/pdf")},
        data={"category": "finance", "force": "false"},
    )
job_id = resp.json()["job_id"]
```

---

## POST /process_urls

Submit remote URLs for extraction. Returns `422` if `urls` is empty.

```json
{
  "urls": ["https://example.com/report.pdf"],
  "force": false,
  "category": "finance",
  "sub_category": "reports",
  "file_date": "2024-09-30",
  "config": {}
}
```

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `urls` | string[] | One or more URLs (required, non-empty) |
| `force` | bool | Re-process even if cached (default: `false`) |
| `category` | string | Optional category tag |
| `sub_category` | string | Optional sub-category tag |
| `file_date` | string | Date override in ISO 8601 |
| `config` | object | Optional [Config Override](#config-override) |

---

## Job response & polling

All queued endpoints return:

```json
{ "job_id": "uuid", "status": "queued", "queue_size": 1, "position": 1 }
```

Poll `GET /jobs/{job_id}` until `status == "completed"` or `"failed"`.

**JobRecord fields:**

| Field | Description |
|-------|-------------|
| `job_id` | UUID |
| `status` | `queued` \| `running` \| `completed` \| `failed` |
| `result` | Extraction result(s) on completion — see [Result Schema](#extraction-result-schema) |
| `error` | Error message if `failed` |
| `progress_done` / `progress_total` | Progress counters while running |

**`result` shape:**
- Single file/URL → one result dict
- Multiple files/URLs → list of result dicts

---

## Extraction Result Schema

```json
{
  "document_title": "Q3 Financial Report",
  "document_type": "document",
  "content_type": "document",
  "process_type": "ocr",
  "file_path": "/data/uploads/q3.pdf",
  "pages": [
    { "page_number": 1, "page_content": "extracted text content..." }
  ]
}
```

| Field | Values | Description |
|-------|--------|-------------|
| `document_type` | `document`, `spreadsheet`, `image`, `audio`, `video` | File type |
| `content_type` | `document`, `spreadsheet`, `presentation`, `transcript` | Content category |
| `process_type` | `ocr`, `doc parsing`, `pdf-parse`, `pdf-liteparse`, `transcribe` | Parser used |
| `file_path` | string | Path to source file |
| `pages` | array | `[{page_number: int, page_content: str}]` |

This output is the correct input format for **as-vectordb** `/index` — pass `result` directly as `data`, adding `full_path` and any extra metadata fields.

---

## Config Override

Pass as `config` (JSON string for `/process_files`, object for `/process_urls`) to override model behaviour per request.

```json
{
  "ocr_model_name": "gemma4:31b-cloud",
  "transcribe_model_name": "turbo",
  "pdf_process_method": "OCR",
  "ocr_dpi": 150,
  "ocr_stream": false
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `ocr_model_name` | `"gemma4:31b-cloud"` | Ollama vision model for OCR |
| `transcribe_model_name` | `"turbo"` | Whisper model size |
| `pdf_process_method` | `"OCR"` | `"OCR"` \| `"liteparse"` \| `"marker"` |
| `ocr_dpi` | 150 | DPI for OCR conversion |
| `ocr_stream` | `false` | Enable streaming OCR response |

---

## Parser selection

| File type | Parser | Notes |
|-----------|--------|-------|
| PDF (standard) | `pdf-parse` | PyMuPDF — fast |
| PDF (high-fidelity) | `pdf-liteparse` | Node.js LiteParse |
| Scanned PDF / image | `ocr` | Ollama Vision (Gemma-VL) |
| DOCX / PPTX / XLSX | `doc parsing` | python-docx / openpyxl / python-pptx |
| Audio / video | `transcribe` | Faster-Whisper |

Override selection via `pdf_process_method` in the config override.

---

## Error codes

| Status | Meaning |
|--------|---------|
| 422 | Validation error — bad input, empty URL list |
| 500 | Server error — enqueue failure, parser crash |
| 503 | Service degraded — queue infrastructure failure |
