#!/usr/bin/env bash
set -euo pipefail

export HOST=192.168.0.124 # change this ip to your target ip

##=====openclaw=====##
export OPENCLAW_BIND_HOST=${HOST}
export REUSE_EXISTING_IMAGE=true
export OPENCLAW_IMAGE=registry.cn-hangzhou.aliyuncs.com/eliteunited/ghcr.io.openclaw.openclaw-arm64:latest # change this to official openclaw image if your network allows you to do so
export COMPOSE_FILE=./docker-compose-searxng-example.yml
export OPENCLAW_CONFIG_DIR=/Users/yu/Projects/app_data/openclaw
export OPENCLAW_WORKSPACE_DIR=/Users/yu/Projects/app_data/openclaw/workspace
export OPENCLAW_GATEWAY_PORT=12345 # change this port to whatever you want
export OPENCLAW_BRIDGE_PORT=12346 # change this port to whatever you want
export OPENCLAW_GATEWAY_BIND=loopback

##=====searXNG=====##
export SEARXNG_PORT=12347 # change this port to whatever you want
export SEARXNG_HOSTNAME=${HOST}:${SEARXNG_PORT}
export SEARXNG_SETTINGS_DIR=/Users/yu/Projects/app_data/searxng
export SEARXNG_IMAGE=registry.cn-hangzhou.aliyuncs.com/eliteunited/docker.io.searxng.searxng-arm64:latest # change this to official searxng image if your network allows you to do so

if [[ -n "${1:-}" ]];then
    docker compose -f ${COMPOSE_FILE} "$1"
    exit 0
fi

./docker-setup.sh

ensure_control_ui_allowed_origins() {
  echo "Ensuring openclaw control ui allowed origins"
  local allowed_origin_json
  local current_allowed_origins

  allowed_origin_json="[\"https://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}\",\"http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}\"]"

  current_allowed_origins="$(
    docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
      config get gateway.controlUi.allowedOrigins 2>/dev/null || true
  )"
  current_allowed_origins="${current_allowed_origins//$'\r'/}"
  echo "current_allowed_origins: ${current_allowed_origins}"

  if [[ -n "$current_allowed_origins" && "$current_allowed_origins" != "null" && "$current_allowed_origins" != "[]" ]]; then
    echo "Control UI allowlist already configured; leaving gateway.controlUi.allowedOrigins unchanged."
    return 0
  fi

  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
    config set gateway.controlUi.allowedOrigins "$allowed_origin_json" --strict-json >/dev/null
  echo "Set gateway.controlUi.allowedOrigins to $allowed_origin_json for non-loopback bind."

  docker compose "${COMPOSE_ARGS[@]}" run --rm openclaw-cli \
    config set gateway.bind lan >/dev/null
  
  echo "Current gateway.controlUi.allowedOrigins:"
  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
      config get gateway.controlUi.allowedOrigins 
  echo "Current gateway.bind:"
  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
      config get gateway.bind

  sed -i '' "s/OPENCLAW_GATEWAY_BIND=loopback/OPENCLAW_GATEWAY_BIND=lan/" .env
  export OPENCLAW_GATEWAY_BIND=lan
}

save_searxng_config_2_env() {
  sed -i '' "/SEARXNG/d" .env
  cat >> .env <<EOF
SEARXNG_HOSTNAME=${SEARXNG_HOSTNAME}
SEARXNG_PORT=${SEARXNG_PORT}
SEARXNG_SETTINGS_DIR=${SEARXNG_SETTINGS_DIR}
SEARXNG_IMAGE=${SEARXNG_IMAGE}
EOF
}

enable_https() {
  # allowInsecureAuth is not working anymore, so tls is a must
  local ssl_dir="${OPENCLAW_CONFIG_DIR}/ssl"
  mkdir -p "$ssl_dir"

  if [[ ! -f "$ssl_dir/cert.pem" || ! -f "$ssl_dir/key.pem" ]]; then
    echo "Generating self-signed TLS certificate in $ssl_dir"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$ssl_dir/key.pem" -out "$ssl_dir/cert.pem" \
      -subj "/CN=${HOST}"
  else
    echo "TLS certificate already exists, skipping generation."
  fi

  # Inject tls config directly into openclaw.json (container-side paths)
  local config_file="${OPENCLAW_CONFIG_DIR}/openclaw.json"
  local cert_path="/home/node/.openclaw/ssl/cert.pem"
  local key_path="/home/node/.openclaw/ssl/key.pem"

  if [[ ! -f "$config_file" ]]; then
    echo '{}' > "$config_file"
  fi

  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
    config set gateway.tls.certPath "$cert_path" >/dev/null
  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
    config set gateway.tls.keyPath "$key_path" >/dev/null
  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
    config set gateway.tls.enabled true >/dev/null
  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
    config get gateway.tls
  echo "TLS configured: certPath=$cert_path keyPath=$key_path"
}

disable_device_approve() {
  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
  config set gateway.controlUi.dangerouslyDisableDeviceAuth true
}


save_searxng_config_2_env
ensure_control_ui_allowed_origins
enable_https
disable_device_approve

cat .env

docker compose -f ${COMPOSE_FILE} stop
docker compose -f ${COMPOSE_FILE} up -d

echo "docker compose -f docker-compose-searxng-example.yml run --rm openclaw-cli devices list"
