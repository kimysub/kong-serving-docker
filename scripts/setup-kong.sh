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
MODEL_CONFIG="/config/model-routes.conf"

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
    # path=/v1 ensures the /v1 prefix is preserved after strip_path removes /v1/{name}
    call PUT "/services/$SERVICE_NAME" \
      -d "name=$SERVICE_NAME" \
      -d "protocol=$PROTOCOL" \
      -d "host=$UPSTREAM_NAME" \
      -d "path=/v1" \
      -d "read_timeout=$TIMEOUT" \
      -d "write_timeout=$TIMEOUT" \
      -d "connect_timeout=10000"
  else
    # -- Single backend mode ---------------------------------------------------
    # Parse URL components and set path=/v1 so the /v1 prefix is preserved
    # after strip_path removes the /v1/{name} route prefix.
    # e.g., /v1/vllm/chat/completions → strip /v1/vllm → /chat/completions
    #        → prepend service path /v1 → /v1/chat/completions (correct!)
    SVC_PROTO=$(echo "$URLS" | cut -d: -f1)
    SVC_HOSTPORT=$(echo "$URLS" | sed 's|.*://||' | sed 's|/.*||')
    SVC_HOST=$(echo "$SVC_HOSTPORT" | cut -d: -f1)
    SVC_PORT=$(echo "$SVC_HOSTPORT" | cut -d: -f2 -s)
    URL_PATH=$(echo "$URLS" | sed 's|.*://[^/]*||')
    if [ -z "$URL_PATH" ] || [ "$URL_PATH" = "/" ]; then
      URL_PATH="/v1"
    fi

    call PUT "/services/$SERVICE_NAME" \
      -d "name=$SERVICE_NAME" \
      -d "protocol=${SVC_PROTO:-http}" \
      -d "host=$SVC_HOST" \
      -d "port=${SVC_PORT:-80}" \
      -d "path=$URL_PATH" \
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

