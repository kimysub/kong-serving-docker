#!/bin/sh
# =============================================================================
# Kong Gateway — post-startup configuration
# Creates services, routes, upstreams (load balancing), and key-auth.
# Uses PUT for upsert so the script is fully idempotent.
#
# Backends are configured via:
#   1. Environment variables: VLLM_UPSTREAM_URL, SGLANG_UPSTREAM_URL
#   2. Config file: /config/backends.conf (for extra backends)
#
# Load balancing: use comma-separated URLs for round-robin distribution.
#   Single:  http://host1:8080
#   Balanced: http://host1:8080,http://host2:8080,http://host3:8080
# =============================================================================
set -e

ADMIN="${KONG_ADMIN_URL:-http://kong:8001}"
CONFIG_FILE="/config/backends.conf"

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

exists() {
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ADMIN$1")
  [ "$STATUS" -eq 200 ]
}

# Add a target to an upstream, skip if already present
add_target() {
  UPSTREAM_NAME="$1"; TARGET="$2"
  EXISTING=$(curl -s "$ADMIN/upstreams/$UPSTREAM_NAME/targets")
  if echo "$EXISTING" | grep -q "\"target\":\"$TARGET\""; then
    echo "[EXISTS]  target $TARGET -> $UPSTREAM_NAME"
  else
    call POST "/upstreams/$UPSTREAM_NAME/targets" \
      -d "target=$TARGET" \
      -d "weight=100"
  fi
}

# Setup a backend: single URL → direct service, comma-separated → upstream + targets
setup_backend() {
  NAME="$1"
  URLS="$2"
  TIMEOUT="${3:-120000}"

  SERVICE_NAME="${NAME}-service"
  ROUTE_NAME="${NAME}-route"
  ROUTE_PATH="/v1/${NAME}"

  echo ""
  echo "--- Backend: $NAME ---"

  if echo "$URLS" | grep -q ','; then
    # -- Load balanced mode ----------------------------------------------------
    UPSTREAM_NAME="${NAME}-upstream"

    # Extract protocol from first URL (http or https)
    PROTOCOL=$(echo "$URLS" | cut -d',' -f1 | sed 's|://.*||')
    PROTOCOL="${PROTOCOL:-http}"

    # Create upstream
    call PUT "/upstreams/$UPSTREAM_NAME" \
      -d "name=$UPSTREAM_NAME"

    # Add each target (host:port extracted from URLs)
    OLD_IFS="$IFS"
    IFS=','
    for URL in $URLS; do
      TARGET=$(echo "$URL" | sed 's|https\?://||' | sed 's|/.*||')
      add_target "$UPSTREAM_NAME" "$TARGET"
    done
    IFS="$OLD_IFS"

    # Service points to upstream name (Kong resolves it internally)
    call PUT "/services/$SERVICE_NAME" \
      -d "name=$SERVICE_NAME" \
      -d "protocol=$PROTOCOL" \
      -d "host=$UPSTREAM_NAME" \
      -d "read_timeout=$TIMEOUT" \
      -d "write_timeout=$TIMEOUT" \
      -d "connect_timeout=10000"
  else
    # -- Single backend mode ---------------------------------------------------
    call PUT "/services/$SERVICE_NAME" \
      -d "name=$SERVICE_NAME" \
      -d "url=$URLS" \
      -d "read_timeout=$TIMEOUT" \
      -d "write_timeout=$TIMEOUT" \
      -d "connect_timeout=10000"
  fi

  # Route
  call PUT "/services/$SERVICE_NAME/routes/$ROUTE_NAME" \
    -d "name=$ROUTE_NAME" \
    -d "paths[]=$ROUTE_PATH" \
    -d "strip_path=true"
}

# =============================================================================
echo "=== Kong setup starting ==="
echo "Admin URL: $ADMIN"
echo ""

# -- Default backends from environment variables -------------------------------
if [ -n "$VLLM_UPSTREAM_URL" ]; then
  setup_backend "vllm" "$VLLM_UPSTREAM_URL" "120000"
fi

if [ -n "$SGLANG_UPSTREAM_URL" ]; then
  setup_backend "sglang" "$SGLANG_UPSTREAM_URL" "120000"
fi

# -- Extra backends from config file -------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
  echo ""
  echo "--- Loading extra backends from $CONFIG_FILE ---"
  while IFS='|' read -r NAME URLS TIMEOUT || [ -n "$NAME" ]; do
    # Skip comments and empty lines
    case "$NAME" in \#*|"") continue ;; esac
    setup_backend "$NAME" "$URLS" "${TIMEOUT:-120000}"
  done < "$CONFIG_FILE"
else
  echo ""
  echo "[INFO]    No config file found at $CONFIG_FILE (optional)"
fi

# -- Admin API loopback service + route + key-auth -----------------------------
echo ""
echo "--- Admin API ---"

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

EXISTING_KEYS=$(curl -s "$ADMIN/consumers/admin/key-auth" | grep -c '"key"' || true)
if [ "$EXISTING_KEYS" -gt 0 ]; then
  echo "[EXISTS]  API key for consumer admin"
else
  call POST /consumers/admin/key-auth -d "key=$KONG_ADMIN_API_KEY"
fi

echo ""
echo "=== Kong setup complete ==="
