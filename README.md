# Kong Gateway — LLM Proxy (Docker Compose)

A Docker Compose stack that runs **Kong Gateway OSS 3.9.1** as a reverse proxy for LLM inference backends (vLLM, SGLang) with a key-auth protected Admin API.

## Architecture

```
Client → Kong Gateway (port 8000/8443)
              ├── /v1/*          → Unified endpoint (routes by model name)
              ├── /v1/vllm/*     → vLLM backend (direct)
              ├── /v1/sglang/*   → SGLang backend (direct)
              └── /admin-api/*   → Kong Admin API (key-auth protected, loopback)
              │
              └── PostgreSQL (internal, port 5432)
```

- **Kong** runs in DB mode with **PostgreSQL 17**
- **Unified endpoint** (`/v1/*`) reads the `model` field and routes to the correct backend — works like the OpenAI API
- **Direct endpoints** (`/v1/vllm/*`, `/v1/sglang/*`) route by URL prefix to a specific backend
- Admin API listens on `0.0.0.0:8001` inside the container but is **not exposed** to the host
- Admin access is available via the `/admin-api` route, protected by `key-auth`
- LLM backends run outside the compose stack and are configured via environment variables

## Prerequisites

- Docker Engine 20.10+ and Docker Compose V2
- LLM backends (vLLM and/or SGLang) running and accessible from the Docker host

## Quick Start

```bash
# 1. Clone the repository
git clone <repo-url> && cd kong-serving-docker

# 2. Copy the example env file
cp .env.example .env

# 3. (Optional) Change the default postgres password
echo 'my-secure-password' > POSTGRES_PASSWORD

# 4. Edit .env — set your backend URLs and admin API key
#    VLLM_UPSTREAM_URL=http://host.docker.internal:8080
#    SGLANG_UPSTREAM_URL=http://host.docker.internal:30000
#    KONG_ADMIN_API_KEY=your-secret-key

# 5. Start the stack
docker compose up -d

# 6. Verify
docker compose ps          # all services healthy
docker compose logs kong-setup  # setup script output
```

## Configuration

All configuration is done through environment variables in `.env` (copy from `.env.example`).

| Variable | Default | Description |
|---|---|---|
| `KONG_VERSION` | `3.9.1` | Kong Gateway image tag |
| `KONG_PG_DATABASE` | `kong` | PostgreSQL database name |
| `KONG_PG_USER` | `kong` | PostgreSQL user |
| `KONG_PROXY_PORT` | `8000` | Host port for Kong HTTP proxy |
| `KONG_PROXY_SSL_PORT` | `8443` | Host port for Kong HTTPS proxy |
| `POSTGRES_PORT` | `5432` | Host port for PostgreSQL |
| `VLLM_UPSTREAM_URL` | `http://host.docker.internal:8080` | vLLM backend URL |
| `SGLANG_UPSTREAM_URL` | `http://host.docker.internal:30000` | SGLang backend URL |
| `KONG_ADMIN_API_KEY` | `changeme-admin-key-secret` | API key for `/admin-api` route |

The PostgreSQL password is stored in the `POSTGRES_PASSWORD` file (used as a Docker secret). This file is gitignored.

## Usage

### Unified Endpoint (Recommended)

The unified `/v1/*` endpoint routes requests by the `model` field in the request body — works just like the OpenAI API:

```bash
# Chat completions — routes to the correct backend based on the model
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.1-70B-Instruct",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

Configure model-to-backend mappings in `config/model-routes.conf`:

```
model_name|backend_name
meta-llama/Llama-3.1-70B-Instruct|vllm
mistralai/Mistral-7B-Instruct-v0.3|sglang
```

After editing, restart the setup container: `docker compose restart kong-setup`

### Direct Backend Endpoints

Access a specific backend directly by URL prefix:

```bash
# vLLM — chat completions
curl http://localhost:8000/v1/vllm/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# SGLang — chat completions
curl http://localhost:8000/v1/sglang/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# vLLM — list models
curl http://localhost:8000/v1/vllm/models

# SGLang — list models
curl http://localhost:8000/v1/sglang/models
```

Kong strips the `/v1/{name}` prefix and prepends the service path `/v1`, so `GET /v1/vllm/models` becomes `GET /v1/models` on the upstream.

### Admin API

The Kong Admin API is accessible through the `/admin-api` route with a required API key:

```bash
# Without key → 401 Unauthorized
curl -i http://localhost:8000/admin-api/services

# With key → 200 OK
curl -i "http://localhost:8000/admin-api/services?apikey=changeme-admin-key-secret"

# Or via header
curl -i http://localhost:8000/admin-api/services \
  -H "apikey: changeme-admin-key-secret"
```

The Admin API port (8001) is **not exposed** to the host. Direct access via `localhost:8001` will fail by design.

## Troubleshooting

### Port conflict with vLLM

vLLM defaults to port 8000, which conflicts with Kong's proxy port. Solutions:

1. Start vLLM on a different port (e.g., `--port 8080`) and set `VLLM_UPSTREAM_URL=http://host.docker.internal:8080`
2. Or change Kong's proxy port: `KONG_PROXY_PORT=9000` in `.env`

### Timeouts for large models

LLM services are configured with 120-second read/write timeouts. For larger models that need more time:

```bash
# Increase timeout via Admin API (value in milliseconds)
curl -X PATCH "http://localhost:8000/admin-api/services/vllm-service?apikey=YOUR_KEY" \
  -d "read_timeout=300000" \
  -d "write_timeout=300000"
```

### SSE streaming

Kong proxies Server-Sent Events (SSE) correctly by default. Ensure the read timeout covers the full streaming duration for long-running generation requests.

### Setup script failed

```bash
# Check the setup logs
docker compose logs kong-setup

# Re-run setup (idempotent — safe to run multiple times)
docker compose restart kong-setup
```

### Linux: host.docker.internal not resolving

The compose file includes `extra_hosts: host.docker.internal:host-gateway` on the Kong service. If your backend URLs use `host.docker.internal` and it still doesn't resolve, ensure you're on Docker 20.10+.
