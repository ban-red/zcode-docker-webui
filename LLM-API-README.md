# ZCode OpenAI-compatible API: usage guide for LLMs

An OpenAI-style chat API backed by ZCode (Z.ai GLM models). Use it like the OpenAI API, with the differences below.

> **Unofficial and unsupported, for local use only.** It's not a Z.ai product and may break without notice. Never expose it to the internet: it has no key by default.

## Connection

- **Base URL:** `https://zcode.orb.local/api/v1` (OrbStack), or `http://localhost:3000/api/v1` on plain Docker, where the port is `ZCODE_PORT`. Always include `/api/v1`, because `/v1` alone is not the API.
- **Auth:** none by default. If the server sets `ZCODE_API_KEY`, send `Authorization: Bearer <key>`. OpenAI SDKs need some `api_key` value, so use any string when there's no key.
- **Headers:** POST requests must send `Content-Type: application/json`. Requests from browser pages are refused unless allowed by the server.
- **Reachable from:** the host machine, and on OrbStack also other OrbStack containers. Nothing beyond that.
- **TLS:** the HTTPS certificate is OrbStack's local CA, which only the Mac's keychain trusts.
  - **Python** on the Mac: works as is.
  - **Node.js:** run with `node --use-system-ca`, or set `NODE_OPTIONS=--use-system-ca`. Otherwise you get `SELF_SIGNED_CERT_IN_CHAIN`.
  - **Other containers** and clients that can't trust it: use `http://zcode.orb.local/api/v1`. The traffic stays on the local machine.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/models` | List models |
| GET | `/models/{id}` | Look up one model (404 if unknown) |
| POST | `/chat/completions` | Chat; set `"stream": true` for SSE |
| POST | `/completions` | Legacy: `prompt` string in, `text` out |
| GET | `/health` | `{"ok", "running", "queued", "agent"}` |

## Models and reasoning

- **Models:** `GLM-5.3-Flash` (the default when `model` is omitted) and `GLM-5.3`. OpenAI SDKs require `model`, so pass it explicitly there. Ids are case-insensitive. Any other id returns 404 `model_not_found`.
- **`reasoning_effort`:** `low`, `medium`, `high` (the default), `xhigh` or `max`. Any other value returns 400.

## Request fields

| Field | Support |
|---|---|
| `messages` | Roles `system`, `developer`, `user`, `assistant` and `tool`. Content is a string or parts: `text`, and `image_url` with a base64 `data:image/...` URL |
| `stream`, `stream_options.include_usage` | Supported |
| `reasoning_effort` | Supported |
| `zcode.session` | ZCode extension. See the Conversations section below |
| `temperature`, `top_p`, `max_tokens`, `stop`, `n`, `tools`, `tool_choice`, `response_format` | **Ignored.** Don't rely on them |

## Responses

- **Shape:** standard `chat.completion` / `chat.completion.chunk` objects, with `finish_reason: "stop"`.
- **Reasoning text:** in `message.reasoning_content` (non-streaming) or `delta.reasoning_content` (streaming), separate from `content`.
- **Extra field:** `"zcode": {"session": "sess_...", "trace_id": "..."}`. When streaming, it's on the final chunk.
- **Usage:** `usage` is included, or when streaming, only if `stream_options.include_usage` is set. About 4k prompt tokens of each request are ZCode's own system prompt.
- **Errors:** JSON `{"error": {"message", "type", "code"}}` with an HTTP status. If an error happens after a stream has started, it arrives as a `data: {"error": ...}` event, followed by `data: [DONE]`.

## Conversations

Each request is one independent turn. Pick one of two ways to continue a conversation:

1. **Resend the full `messages` history** (standard OpenAI). It's flattened into one prompt, limited to about 120 KB.
2. **Cheaper:** take `zcode.session` from the previous response and send it back as `"zcode": {"session": "sess_..."}`. The server sends only the messages after the last `assistant` message, and ZCode supplies the rest from its own session memory.

## Behavior to expect

- **Latency:** the first token takes about 8–12 s, because each request starts a process. Tokens then stream in real time. Set client timeouts of at least 120 s, and up to 600 s for long answers.
- **Concurrency:** about 2 requests run at once and the rest are queued. Avoid large parallel fan-outs.
- **No tool calling:** the model can't call your functions or tools. If you need structured output, ask for JSON in the prompt and parse the reply.
- **It's a coding agent underneath:** it may introduce itself as ZCode. A clear `system` message keeps it on task.

## Errors

| Status | Meaning | What to do |
|---|---|---|
| 400 | Bad JSON, missing `messages`, or invalid `reasoning_effort` | Fix the request |
| 401 | Missing or wrong API key | Send `Authorization: Bearer <key>` |
| 403 | Browser `Origin` not allowed, or agent-only fields sent | Call from a non-browser client and drop `zcode.cwd`/`mode`/`tools` |
| 404 | Unknown model or route | Use `GLM-5.3-Flash` or `GLM-5.3`, under `/api/v1` |
| 413 | Prompt over about 120 KB | Use `zcode.session` or shorten the history |
| 415 | Wrong `Content-Type` | Send `application/json` |
| 502 / 503 | ZCode failed, or isn't logged in (`Select a model before continuing`) | Retry later. A human has to log in to the ZCode desktop app |
| 504 | Run exceeded the server's time limit | Simplify the request |

## Examples

```sh
curl -N https://zcode.orb.local/api/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"stream": true, "messages": [
        {"role": "system", "content": "Answer concisely."},
        {"role": "user", "content": "Explain TCP slow start in two sentences."}]}'
```

```python
from openai import OpenAI

client = OpenAI(base_url="https://zcode.orb.local/api/v1", api_key="unused", timeout=600)

# Streaming
for chunk in client.chat.completions.create(
        model="GLM-5.3-Flash", stream=True,
        messages=[{"role": "user", "content": "Write a haiku about rivers."}]):
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")

# Continue a conversation through its session
first = client.chat.completions.create(
    model="GLM-5.3-Flash",
    messages=[{"role": "user", "content": "Remember the number 42."}])
session = first.model_extra["zcode"]["session"]
follow = client.chat.completions.create(
    model="GLM-5.3-Flash",
    messages=[{"role": "user", "content": "What number did I ask you to remember?"}],
    extra_body={"zcode": {"session": session}})
print(follow.choices[0].message.content)
```

```javascript
import OpenAI from "openai";   // run with: node --use-system-ca app.mjs

const client = new OpenAI({ baseURL: "https://zcode.orb.local/api/v1", apiKey: "unused", timeout: 600_000 });
const res = await client.chat.completions.create({
  model: "GLM-5.3-Flash",
  messages: [{ role: "user", content: "Say hello." }],
  reasoning_effort: "low",
});
console.log(res.choices[0].message.content);
```