# -- Unified /v1 endpoint (model-based routing via pre-function plugin) --------
if [ -f "$MODEL_CONFIG" ]; then
  echo ""
  echo "--- Unified LLM Endpoint (/v1) ---"

  # Build the Lua model-routing table by resolving each backend
  LUA_MAP=""
  DEFAULT_BACKEND=""

  while IFS='|' read -r MODEL_NAME BACKEND REAL_MODEL || [ -n "$MODEL_NAME" ]; do
    # Skip comments and empty lines
    case "$MODEL_NAME" in \#*|"") continue ;; esac

    # Strip whitespace/CR from optional third field
    REAL_MODEL=$(printf '%s' "$REAL_MODEL" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Remember first backend as default fallback
    if [ -z "$DEFAULT_BACKEND" ]; then
      DEFAULT_BACKEND="$BACKEND"
    fi

    # Build optional model-rewrite field for Lua table
    # When REAL_MODEL is set, the Lua code will rewrite the "model" field
    # in the request body before forwarding to the backend.
    MODEL_FIELD=""
    if [ -n "$REAL_MODEL" ]; then
      MODEL_FIELD=", model = \"${REAL_MODEL}\""
    fi

    # Check if this backend has an upstream (load balanced)
    UP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ADMIN/upstreams/${BACKEND}-upstream")

    if [ "$UP_STATUS" -eq 200 ]; then
      LUA_MAP="${LUA_MAP}  [\"${MODEL_NAME}\"] = { upstream = \"${BACKEND}-upstream\"${MODEL_FIELD} },"
      echo "[MAP]     $MODEL_NAME -> upstream:${BACKEND}-upstream${REAL_MODEL:+ (rewrite -> $REAL_MODEL)}"
    else
      # Get service details (host, port, protocol)
      SVC_JSON=$(curl -s "$ADMIN/services/${BACKEND}-service")
      SVC_HOST=$(echo "$SVC_JSON" | grep -o '"host":"[^"]*"' | head -1 | sed 's/"host":"//;s/"//')
      SVC_PORT=$(echo "$SVC_JSON" | grep -o '"port":[0-9]*' | head -1 | sed 's/"port"://')
      SVC_PROTO=$(echo "$SVC_JSON" | grep -o '"protocol":"[^"]*"' | head -1 | sed 's/"protocol":"//;s/"//')

      if [ -n "$SVC_HOST" ]; then
        LUA_MAP="${LUA_MAP}  [\"${MODEL_NAME}\"] = { scheme = \"${SVC_PROTO:-http}\", host = \"${SVC_HOST}\", port = ${SVC_PORT:-80}${MODEL_FIELD} },"
        echo "[MAP]     $MODEL_NAME -> ${SVC_PROTO:-http}://${SVC_HOST}:${SVC_PORT:-80}${REAL_MODEL:+ (rewrite -> $REAL_MODEL)}"
      else
        echo "[WARN]    Backend '${BACKEND}' not found, skipping model '${MODEL_NAME}'"
      fi
    fi
  done < "$MODEL_CONFIG"

  if [ -z "$LUA_MAP" ]; then
    echo "[WARN]    No model routes configured, skipping unified endpoint"
  else
    # Create unified service (uses first backend as fallback for non-POST requests)
    DFLT_JSON=$(curl -s "$ADMIN/services/${DEFAULT_BACKEND}-service")
    DFLT_HOST=$(echo "$DFLT_JSON" | grep -o '"host":"[^"]*"' | head -1 | sed 's/"host":"//;s/"//')
    DFLT_PORT=$(echo "$DFLT_JSON" | grep -o '"port":[0-9]*' | head -1 | sed 's/"port"://')
    DFLT_PROTO=$(echo "$DFLT_JSON" | grep -o '"protocol":"[^"]*"' | head -1 | sed 's/"protocol":"//;s/"//')

    call PUT /services/unified-llm-service \
      -d "name=unified-llm-service" \
      -d "protocol=${DFLT_PROTO:-http}" \
      -d "host=${DFLT_HOST:-localhost}" \
      -d "port=${DFLT_PORT:-80}" \
      -d "path=/" \
      -d "read_timeout=120000" \
      -d "write_timeout=120000" \
      -d "connect_timeout=10000"

    call PUT /services/unified-llm-service/routes/unified-llm-route \
      -d "name=unified-llm-route" \
      -d "paths[]=/v1" \
      -d "strip_path=false"

    # Write the Lua router code to a temp file
    cat > /tmp/model-router.lua <<ENDLUA
local ROUTES = {$LUA_MAP
}

local method = kong.request.get_method()
local path = kong.request.get_path()

-- =========================================================================
-- GET /v1/models — return all client-facing model names (OpenAI-compatible)
-- GET /v1/models/{id} — return details for a specific model
-- =========================================================================
if method == "GET" then
  if path == "/v1/models" or path == "/v1/models/" then
    local models = {}
    local now = ngx.time()
    for name, _ in pairs(ROUTES) do
      models[#models + 1] = {
        id = name,
        object = "model",
        created = now,
        owned_by = "kong-gateway"
      }
    end
    return kong.response.exit(200, {
      object = "list",
      data = models
    })
  end
  local model_id = path:match("^/v1/models/(.+)$")
  if model_id then
    if ROUTES[model_id] then
      return kong.response.exit(200, {
        id = model_id,
        object = "model",
        created = ngx.time(),
        owned_by = "kong-gateway"
      })
    else
      return kong.response.exit(404, {
        error = {
          message = "No model found: " .. model_id,
          type = "invalid_request_error"
        }
      })
    end
  end
  return
end

-- =========================================================================
-- POST/PUT/PATCH — route by "model" field in request body
-- =========================================================================
if method ~= "POST" and method ~= "PUT" and method ~= "PATCH" then
  return
end
local body, err = kong.request.get_body("application/json")
if not body then
  return
end
local model = body.model
if not model then
  return
end
local route = ROUTES[model]
if not route then
  for pattern, r in pairs(ROUTES) do
    if model:find(pattern, 1, true) == 1 then
      route = r
      break
    end
  end
end
if not route then
  return kong.response.exit(404, { error = { message = "No backend configured for model: " .. model, type = "invalid_request_error" } })
end
if route.upstream then
  kong.service.set_upstream(route.upstream)
elseif route.host then
  kong.service.request.set_scheme(route.scheme or "http")
  kong.service.set_target(route.host, route.port or 80)
end
if route.model then
  body.model = route.model
  kong.service.request.set_body(body, "application/json")
end
ENDLUA

    LUA_CODE=$(cat /tmp/model-router.lua)

    # Delete any existing pre-function plugins, then recreate
    # (uses tr to split JSON objects for reliable field-order-independent matching)
    curl -s "$ADMIN/services/unified-llm-service/plugins" | \
      tr '{' '\n' | grep '"name":"pre-function"' | \
      grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//g' | \
      while read -r PF_ID; do
        [ -n "$PF_ID" ] && call DELETE "/plugins/$PF_ID"
      done

    # Create the pre-function plugin with model-routing logic
    PF_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$ADMIN/services/unified-llm-service/plugins" \
      -d "name=pre-function" \
      --data-urlencode "config.access[]=$LUA_CODE")
    if [ "$PF_STATUS" -ge 200 ] && [ "$PF_STATUS" -lt 300 ]; then
      echo "[OK]      pre-function plugin on unified-llm-service ($PF_STATUS)"
    else
      echo "[ERROR]   pre-function plugin ($PF_STATUS)"
      curl -s -X POST "$ADMIN/services/unified-llm-service/plugins" \
        -d "name=pre-function" \
        --data-urlencode "config.access[]=$LUA_CODE"
      echo ""
    fi

    rm -f /tmp/model-router.lua
  fi
else
  echo ""
  echo "[INFO]    No model-routes.conf found, skipping unified endpoint"
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
