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
| **Upstream** | A group of backend targets for load balancing | `vllm-upstream` with 3 GPU server targets |
| **Target** | A single backend instance inside an upstream | `gpu-server1:8080` with weight 100 |

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

## Adding Multiple Backends (Different Models)

There are two ways to add backends: via config file (persistent across restarts) or via Admin API (immediate, runtime).

### Method 1: Config File (Recommended for Permanent Backends)

Edit `config/backends.conf` to add backends that are set up automatically on every start:

```bash
cp config/backends.conf.example config/backends.conf
```

Each line follows the format `name|url|timeout_ms`:

```
# Ollama server for local models
ollama|http://host.docker.internal:11434|120000

# vLLM running a code generation model
vllm-codegen|http://host.docker.internal:8090|120000

# Text Generation Inference (TGI)
tgi|http://host.docker.internal:8082|120000
```

Then restart the setup container:

```bash
docker compose restart kong-setup
```

This creates:
- `/v1/ollama/*` routing to your Ollama server
- `/v1/vllm-codegen/*` routing to your code generation vLLM
- `/v1/tgi/*` routing to your TGI server

### Method 2: Admin API (For Dynamic/Temporary Backends)

Add a backend at runtime without editing any files:

```bash
# 1. Create the service
curl -X PUT "http://localhost:8000/admin-api/services/ollama-service" \
  -H "apikey: YOUR_KEY" \
  -d "name=ollama-service" \
  -d "url=http://host.docker.internal:11434" \
  -d "read_timeout=120000" \
  -d "write_timeout=120000"

# 2. Create a route for it
curl -X PUT "http://localhost:8000/admin-api/services/ollama-service/routes/ollama-route" \
  -H "apikey: YOUR_KEY" \
  -d "name=ollama-route" \
  -d "paths[]=/v1/ollama" \
  -d "strip_path=true"
```

Now you can reach Ollama at `http://localhost:8000/v1/ollama/...`. This takes effect immediately.

## Load Balancing (Same Model, Multiple Instances)

When you have multiple instances serving the **same model**, Kong can distribute requests across them using round-robin.

### Method 1: Config File (Comma-Separated URLs)

In `.env`, use comma-separated URLs:

```bash
# Load balance vLLM across 3 GPU servers
VLLM_UPSTREAM_URL=http://gpu-server1:8080,http://gpu-server2:8080,http://gpu-server3:8080
```

Or in `config/backends.conf`:

```
# Load balanced vLLM cluster
vllm-cluster|http://gpu-server1:8080,http://gpu-server2:8080,http://gpu-server3:8080|180000
```

Then restart:

```bash
docker compose restart kong-setup
```

The setup script automatically creates a Kong **upstream** with **targets** for each URL.

### Method 2: Admin API (Runtime Load Balancing)

Set up load balancing dynamically:

```bash
# 1. Create an upstream (the load balancer group)
curl -X PUT "http://localhost:8000/admin-api/upstreams/vllm-upstream" \
  -H "apikey: YOUR_KEY" \
  -d "name=vllm-upstream"

# 2. Add targets (each backend instance)
curl -X POST "http://localhost:8000/admin-api/upstreams/vllm-upstream/targets" \
  -H "apikey: YOUR_KEY" \
  -d "target=gpu-server1:8080" \
  -d "weight=100"

curl -X POST "http://localhost:8000/admin-api/upstreams/vllm-upstream/targets" \
  -H "apikey: YOUR_KEY" \
  -d "target=gpu-server2:8080" \
  -d "weight=100"

curl -X POST "http://localhost:8000/admin-api/upstreams/vllm-upstream/targets" \
  -H "apikey: YOUR_KEY" \
  -d "target=gpu-server3:8080" \
  -d "weight=100"

# 3. Point the service to the upstream (instead of a direct URL)
curl -X PATCH "http://localhost:8000/admin-api/services/vllm-service" \
  -H "apikey: YOUR_KEY" \
  -d "host=vllm-upstream" \
  -d "protocol=http"
```

Now every request to `/v1/vllm/*` is distributed across all three servers.

### Managing Targets

```bash
# List all targets in an upstream
curl -s "http://localhost:8000/admin-api/upstreams/vllm-upstream/targets?apikey=YOUR_KEY" \
  | python3 -m json.tool

# Add a new target (scales out)
curl -X POST "http://localhost:8000/admin-api/upstreams/vllm-upstream/targets" \
  -H "apikey: YOUR_KEY" \
  -d "target=gpu-server4:8080" \
  -d "weight=100"

# Remove a target (set weight to 0)
curl -X POST "http://localhost:8000/admin-api/upstreams/vllm-upstream/targets" \
  -H "apikey: YOUR_KEY" \
  -d "target=gpu-server2:8080" \
  -d "weight=0"

# Check health of all targets
curl -s "http://localhost:8000/admin-api/upstreams/vllm-upstream/health?apikey=YOUR_KEY" \
  | python3 -m json.tool
```

### Weighted Load Balancing

Assign different weights to send more traffic to stronger servers:

```bash
# Powerful GPU server gets 3x the traffic
curl -X POST "http://localhost:8000/admin-api/upstreams/vllm-upstream/targets" \
  -H "apikey: YOUR_KEY" \
  -d "target=powerful-gpu:8080" \
  -d "weight=300"

# Standard GPU server gets normal traffic
curl -X POST "http://localhost:8000/admin-api/upstreams/vllm-upstream/targets" \
  -H "apikey: YOUR_KEY" \
  -d "target=standard-gpu:8080" \
  -d "weight=100"
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
| List upstreams | `curl "http://localhost:8000/admin-api/upstreams?apikey=KEY"` |
| List targets | `curl "http://localhost:8000/admin-api/upstreams/NAME-upstream/targets?apikey=KEY"` |
| Target health | `curl "http://localhost:8000/admin-api/upstreams/NAME-upstream/health?apikey=KEY"` |
| Add a target | `curl -X POST "http://localhost:8000/admin-api/upstreams/NAME-upstream/targets" -H "apikey: KEY" -d "target=host:port" -d "weight=100"` |
| Remove a target | `curl -X POST "http://localhost:8000/admin-api/upstreams/NAME-upstream/targets" -H "apikey: KEY" -d "target=host:port" -d "weight=0"` |
| Update a service | `curl -X PATCH "http://localhost:8000/admin-api/services/NAME?apikey=KEY" -d "key=value"` |
| Delete a route | `curl -X DELETE "http://localhost:8000/admin-api/routes/NAME?apikey=KEY"` |
| Delete a service | `curl -X DELETE "http://localhost:8000/admin-api/services/NAME?apikey=KEY"` |
| Kong health | `docker compose ps kong` |
| Kong logs | `docker compose logs -f kong` |
| Restart Kong | `docker compose restart kong` |
| Restart setup | `docker compose restart kong-setup` |
