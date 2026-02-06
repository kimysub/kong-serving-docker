# Kong Usage Guide

A beginner-friendly guide to using Kong Gateway as an LLM proxy. This guide assumes you have already completed the [Quick Setup Guide](QUICKSETUP_GUIDE.md) and Kong is running.

## How Kong Works (The Basics)

Kong is a **reverse proxy**. It sits between your application and your LLM backends, forwarding requests to the right place.

```
Your App                        Kong                         LLM Backend
   │                             │                              │
   ├── POST /v1/vllm/v1/chat ──►├── strips "/v1/vllm" ──────► │ POST /v1/chat
   │                             │   forwards to vLLM           │
   │                             │                              │
   ├── POST /v1/sglang/v1/chat ►├── strips "/v1/sglang" ─────► │ POST /v1/chat
   │                             │   forwards to SGLang         │
   │                             │                              │
   └── GET /admin-api/services ►├── checks API key ──────────► │ Kong Admin API
                                 │   (key-auth plugin)          │ (internal)
```

### Key Concepts

| Concept | What It Is | Example |
|---|---|---|
| **Service** | A backend your API talks to | `vllm-service` pointing to `http://host.docker.internal:8080` |
| **Route** | A URL path that maps to a service | `/v1/vllm` maps to `vllm-service` |
| **Plugin** | Middleware that adds behavior | `key-auth` on `admin-api-service` requires an API key |
| **Consumer** | A user/application identity | `admin` consumer with an API key |
| **Upstream** | The actual backend URL | `http://host.docker.internal:8080` |

## Pre-Configured Routes

This stack comes with three routes already configured:

| Route | Backend | Auth Required? | Purpose |
|---|---|---|---|
| `/v1/vllm/*` | vLLM server | No | LLM inference via vLLM |
| `/v1/sglang/*` | SGLang server | No | LLM inference via SGLang |
| `/admin-api/*` | Kong Admin API | Yes (API key) | Manage Kong configuration |

## Making LLM Requests

### Chat Completions

```bash
# vLLM
curl http://localhost:8000/v1/vllm/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What is Docker?"}
    ]
  }'

# SGLang
curl http://localhost:8000/v1/sglang/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [
      {"role": "user", "content": "What is Docker?"}
    ]
  }'
```

### Streaming Responses

Add `"stream": true` to get Server-Sent Events (SSE):

```bash
curl http://localhost:8000/v1/vllm/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [{"role": "user", "content": "Tell me a story"}],
    "stream": true
  }'
```

