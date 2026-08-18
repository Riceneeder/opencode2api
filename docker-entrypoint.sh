#!/bin/sh
set -eu

app_dir=${APP_DIR:-/app}
state_dir=${STATE_DIR:-/var/lib/opencode2api}
config_path=${CONFIG_PATH:-$app_dir/config.json}
binary_path=$state_dir/opencode2api
fingerprint_path=$state_dir/source.sha256

# Back4app and similar platforms expose PORT env var for single-port mode
if [ -n "${PORT:-}" ]; then
    listen_address="0.0.0.0:${PORT}"
    combined_mode=true
else
    listen_address=${LISTEN_ADDRESS:-0.0.0.0:8080}
    webui_listen_address=${WEBUI_LISTEN_ADDRESS:-0.0.0.0:8081}
    combined_mode=${COMBINED_MODE:-false}
fi

mkdir -p "$state_dir"

if [ -f "$config_path" ]; then
    active_config=$config_path
elif [ -n "${SERVER_KEYS:-}" ] || [ -n "${ZEN_KEYS:-}" ] || [ -n "${GO_KEYS:-}" ]; then
    # Generate config from environment variables (for Back4app and similar platforms)
    generated_config=$state_dir/config.json
    printf '%s\n' "Generating config.json from environment variables..."
    
    # Build JSON arrays from comma-separated env vars
    server_keys_json="[]"
    if [ -n "${SERVER_KEYS:-}" ]; then
        server_keys_json=$(printf '%s' "$SERVER_KEYS" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "\"%s\"", $i; if(i<NF) printf ","} printf "]"}')
    fi
    
    zen_keys_json="[]"
    if [ -n "${ZEN_KEYS:-}" ]; then
        zen_keys_json=$(printf '%s' "$ZEN_KEYS" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "\"%s\"", $i; if(i<NF) printf ","} printf "]"}')
    fi
    
    go_keys_json="[]"
    if [ -n "${GO_KEYS:-}" ]; then
        go_keys_json=$(printf '%s' "$GO_KEYS" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "\"%s\"", $i; if(i<NF) printf ","} printf "]"}')
    fi
    
    proxies_json='["direct"]'
    if [ -n "${PROXIES:-}" ]; then
        proxies_json=$(printf '%s' "$PROXIES" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "\"%s\"", $i; if(i<NF) printf ","} printf "]"}')
    fi
    
    cat > "$generated_config" << EOF
{
  "listen": "${LISTEN_ADDRESS:-0.0.0.0:8080}",
  "server_keys": $server_keys_json,
  "zen_keys": $zen_keys_json,
  "go_keys": $go_keys_json,
  "anonymous": ${ANONYMOUS:-false},
  "prefer": "${PREFER:-go}",
  "proxyfile": "",
  "proxies": $proxies_json,
  "upstream": {
    "zen": "${UPSTREAM_ZEN:-https://opencode.ai/zen}",
    "go": "${UPSTREAM_GO:-https://opencode.ai/zen/go}"
  },
  "retry": {
    "max_attempts": ${MAX_ATTEMPTS:-3},
    "timeout_seconds": ${TIMEOUT_SECONDS:-300}
  },
  "models": {
    "refresh_seconds": ${REFRESH_SECONDS:-300},
    "protocols": {}
  },
  "performance": {
    "max_idle_conns": ${MAX_IDLE_CONNS:-2048},
    "max_idle_conns_per_host": ${MAX_IDLE_CONNS_PER_HOST:-256},
    "max_conns_per_host": ${MAX_CONNS_PER_HOST:-0},
    "idle_conn_timeout_seconds": ${IDLE_CONN_TIMEOUT:-120},
    "connect_timeout_seconds": ${CONNECT_TIMEOUT:-5},
    "failure_cooldown_seconds": ${FAILURE_COOLDOWN:-15}
  },
  "logging": {
    "level": "${LOG_LEVEL:-info}",
    "ring_size": ${RING_SIZE:-2000}
  },
  "webui": {
    "enabled": ${WEBUI_ENABLED:-true},
    "listen": "${WEBUI_LISTEN:-0.0.0.0:8081}",
    "username": "${WEBUI_USERNAME:-admin}",
    "password": "${WEBUI_PASSWORD:-changeme123}",
    "session_ttl_minutes": ${SESSION_TTL:-720}
  }
}
EOF
    active_config=$generated_config
    printf '%s\n' "config.json generated from environment variables."
else
    generated_config=$state_dir/config.json
    if [ ! -f "$generated_config" ]; then
        cp "$app_dir/config.example.json" "$generated_config"
    fi
    active_config=$generated_config
    printf '%s\n' "config.json not found; using a persistent generated copy. Set real API keys or enable anonymous mode, and change the WebUI password before use."
fi

source_fingerprint() {
    {
        go version
        go env GOOS GOARCH CGO_ENABLED
        find "$app_dir" \
            -path "$app_dir/.git" -prune -o \
            -type f \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -path "$app_dir/webui/*" \) -print \
            | LC_ALL=C sort \
            | while IFS= read -r source_file; do
                sha256sum "$source_file"
            done
    } | sha256sum | awk '{print $1}'
}

current_fingerprint=$(source_fingerprint)
stored_fingerprint=""
if [ -f "$fingerprint_path" ]; then
    stored_fingerprint=$(cat "$fingerprint_path")
fi

if [ ! -x "$binary_path" ] || [ "$current_fingerprint" != "$stored_fingerprint" ]; then
    printf '%s\n' "Source changed or no cached binary exists; building opencode2api..."
    temporary_binary=$state_dir/opencode2api.new
    cd "$app_dir"
    go build -trimpath -o "$temporary_binary" ./
    mv "$temporary_binary" "$binary_path"
    printf '%s\n' "$current_fingerprint" > "$fingerprint_path"
    printf '%s\n' "Build completed and cached in the persistent Docker volume."
else
    printf '%s\n' "Source is unchanged; starting the cached opencode2api binary."
fi

if [ "$combined_mode" = "true" ]; then
    exec "$binary_path" -config "$active_config" -listen "$listen_address" -combined
else
    exec "$binary_path" -config "$active_config" -listen "$listen_address" -web-listen "$webui_listen_address"
fi
