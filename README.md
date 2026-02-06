# Kong Gateway — LLM Proxy (Docker Compose)

A Docker Compose stack that runs **Kong Gateway OSS 3.9.1** as a reverse proxy for LLM inference backends (vLLM, SGLang) with a key-auth protected Admin API.

## Architecture

```
Client → Kong Gateway (port 8000/8443)
              ├── /v1/vllm/*    → vLLM backend (external)
              ├── /v1/sglang/*  → SGLang backend (external)
              └── /admin-api/*  → Kong Admin API (key-auth protected, loopback)
              │
              └── PostgreSQL (internal, port 5432)
```

- **Kong** runs in DB mode with **PostgreSQL 17**
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

### LLM Inference

```bash
# vLLM — chat completions
curl http://localhost:8000/v1/vllm/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# SGLang — chat completions
curl http://localhost:8000/v1/sglang/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# vLLM — list models
curl http://localhost:8000/v1/vllm/v1/models

# SGLang — list models
curl http://localhost:8000/v1/sglang/v1/models
```

Kong strips the `/v1/vllm` or `/v1/sglang` prefix before forwarding, so `GET /v1/vllm/v1/models` becomes `GET /v1/models` on the upstream.

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
