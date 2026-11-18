---
description: >
  Use when writing code that calls the as-agents chat endpoint, handles SSE streaming,
  processes plan events, handles interrupts, dispatches background tasks, subscribes to
  delegate events, or switches agent models at runtime.
  Also use when sending messages to port 8008 or implementing an as-agents chat client.
---

# as-agents — Chat, SSE & Models

**Base URL**: `http://localhost:8008`  
Full reference: `as_agents/docs/api/chat.md`

---

## Send a message

```json
POST /v1/chat/completions
{
  "model": "fa_agent",
  "messages": [{ "role": "user", "content": "Your prompt here" }],
  "stream": true,
  "thread_id": "<uuid>"
}
```

- `model` — agent name from `GET /v1/agents`
- `thread_id` — reuse across turns; omit for stateless one-shot
- Only `messages[-1].content` is processed
- `content` can be a **string** or an **array of content blocks** (see below)
- `metadata` *(optional object)* — key-value pairs merged into the session context (LangGraph state) for this turn; keys persist in the checkpoint until explicitly overwritten. Use to pass client-side flags the agent reads from `## Session Context`.
  - **`lens_mode`** — controls which answer protocol is appended to the active lens each turn. Values: `"lite"` (default — sections 1 + 3, compact protocol), `"full"` (all sections + full agentic-answer protocol), `"score"` (all sections + scoring protocol). Changing this mid-session takes effect on the next turn without reloading the lens.

### Multimodal content blocks

Pass `content` as an array to send images or mixed content (OpenAI vision format):

```json
{
  "model": "default",
  "messages": [{
    "role": "user",
    "content": [
      { "type": "text", "text": "What does this chart show?" },
      { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,<b64>" } }
    ]
  }],
  "stream": true,
  "thread_id": "<uuid>"
}
```

**Images are passed straight through to the model** — no storage, no tool call. The `image_url` block is forwarded unchanged inside the same message the LLM receives, exactly like a standard OpenAI vision request; vision-capable models see it natively.

`image_url.url` accepts a **data URI** (`data:image/jpeg;base64,...`) or a **real URL** (`https://...`).

Any other block type (e.g. `file`) is dropped — there is no generic binary-attachment mechanism. For documents/files, upload them via the session-files API instead (see `as-agents-threads` skill) and have the agent call `process_file`.

---

## SSE chunk types

Parse each `data: <json>` line. Ignore `data: [DONE]`.

| `finish_reason` | Meaning | Action |
|-----------------|---------|--------|
| `null` | Mid-stream token | Append `delta.content` (skip if `delta.thinking == true`) |
| `stop` | Done | — |
| `interrupt` | Needs input or approval | Check `interrupt.type` — see below |
| `task_started` | Background job dispatched | Read `background_started.job_id`; poll progress |

**Tool event** (informational, no content):
```json
{ "tool_event": { "type": "start"|"end", "name": "tool_name", "input": "...", "output": "..." } }
```

**Plan events** — `tool_event` suppressed for all three; only `plan_event` emitted:

| `plan_event.type` | When | Key fields |
|---|---|---|
| `plan_created` | Agent creates checklist | `plan` (markdown), `steps` (string array) |
| `step_start` | Agent begins a step | `step` (label), `index` (1-based) |
| `step_complete` | Agent ticks a step | `plan` (updated markdown), `step`, `summary`? |

```json
{ "plan_event": { "type": "plan_created", "plan": "- [ ] step 1\n- [ ] step 2", "steps": ["step 1", "step 2"] } }
{ "plan_event": { "type": "step_start", "step": "step 1", "index": 1 } }
{ "plan_event": { "type": "step_complete", "plan": "- [x] step 1\n- [ ] step 2", "step": "step 1", "summary": "..." } }
```

**Context stats** (once per turn, just before `stop`):
```json
{ "context_stats": { "used_tokens": 12800, "context_window": 65536, "pct": 19.5 }, "thread_id": "..." }
```

**Token usage** (on the `finish_reason: stop` chunk — present when the model returns `usage_metadata`):
```json
{ "choices": [{ "delta": {}, "finish_reason": "stop" }], "usage": { "prompt_tokens": 812, "completion_tokens": 340, "total_tokens": 1152 }, "thread_id": "..." }
```

Use `usage.total_tokens` to deduct credits. The full end-of-stream sequence is:
```
data: {"context_stats": {...}, ...}
data: {"choices": [{"finish_reason": "stop"}], "usage": {"prompt_tokens": 812, "completion_tokens": 340, "total_tokens": 1152}, ...}
data: [DONE]
```

---

## Interrupt types

Both use `finish_reason: "interrupt"`. Distinguish by `interrupt.type`:

| `type` | Meaning | Handle |
|--------|---------|--------|
| `"human_input"` | Agent asked a question | Show to user; send answer as next message on same `thread_id` |
| `"approval"` | Agent wants to run a tool | Show tool + question; send approval or denial |

