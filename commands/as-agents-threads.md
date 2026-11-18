---
description: >
  Use when managing as-agents threads (sessions): listing, reading plan or token stats,
  clearing, compressing, or deleting a thread. Also use when starting, monitoring, or
  cancelling delegate jobs via the /v1/jobs API, or retrieving job artifacts.
  Also use when uploading files, triggering extraction, listing session files, or
  deleting files via the /v1/threads/{thread_id}/files endpoints.
---

# as-agents — Threads (Sessions) & Jobs

**Base URL**: `http://localhost:8008`

> A **thread** is a session — one continuous conversation with an agent. `thread_id` is the LangGraph checkpoint key that persists message history and state across requests.
>
> A **job** is a headless delegate subprocess — an agent running a task in the background without an interactive chat session. Jobs are only created via `POST /v1/jobs` (directly) or when an agent calls `start_delegate`. File extraction tasks reuse the jobs table for status tracking but are not delegate jobs.

---

## Thread endpoints

```
GET    /v1/threads                          # list sessions; ?agent=fa_agent; ?limit=50
POST   /v1/threads/token-usage              # bulk token cost for multiple threads → {object, data}
GET    /v1/threads/{thread_id}/plan         # plan markdown + steps_total/done/pct_complete (404 if no plan)
POST   /v1/threads/{thread_id}/plan/clear   # clear active plan → {status: "plan_cleared"}
GET    /v1/threads/{thread_id}/status       # per-role token breakdown + context window % (actual or estimated)
GET    /v1/threads/{thread_id}/context      # cumulative token totals + est_cost_usd across all turns
POST   /v1/threads/{thread_id}/clear        # reset messages + session context → {status: "cleared"}
POST   /v1/threads/{thread_id}/compress     # LLM-summarise history into 1 message → {status, original_message_count, summary}
DELETE /v1/threads/{thread_id}              # permanent delete → {status: "deleted", telemetry_rows_deleted}
```

> `?model=` selects the agent's checkpoint graph (default `"default"`). Match the value used when chatting.

**Plan response:**
```json
{ "thread_id": "...", "plan": "- [x] Step 1\n- [ ] Step 2", "steps_total": 2, "steps_done": 1, "pct_complete": 50 }
```

**Status response** (per-role breakdown — use for UI token meters):
```json
{
  "thread_id": "...", "agent_name": "fa_agent",
  "context_window": 65536, "used_tokens": 14200, "pct": 21.7,
  "role_tokens": { "system": 3200, "user": 800, "tool": 2100, "assistant": 8100 },
  "role_counts": { "system": 1, "user": 4, "tool": 6, "assistant": 4 },
  "source": "actual"
}
```

**Context response** (cumulative totals — single thread):
```json
{ "thread_id": "...", "total_prompt_tokens": 48200, "total_completion_tokens": 12100, "total_tokens": 60300, "est_cost_usd": 0.000724, "run_count": 6, "context_window": 65536, "cumulative_pct": 73.6 }
```

**Bulk token-usage** — frontend use: sum costs across all a user's threads:

Request:
```json
{ "thread_ids": ["thread-abc", "thread-xyz"] }
```
Response:
```json
{
  "object": "list",
  "data": {
    "thread-abc": { "total_prompt_tokens": 48200, "total_completion_tokens": 12100, "total_tokens": 60300, "est_cost_usd": 0.000724, "run_count": 6 },
    "thread-xyz": { "total_prompt_tokens": 0, "total_completion_tokens": 0, "total_tokens": 0, "est_cost_usd": 0.0, "run_count": 0 }
  }
}
```
- Threads with no recorded usage return zero values (not 404).
- Single SQL query regardless of how many thread_ids are passed.

---

## Session file endpoints

Files are session-scoped — stored at `data/{thread_id}/raw/` (originals) and `data/{thread_id}/{stem}.md` (extracted). Upload and extraction are separate steps. Deleted with the thread.

Uploads are rejected with `413` above `MAX_UPLOAD_MB` (default 10 MB): `{ "error": "file_too_large", "filename": "...", "message": "..." }`. PDFs are additionally rejected above `MAX_PDF_PAGES` (default 100, checked pre-extraction): `{ "error": "too_many_pages", "filename": "...", "page_count": N, "message": "..." }`.

```
POST   /v1/threads/{thread_id}/files                    # upload files (multipart, field: "files")
POST   /v1/threads/{thread_id}/files/process            # trigger as_extractor → returns job_id
GET    /v1/threads/{thread_id}/files                    # list files with status + snippet
DELETE /v1/threads/{thread_id}/files/{file_id}          # delete one file
DELETE /v1/threads/{thread_id}/files                    # delete all files for session
```

