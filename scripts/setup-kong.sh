#!/bin/sh
# =============================================================================
# Kong Gateway — post-startup configuration
# Creates services, routes, and key-auth for the admin API.
# Uses PUT for upsert (create-or-update) so the script is fully idempotent.
# =============================================================================
set -e

ADMIN="${KONG_ADMIN_URL:-http://kong:8001}"

# -- helpers ------------------------------------------------------------------
call() {
  METHOD="$1"; ENDPOINT="$2"; shift 2
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X "$METHOD" "$ADMIN$ENDPOINT" "$@")
  if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
    echo "[OK]      $METHOD $ENDPOINT ($STATUS)"
  else
    echo "[ERROR]   $METHOD $ENDPOINT ($STATUS)"
    curl -s -X "$METHOD" "$ADMIN$ENDPOINT" "$@"
    echo ""
    return 1
  fi
}

# Check if a resource exists (GET returns 200)
exists() {
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ADMIN$1")
  [ "$STATUS" -eq 200 ]
}

echo "=== Kong setup starting ==="
echo "Admin URL:        $ADMIN"
echo "vLLM upstream:    $VLLM_UPSTREAM_URL"
echo "SGLang upstream:  $SGLANG_UPSTREAM_URL"
echo ""

# -- vLLM service + route -----------------------------------------------------
call PUT /services/vllm-service \
  -d "name=vllm-service" \
  -d "url=$VLLM_UPSTREAM_URL" \
  -d "read_timeout=120000" \
  -d "write_timeout=120000" \
  -d "connect_timeout=10000"

call PUT /services/vllm-service/routes/vllm-route \
  -d "name=vllm-route" \
  -d "paths[]=/v1/vllm" \
  -d "strip_path=true"

# -- SGLang service + route ----------------------------------------------------
call PUT /services/sglang-service \
  -d "name=sglang-service" \
  -d "url=$SGLANG_UPSTREAM_URL" \
  -d "read_timeout=120000" \
  -d "write_timeout=120000" \
  -d "connect_timeout=10000"

call PUT /services/sglang-service/routes/sglang-route \
  -d "name=sglang-route" \
  -d "paths[]=/v1/sglang" \
  -d "strip_path=true"

# -- Admin API loopback service + route + key-auth ----------------------------
call PUT /services/admin-api-service \
  -d "name=admin-api-service" \
  -d "url=http://127.0.0.1:8001"

call PUT /services/admin-api-service/routes/admin-api-route \
  -d "name=admin-api-route" \
  -d "paths[]=/admin-api" \
  -d "strip_path=true"

# key-auth plugin — check first since plugins don't support PUT-by-name upsert
if exists "/services/admin-api-service/plugins"; then
  KEY_AUTH_EXISTS=$(curl -s "$ADMIN/services/admin-api-service/plugins" | grep -c '"name":"key-auth"' || true)
  if [ "$KEY_AUTH_EXISTS" -gt 0 ]; then
    echo "[EXISTS]  key-auth plugin on admin-api-service"
  else
    call POST /services/admin-api-service/plugins -d "name=key-auth"
  fi
else
  call POST /services/admin-api-service/plugins -d "name=key-auth"
fi

# -- Admin consumer + API key -------------------------------------------------
call PUT /consumers/admin \
  -d "username=admin"

# API key — check if one already exists for this consumer
EXISTING_KEYS=$(curl -s "$ADMIN/consumers/admin/key-auth" | grep -c '"key"' || true)
if [ "$EXISTING_KEYS" -gt 0 ]; then
  echo "[EXISTS]  API key for consumer admin"
else
  call POST /consumers/admin/key-auth -d "key=$KONG_ADMIN_API_KEY"
fi

echo ""
echo "=== Kong setup complete ==="