**Approval words** (case-insensitive): `yes`, `y`, `ok`, `okay`, `sure`, `go`, `proceed`, `approve`, `confirmed`, `confirm`  
**Denial**: anything else — agent responds gracefully without running the tool.

---

## Background task dispatched

```json
{ "choices": [{ "finish_reason": "task_started" }], "background_started": { "job_id": "a3f9c1b2", "label": "..." } }
```

Stream ends here. Poll `GET /v1/jobs/{job_id}` for status, or subscribe to `GET /v1/jobs/{job_id}/events` (SSE) for live progress — see `as-agents-threads` skill.

---

## Delegate subprocess events

When an agent uses `start_delegate`, the SSE stream emits a `tool_event` with `job_id`. Subscribe to that job's event stream to get live progress from the subprocess:

```
GET /v1/delegate/{job_id}/events   # SSE; tails /tmp/ic_delegate_{job_id}.jsonl
```

Each line is a `data: <json>` event. Stream ends on `{"event": "done"}` or `{"event": "error"}`.

```python
with httpx.stream("GET", f"{BASE}/v1/delegate/{job_id}/events", timeout=None) as r:
    for line in r.iter_lines():
        if not line.startswith("data: "): continue
        ev = json.loads(line[6:])
        if ev.get("event") in ("done", "error"):
            break
        # tool_event / plan_event dicts mirror the main SSE stream
```

---

## Agent card

```
GET /v1/agents/{agent_name}/card
```

Returns `{ "agent": "<name>", "card": "<AGENT_CARD.md contents>" }`.  
Returns `{ "agent": "<name>", "card": "N/A" }` if the agent has no `AGENT_CARD.md`.  
404 if agent name is unknown.

Use this to orient a client when switching agents — the card describes what the agent does and how to use it, from the agent's own perspective.

---

## Agents

```
GET    /v1/agents                          # list all agents (full config; id == name)
GET    /v1/agents/{name}/card              # agent card markdown
GET    /v1/agents/{name}/skills            # skills available to this agent
GET    /v1/agents/{name}/model             # active model for agent (config + runtime override)
PUT    /v1/agents/{name}/model             # switch model: {"model": "<registry-key>"}
DELETE /v1/agents/{name}/model             # clear override — reverts to config default
```

## LLM models

```
GET    /v1/models                          # list LLM profiles {name, provider, model, temperature, context_window}
POST   /v1/models?name=<key>              # create LLM profile
PUT    /v1/models/{name}                   # update LLM profile
DELETE /v1/models/{name}                   # delete LLM profile (blocked if in use)
```

**Switch example:**
```python
httpx.put(f"{BASE}/v1/agents/fa_agent/model", json={"model": "claude-sonnet"})
```
Clears the agent from the pool so the next request picks up the new model.

---

## Artifact SSE event

When an agent calls `notify_artifact`, a chunk arrives with no `delta.content`:

```json
{ "artifact_event": { "filename": "report.pdf", "agent": "fa_agent", "path": "report.pdf", "mime": "application/pdf", "url": "/v1/agents/fa_agent/workspace/report.pdf" } }
```

Show a download button linking to `/api/agents` + `artifact_event.url`.

---

## Workspace files

```
GET /v1/agents/{agent_name}/workspace          # list all files → { "object": "list", "data": [...] }
GET /v1/agents/{agent_name}/workspace/{path}   # download a file (FileResponse, path-guarded, 403 if outside workspace)
```

Each file entry: `{ filename, path, url, mime, size, modified }`.  
Download URL: `/api/agents` + `url` (proxied via Next.js).

---

---

## Distiller lenses

```
GET /v1/lenses                              # all lenses
GET /v1/lenses?subject_area=investors       # filter by subject area
GET /v1/agents/{name}/lenses                # lenses filtered to a specific agent
GET /v1/agents/{name}/lenses?subject_area=investors
```

Response: `{ "object": "list", "data": [{ "slug": "jack-ma", "subject_area": "china", "identity": "..." }] }`

- `slug` — cache key used in `load_lens` / `distill_lens` tool calls
- `subject_area` — folder the lens lives under (`investors`, `china`, `tech`, `architecture`, `politics`, `property`, `thinkers`, `regulators`); `null` for top-level lenses
- `identity` — always present; one-sentence identity summary for the lens

---

## CV Scoring

Deterministic CV endpoints — call directly from the UI, bypassing LLM routing. Requires files uploaded via `POST /v1/threads/{thread_id}/files` first.

```
POST /v1/cv/analyse   — full CV analysis (perspectives + summary + prospective titles)
POST /v1/cv/fit       — hiring verdict for a target role (requires analyse first)
```

### `/v1/cv/analyse`