**Upload response:**
```json
{ "files": [{ "file_id": "a1b2c3d4", "filename": "report.pdf", "mime_type": "application/pdf", "size_kb": 142.3, "status": "uploaded" }] }
```
409 on filename conflict: `{ "error": "filename_conflict", "filename": "report.pdf", "message": "..." }`

**Process request / response:**
```json
// request (omit file_ids to process all status=uploaded)
{ "file_ids": ["a1b2c3d4"] }
// response — extraction_id is NOT a delegate job; it's a file-extraction tracking id
{ "job_id": "<extraction_id>", "file_ids": ["a1b2c3d4"], "status": "processing" }
```
Subscribe to `GET /v1/threads/{thread_id}/files/{extraction_id}/events` (SSE) for live status, or poll `GET /v1/jobs/{extraction_id}` for `status: "done"` or `"error"`.

**List response:**
```json
{ "files": [{ "file_id": "...", "filename": "report.pdf", "status": "done", "snippet": "First 500 chars…", "error_msg": null, "uploaded_at": "...", "extracted_at": "..." }] }
```
Status values: `uploaded` → `processing` → `done` | `error`

**Agent tools** (opt-in per agent via that agent's `tools:` list in `config.yml` — not in `base_tools`):
- `list_session_files(thread_id)` — returns file list with status and snippet
- `process_file(file_id, thread_id, instructions?, config_override?, force?)` — the single entry point for reading a file's content. Cache-aware: if already extracted, returns the content directly in this same call (no follow-up `read_file` needed). `instructions` routes to `/analyze_image` for images/PDFs. `force=true` re-extracts even if already done.

Do not use the generic `read_file` tool on `data/{thread_id}/...` paths — always use `process_file`, which checks the cache first.

---

## Job endpoints

A job is a headless delegate subprocess — the same mechanism as the `start_delegate`/`poll_delegate` agent tools, but callable directly from the frontend. Only delegate subprocesses are jobs; file extraction uses a separate tracking ID.

```
POST   /v1/jobs                             # start a job
GET    /v1/jobs                             # list jobs; ?agent=<name>; ?limit=50
GET    /v1/jobs/{job_id}                    # job details + full event log
GET    /v1/jobs/{job_id}/events             # SSE stream of live job events
DELETE /v1/jobs/{job_id}                    # cancel (SIGTERM + cleanup)
```

**Start job request:**
```json
{ "agent": "distiller", "prompt": "Distil Steve Jobs", "skill": "distill-lens", "thread_id": "" }
```
- `agent`: agent name from config (default `"default"`)
- `skill`: optional — prepended as `[Skill: {skill}]` to the prompt
- `thread_id`: optional — auto-generated as `delegate-{job_id}` if omitted

**Start job response:**
```json
{ "job_id": "550e8400-...", "thread_id": "delegate-550e8400-...", "status": "running" }
```

**Cancel response:**
```json
{ "job_id": "...", "status": "cancelled" }   // or "already_finished"
```

**SSE event stream** (`/events`):

Each `data:` line is a JSON object. Event types:

| `type` / `event` | Meaning |
|------------------|---------|
| `"start"` | Tool call started — `{type, name, input}` |
| `"end"` | Tool call finished — `{type, name, output}` (truncated to 500 chars) |
| `"plan_created"` | Agent created a plan — `{type, plan, steps}` |
| `"step_start"` | Plan step begun — `{type, step, index}` |
| `"step_complete"` | Plan step done — `{type, step, index}` |
| `"artifact"` | File ready to download — `{type, filename, agent, path, mime, url}` |
| `{"event":"done"}` | Job finished — stream ends |
| `{"event":"error","message":"..."}` | Job failed — stream ends |

**Artifact event:**
```json
{ "type": "artifact", "filename": "report.pdf", "agent": "distiller", "path": "skill_outputs/distill-lens/report.pdf", "mime": "application/pdf", "url": "/v1/agents/distiller/workspace/skill_outputs/distill-lens/report.pdf" }
```
Use `url` directly against the base URL to download the file — no extra endpoint needed.

**JS poll snippet:**
```js
const es = new EventSource(`http://localhost:8008/v1/jobs/${jobId}/events`)
es.onmessage = (e) => {
  const ev = JSON.parse(e.data)
  if (ev.event === 'done' || ev.event === 'error') { es.close(); return }
  if (ev.type === 'artifact') showDownload(ev.url, ev.filename)
  if (ev.type === 'plan_created') showPlan(ev.steps)
}
```
