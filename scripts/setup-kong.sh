#!/bin/sh
# =============================================================================
# Kong Gateway — post-startup configuration
# Creates services, routes, and key-auth for the admin API.
# All calls are idempotent (409 conflicts are tolerated on re-runs).
# =============================================================================
set -e

ADMIN="${KONG_ADMIN_URL:-http://kong:8001}"

# -- helpers ------------------------------------------------------------------
call() {
  METHOD="$1"; ENDPOINT="$2"; shift 2
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X "$METHOD" "$ADMIN$ENDPOINT" "$@")
  if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
    echo "[OK]      $METHOD $ENDPOINT ($STATUS)"
  elif [ "$STATUS" -eq 409 ]; then
    echo "[EXISTS]  $METHOD $ENDPOINT ($STATUS)"
  else
    echo "[ERROR]   $METHOD $ENDPOINT ($STATUS)"
    # Print response body for debugging
    curl -s -X "$METHOD" "$ADMIN$ENDPOINT" "$@"
    echo ""
    return 1
  fi
}

echo "=== Kong setup starting ==="
echo "Admin URL:        $ADMIN"
echo "vLLM upstream:    $VLLM_UPSTREAM_URL"
echo "SGLang upstream:  $SGLANG_UPSTREAM_URL"
echo ""

# -- vLLM service + route -----------------------------------------------------
call POST /services \
  -d "name=vllm-service" \
  -d "url=$VLLM_UPSTREAM_URL" \
  -d "read_timeout=120000" \
  -d "write_timeout=120000" \
  -d "connect_timeout=10000"

call POST /services/vllm-service/routes \
  -d "name=vllm-route" \
  -d "paths[]=/v1/vllm" \
  -d "strip_path=true"

# -- SGLang service + route ----------------------------------------------------
call POST /services \
  -d "name=sglang-service" \
  -d "url=$SGLANG_UPSTREAM_URL" \
  -d "read_timeout=120000" \
  -d "write_timeout=120000" \
  -d "connect_timeout=10000"

call POST /services/sglang-service/routes \
  -d "name=sglang-route" \
  -d "paths[]=/v1/sglang" \
  -d "strip_path=true"

# -- Admin API loopback service + route + key-auth ----------------------------
call POST /services \
  -d "name=admin-api-service" \
  -d "url=http://127.0.0.1:8001"

call POST /services/admin-api-service/routes \
  -d "name=admin-api-route" \
  -d "paths[]=/admin-api" \
  -d "strip_path=true"

call POST /services/admin-api-service/plugins \
  -d "name=key-auth"

# -- Admin consumer + API key -------------------------------------------------
call POST /consumers \
  -d "username=admin"

call POST /consumers/admin/key-auth \
  -d "key=$KONG_ADMIN_API_KEY"

echo ""
echo "=== Kong setup complete ==="