```json
POST /v1/cv/analyse
{ "thread_id": "<uuid>", "filename": "<uploaded filename>" }
```

Response:
```json
{
  "cv_hash": "a3f9c1b2d4e5f6a7",
  "perspectives": [
    { "lens_slug": "...", "lens_name": "...", "overall": 7.5,
      "dimensions": [{"name":"<lens-chosen>","score":8,"reasoning":"<one line>"},...] }
  ],
  "summary": {
    "score": 7.5, "grade": "B",
    "summary": "...", "strengths": [...], "gaps": [...], "top_priority": "...",
    "prospective_titles": ["Senior Data Scientist", "Lead ML Engineer", "..."]
  }
}
```

- Each perspective chooses its own 5 dimensions — names are lens-specific, not fixed.
- `summary.score` is synthesised by anthonysun.ai from perspective `overall` scores; high variance across perspectives lowers confidence.
- Perspectives are cached by CV content hash — repeat calls with the same file are fast.
- Cache lives at `data/{thread_id}/cv_score/{cv_hash}/{lens_slug}.json`.

### `/v1/cv/fit`

```json
POST /v1/cv/fit
{
  "thread_id": "<uuid>",
  "filename": "<uploaded filename>",
  "job_target": "<role title or full JD text>",   // optional — provide this OR jd_url
  "jd_url": "<https://...>"                        // optional — scraped on the fly
}
```

Provide exactly one of `job_target` (free text) or `jd_url` (URL to a job posting). If both are given, `jd_url` takes precedence. If scraping the URL fails, a `400` is returned immediately — no LLM call is made.

Response:
```json
{
  "cv_hash": "a3f9c1b2d4e5f6a7",
  "verdict": {
    "score": 3.1, "grade": "D",
    "verdict": "no_hire",
    "fit_gap": "overqualified",
    "summary": "...", "strengths": [...], "gaps": [...], "top_priority": "..."
  }
}
```

- `verdict`: `hire` | `no_hire` | `conditional`
- `fit_gap`: `good_fit` | `overqualified` | `underqualified`
- Requires `/v1/cv/analyse` to have been called first on the same file/thread.

### Error response (both endpoints)

```json
{ "error": "<code>", "message": "<human readable>" }
```

| Code | Meaning |
|------|---------|
| `file_not_found` | File not in `data/{thread_id}/raw/` |
| `extraction_failed` | as_extractor could not parse the file |
| `no_lenses` | No CV perspective lenses configured |
| `not_cv` | Uploaded file is not a CV/résumé |
| `not_analysed` | `/v1/cv/analyse` not run yet (fit endpoint only) |
| `jd_scrape_failed` | URL provided but could not be scraped — paste JD text directly |
| `missing_job_target` | Neither `job_target` nor `jd_url` provided |
| `internal_error` | Unexpected error |

### Python client example

```python
import httpx

BASE = "http://localhost:8008"
thread_id = "<uuid>"

# Step 1 — upload
with open("resume.pdf", "rb") as f:
    r = httpx.post(f"{BASE}/v1/threads/{thread_id}/files", files={"files": f})
filename = r.json()["files"][0]["filename"]

# Step 2 — analyse
analyse = httpx.post(f"{BASE}/v1/cv/analyse",
                     json={"thread_id": thread_id, "filename": filename}).json()
print(analyse["summary"]["prospective_titles"])

# Step 3a — job fit via free text
fit = httpx.post(f"{BASE}/v1/cv/fit",
                 json={"thread_id": thread_id, "filename": filename,
                       "job_target": "Senior Data Scientist at a fintech startup"}).json()

# Step 3b — job fit via URL
fit = httpx.post(f"{BASE}/v1/cv/fit",
                 json={"thread_id": thread_id, "filename": filename,
                       "jd_url": "https://example.com/jobs/senior-data-scientist"}).json()

print(fit["verdict"]["verdict"], fit["verdict"]["fit_gap"])
```

---

## Minimal Python client

```python
import httpx, json, uuid

BASE = "http://localhost:8008"

def chat(model, message, thread_id):
    with httpx.stream("POST", f"{BASE}/v1/chat/completions", timeout=None,
                      json={"model": model, "messages": [{"role": "user", "content": message}],
                            "stream": True, "thread_id": thread_id}) as r:
        for line in r.iter_lines():
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[6:])
            reason = chunk["choices"][0].get("finish_reason")
            delta  = chunk["choices"][0].get("delta", {})
            if reason == "interrupt":
                return {"type": "interrupt", "data": chunk["interrupt"], "thread_id": chunk["thread_id"]}
            if reason == "task_started":
                return {"type": "background", "job_id": chunk["background_started"]["job_id"],
                        "thread_id": chunk["thread_id"]}
            if delta.get("content") and not delta.get("thinking"):
                print(delta["content"], end="", flush=True)
```