Kong passes SSE streams through correctly. For very long generations, you may need to increase the read timeout (see [Changing Timeouts](#changing-timeouts)).

### List Available Models

```bash
# vLLM models
curl http://localhost:8000/v1/vllm/v1/models

# SGLang models
curl http://localhost:8000/v1/sglang/v1/models
```

### Text Completions

```bash
curl http://localhost:8000/v1/vllm/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "prompt": "The capital of France is"
  }'
```

### Embeddings

```bash
curl http://localhost:8000/v1/vllm/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "input": "Hello world"
  }'
```

### How Path Stripping Works

Kong removes the route prefix before forwarding. Here is how paths map:

| You Send | Kong Forwards |
|---|---|
| `GET /v1/vllm/v1/models` | `GET /v1/models` to vLLM |
| `POST /v1/vllm/v1/chat/completions` | `POST /v1/chat/completions` to vLLM |
| `POST /v1/sglang/v1/completions` | `POST /v1/completions` to SGLang |
| `GET /admin-api/services` | `GET /services` to Admin API |

## Using the Admin API

The Admin API lets you view and change Kong's configuration. It requires an API key.

### Passing the API Key

You can pass the key in two ways:

```bash
# As a query parameter
curl "http://localhost:8000/admin-api/services?apikey=YOUR_KEY"

# As a header (recommended for production)
curl http://localhost:8000/admin-api/services \
  -H "apikey: YOUR_KEY"
```

Replace `YOUR_KEY` with the value of `KONG_ADMIN_API_KEY` from your `.env` file.

### View All Services

```bash
curl -s "http://localhost:8000/admin-api/services?apikey=YOUR_KEY" | python3 -m json.tool
```

### View All Routes

```bash
curl -s "http://localhost:8000/admin-api/routes?apikey=YOUR_KEY" | python3 -m json.tool
```

### View All Plugins

```bash
curl -s "http://localhost:8000/admin-api/plugins?apikey=YOUR_KEY" | python3 -m json.tool
```

### View a Specific Service

```bash
curl -s "http://localhost:8000/admin-api/services/vllm-service?apikey=YOUR_KEY" | python3 -m json.tool
```

## Common Admin Tasks

### Changing Timeouts

LLM inference can be slow for large models. The default timeout is 120 seconds. To increase:

```bash
# Set vLLM timeout to 5 minutes (300000 milliseconds)
curl -X PATCH "http://localhost:8000/admin-api/services/vllm-service" \
  -H "apikey: YOUR_KEY" \
  -d "read_timeout=300000" \
  -d "write_timeout=300000"

# Set SGLang timeout to 5 minutes
curl -X PATCH "http://localhost:8000/admin-api/services/sglang-service" \
  -H "apikey: YOUR_KEY" \
  -d "read_timeout=300000" \
  -d "write_timeout=300000"
```

### Changing a Backend URL

If your LLM backend moves to a different address:

```bash
# Update vLLM backend URL
curl -X PATCH "http://localhost:8000/admin-api/services/vllm-service" \
  -H "apikey: YOUR_KEY" \
  -d "url=http://new-host:8080"
```

This takes effect immediately — no restart needed.

### Adding a New LLM Backend

To add a third LLM backend (e.g., an Ollama server):

```bash
# 1. Create the service
curl -X POST "http://localhost:8000/admin-api/services" \
  -H "apikey: YOUR_KEY" \
  -d "name=ollama-service" \
  -d "url=http://host.docker.internal:11434" \
  -d "read_timeout=120000" \
  -d "write_timeout=120000"

# 2. Create a route for it
curl -X POST "http://localhost:8000/admin-api/services/ollama-service/routes" \
  -H "apikey: YOUR_KEY" \
  -d "name=ollama-route" \
  -d "paths[]=/v1/ollama" \
  -d "strip_path=true"
```

Now you can reach Ollama at `http://localhost:8000/v1/ollama/...`.

### Adding Rate Limiting to a Service

To prevent a service from being overloaded:

```bash
curl -X POST "http://localhost:8000/admin-api/services/vllm-service/plugins" \
  -H "apikey: YOUR_KEY" \
  -d "name=rate-limiting" \
  -d "config.minute=60" \
  -d "config.policy=local"
```

This limits the vLLM route to 60 requests per minute.

### Removing a Service

```bash
# First delete the route
curl -X DELETE "http://localhost:8000/admin-api/routes/ollama-route" \
  -H "apikey: YOUR_KEY"

# Then delete the service
curl -X DELETE "http://localhost:8000/admin-api/services/ollama-service" \
  -H "apikey: YOUR_KEY"
```

### Adding Request Authentication to LLM Routes

By default, LLM routes have no authentication. To require an API key:

```bash
# 1. Add key-auth plugin to vLLM service
curl -X POST "http://localhost:8000/admin-api/services/vllm-service/plugins" \
  -H "apikey: YOUR_KEY" \
  -d "name=key-auth"

# 2. Create a consumer for your application
curl -X POST "http://localhost:8000/admin-api/consumers" \
  -H "apikey: YOUR_KEY" \
  -d "username=my-app"

# 3. Generate an API key for the consumer
curl -X POST "http://localhost:8000/admin-api/consumers/my-app/key-auth" \
  -H "apikey: YOUR_KEY" \
  -d "key=my-app-secret-key"
```

Now vLLM requests require the key:

```bash
curl http://localhost:8000/v1/vllm/v1/models \
  -H "apikey: my-app-secret-key"
```

## Using Kong with Python (OpenAI SDK)

Since vLLM and SGLang are OpenAI-compatible, you can use the OpenAI Python SDK with Kong as the base URL:

```python
from openai import OpenAI

# Point the OpenAI client at Kong's vLLM route
client = OpenAI(
    base_url="http://localhost:8000/v1/vllm/v1",
    api_key="not-needed",  # unless you added key-auth to vLLM
)

response = client.chat.completions.create(
    model="your-model-name",
    messages=[
        {"role": "user", "content": "Hello!"}
    ],
)
print(response.choices[0].message.content)
```

For SGLang, change the `base_url`:

```python
client = OpenAI(
    base_url="http://localhost:8000/v1/sglang/v1",
    api_key="not-needed",
)
```

If you added `key-auth` to the LLM routes, pass the API key:

```python
client = OpenAI(
    base_url="http://localhost:8000/v1/vllm/v1",
    api_key="my-app-secret-key",  # used as the apikey header
    default_headers={"apikey": "my-app-secret-key"},
)
```

## Monitoring and Debugging

### Check Kong Status

```bash
# Is Kong running and healthy?
docker compose ps kong

# Kong's internal status (via admin API)
curl -s "http://localhost:8000/admin-api/?apikey=YOUR_KEY" | python3 -m json.tool
```

### View Request Logs

```bash
# Real-time proxy logs (shows all requests passing through Kong)
docker compose logs -f kong
```

Each log line shows the request method, path, status code, and latency.

### Debug a 502 Bad Gateway

A 502 means Kong cannot reach the upstream backend.

```bash
# 1. Check the service configuration
curl -s "http://localhost:8000/admin-api/services/vllm-service?apikey=YOUR_KEY" | python3 -m json.tool

# 2. Verify the backend is running
curl http://localhost:8080/v1/models  # adjust port to match your vLLM

# 3. If using host.docker.internal, verify it resolves inside the container
docker compose exec kong nslookup host.docker.internal
```

### Debug a 404 Not Found

A 404 means no route matches the path you requested.

```bash
# List all routes to check paths
curl -s "http://localhost:8000/admin-api/routes?apikey=YOUR_KEY" | python3 -m json.tool
```

Make sure your request path starts with one of the configured route prefixes (`/v1/vllm`, `/v1/sglang`, or `/admin-api`).

## Quick Reference

| Task | Command |
|---|---|
| List services | `curl "http://localhost:8000/admin-api/services?apikey=KEY"` |
| List routes | `curl "http://localhost:8000/admin-api/routes?apikey=KEY"` |
| List plugins | `curl "http://localhost:8000/admin-api/plugins?apikey=KEY"` |
| List consumers | `curl "http://localhost:8000/admin-api/consumers?apikey=KEY"` |
| Update a service | `curl -X PATCH "http://localhost:8000/admin-api/services/NAME?apikey=KEY" -d "key=value"` |
| Delete a route | `curl -X DELETE "http://localhost:8000/admin-api/routes/NAME?apikey=KEY"` |
| Delete a service | `curl -X DELETE "http://localhost:8000/admin-api/services/NAME?apikey=KEY"` |
| Kong health | `docker compose ps kong` |
| Kong logs | `docker compose logs -f kong` |
| Restart Kong | `docker compose restart kong` |
| Restart setup | `docker compose restart kong-setup` |
