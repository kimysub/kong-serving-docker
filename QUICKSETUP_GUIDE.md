# Quick Setup Guide

A step-by-step guide to get Kong Gateway running as an LLM proxy on your machine. No prior Kong or Docker Compose experience required.

## What You Will Get

After following this guide, you will have:

- A **Kong Gateway** that routes your API requests to LLM backends (vLLM, SGLang)
- A **PostgreSQL** database that stores Kong's configuration
- A **protected Admin API** so only you can change Kong settings

```
Your app  ──request──►  Kong (port 8000)  ──forward──►  vLLM / SGLang
```

## Prerequisites

Before you start, make sure you have these installed:

### 1. Docker Desktop (or Docker Engine)

Check if Docker is installed:

```bash
docker --version
# Expected: Docker version 20.10 or higher
```

If not installed:
- **macOS / Windows**: Download [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- **Linux**: Follow the [Docker Engine install guide](https://docs.docker.com/engine/install/)

### 2. Docker Compose V2

Docker Compose usually comes with Docker Desktop. Verify:

```bash
docker compose version
# Expected: Docker Compose version v2.x.x
```

> **Note**: We use `docker compose` (with a space), not the older `docker-compose` (with a hyphen).

### 3. An LLM Backend (Optional for Initial Setup)

You can start Kong without a running LLM backend. Routes will return `502 Bad Gateway` until a backend is available, but everything else will work.

## Setup Steps

### Step 1: Get the Project

```bash
git clone <repo-url>
cd kong-serving-docker
```

### Step 2: Create Your `.env` File

Copy the example configuration:

```bash
cp .env.example .env
```

This creates a `.env` file with sensible defaults. You can edit it later.

### Step 3: Set the Database Password

The file `POSTGRES_PASSWORD` already has a default password. For production use, change it:

```bash
echo 'pick-a-strong-password-here' > POSTGRES_PASSWORD
```

> This file is gitignored so your password will not be committed.

### Step 4: Configure Your LLM Backends (Edit `.env`)

Open `.env` in any text editor and set the URLs where your LLM backends are running:

```bash
# If vLLM is running on port 8080 on the same machine:
VLLM_UPSTREAM_URL=http://host.docker.internal:8080

# If SGLang is running on port 30000 on the same machine:
SGLANG_UPSTREAM_URL=http://host.docker.internal:30000
```

**What is `host.docker.internal`?** It is a special DNS name that lets containers reach services running on your host machine. Docker resolves this automatically.

**Port conflict warning**: Both Kong and vLLM default to port 8000. If your vLLM uses port 8000, either:
- Start vLLM on a different port: `--port 8080`
- Or change Kong's port in `.env`: `KONG_PROXY_PORT=9000`

### Step 5: Set Your Admin API Key

In `.env`, change the default admin key:

```bash
KONG_ADMIN_API_KEY=my-secret-admin-key
```

This key protects the `/admin-api` route. Anyone with this key can modify Kong's configuration.

### Step 6: Start Everything

```bash
docker compose up -d
```

This command:
1. Downloads the Docker images (first run only, may take a few minutes)
2. Starts PostgreSQL and waits for it to be ready
3. Runs database migrations
4. Starts Kong Gateway
5. Runs the setup script to configure routes and authentication

### Step 7: Verify It Works

Wait about 30 seconds for all services to start, then:

```bash
# Check all containers are running and healthy
docker compose ps
```

You should see output like:

```
NAME                STATUS
kong-db             running (healthy)
kong                running (healthy)
kong-migrations     exited (0)       ← Normal! This only runs once.
kong-migrations-up  exited (0)       ← Normal! This only runs once.
kong-setup          exited (0)       ← Normal! This runs once at startup.
```

Check the setup script completed successfully:

```bash
docker compose logs kong-setup
```

You should see lines like:

```
[OK]      POST /services (201)
[OK]      POST /services/vllm-service/routes (201)
...
=== Kong setup complete ===
```

### Step 8: Test Your Routes

```bash
# Test admin API without key → should return 401
curl -i http://localhost:8000/admin-api/services

# Test admin API with key → should return 200
curl -i "http://localhost:8000/admin-api/services?apikey=my-secret-admin-key"

# Test vLLM route (502 is expected if vLLM is not running)
curl -i http://localhost:8000/v1/vllm/v1/models

# Test SGLang route (502 is expected if SGLang is not running)
curl -i http://localhost:8000/v1/sglang/v1/models
```

- **401** on `/admin-api` without a key = auth is working
- **200** on `/admin-api` with a key = admin access works
- **502** on LLM routes = Kong is routing correctly but the backend is not reachable
- **200** on LLM routes = everything is connected

## Common Tasks

### Stop the Stack

```bash
docker compose down
```

Your data is preserved in the Docker volume. Next time you run `docker compose up -d`, everything will start with your existing configuration.

### Stop and Delete Everything (including data)

```bash
docker compose down -v
```

The `-v` flag removes the PostgreSQL volume. You will need to run migrations again on the next start.

### View Logs

```bash
# All services
docker compose logs

# Only Kong
docker compose logs kong

# Follow logs in real time
docker compose logs -f kong
```

### Restart After Changing `.env`

```bash
docker compose down && docker compose up -d
```

> Changing `.env` requires restarting the containers for new values to take effect.

## What's Next?

- Read the [Kong Usage Guide](KONG_USAGE_GUIDE.md) to learn how to manage services, routes, and plugins
- Read the [README](README.md) for the full configuration reference and troubleshooting tips
