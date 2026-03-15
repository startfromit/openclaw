#!/usr/bin/env bash
set -euo pipefail

# change these to official openclaw image if your network allows you to do so
searxng_x86_image=registry.cn-hangzhou.aliyuncs.com/eliteunited/docker.io.searxng.searxng:latest
openclaw_x86_image=registry.cn-hangzhou.aliyuncs.com/eliteunited/openclaw:2026.3.12
if [[ $(arch) == "arm64" ]];then
  searxng_x86_image=registry.cn-hangzhou.aliyuncs.com/eliteunited/docker.io.searxng.searxng-arm64:latest
  openclaw_x86_image=registry.cn-hangzhou.aliyuncs.com/eliteunited/openclaw:2026.3.12-arm64
fi

export HOST=192.168.0.124 # change this ip to your target ip
##=====openclaw=====##
export OPENCLAW_BIND_HOST=${HOST}
export OPENCLAW_IMAGE=${openclaw_x86_image} 
export COMPOSE_FILE=./docker-compose-searxng-example.yml
export OPENCLAW_CONFIG_DIR=${HOME}/Projects/app_data/openclaw # change this to your desired directory
export OPENCLAW_WORKSPACE_DIR=${HOME}/Projects/app_data/openclaw/workspace # change this to your desired directory
export OPENCLAW_GATEWAY_PORT=12345 # change this port to whatever you want
export OPENCLAW_BRIDGE_PORT=12346 # change this port to whatever you want
export OPENCLAW_GATEWAY_BIND=lan # do not change or installation will fail, will be changed to lan during setup
export REUSE_EXISTING_IMAGE=true
export OPENCLAW_EXTENSIONS="ollama feishu discord slack whatsapp synology-chat imessage" # only works when REUSE_EXISTING_IMAGE=false and OPENCLAW_IMAGE=openclaw:local
export OPENCLAW_DOCKER_APT_PACKAGES="curl wget himalaya ffmpeg build-essential" # only works when REUSE_EXISTING_IMAGE=false and OPENCLAW_IMAGE=openclaw:local

##=====searXNG=====##
export SEARXNG_PORT=12347 # change this port to whatever you want
export SEARXNG_HOSTNAME=${HOST}:${SEARXNG_PORT}
export SEARXNG_SETTINGS_DIR=${HOME}/Projects/app_data/searxng
export SEARXNG_IMAGE=${searxng_x86_image}

if [[ -n "${1:-}" ]];then
    docker compose -f ${COMPOSE_FILE} $@
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

  sed -i '' "s/OPENCLAW_GATEWAY_BIND=.*/OPENCLAW_GATEWAY_BIND=lan/" .env
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

fix_compaction_issue() {
  local config_file="${OPENCLAW_CONFIG_DIR}/openclaw.json"
  python3 - "$config_file" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r") as f:
    cfg = json.load(f)
cfg.setdefault("agents", {}).setdefault("defaults", {}).update({
    "compaction": {
        "mode": "default",
        "maxHistoryShare": 0.6,
        "reserveTokensFloor": 40000,
        "memoryFlush": {
            "enabled": True
        }
    },
    "contextPruning": {
        "mode": "cache-ttl"
    }
})
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("compaction config written to " + path)
PY
}

config_searxng_in_openclaw_env() {
  local config_file="${OPENCLAW_CONFIG_DIR}/openclaw.json"
  python3 - "$config_file" "http://${SEARXNG_HOSTNAME}/" <<'PY'
import json, sys
path, searxng_url = sys.argv[1], sys.argv[2]
with open(path, "r") as f:
    cfg = json.load(f)
cfg.setdefault("env", {})["SEARXNG_URL"] = searxng_url
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("SEARXNG_URL set to " + searxng_url)
PY
}

enable_tools() {
  local config_file="${OPENCLAW_CONFIG_DIR}/openclaw.json"
  if [[ ! -f "$config_file" ]]; then
    echo '{}' > "$config_file"
  fi
  python3 - "$config_file" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r") as f:
    cfg = json.load(f)
cfg.setdefault("tools", {}).update({
    "web": {
        "search": {
            "enabled": False
        },
        "fetch": {
            "enabled": True,
            "maxChars": 50000,
            "maxCharsCap": 50000,
            "cacheTtlMinutes": 15,
            "maxRedirects": 3
        }
    }
})
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("tools config written to " + path)
PY
  mkdir -p "$OPENCLAW_CONFIG_DIR/skills/searxng"
  cat > "$OPENCLAW_CONFIG_DIR/skills/searxng/SKILL.md" <<'EOF'
---
name: searxng
description: 调用本地SearXNG实例进行隐私化网页搜索，返回结构化结果（支持中文/英文）。
---

## 核心配置
- API地址: $SEARXNG_URL
- 返回格式: JSON

## 使用步骤
1. 构造查询URL: `$SEARXNG_URL/search?q={urlencoded_query}&format=json`
2. 用 exec 工具通过 curl 调用: `curl -s "$SEARXNG_URL/search?q=<query>&format=json"`
3. 解析JSON结果，提取 results 数组，每条包含 title/url/content 字段

## 错误处理
- 若API超时/无响应：提示"SearXNG服务不可用，请检查实例状态"
- 若结果为空：提示"未找到相关结果，请更换关键词重试"

## 示例
查询: "2026年实时金价"
命令: curl -s "$SEARXNG_URL/search?q=2026年实时金价&format=json"
EOF
}

setup_ollama() {
  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
    config set models.providers.ollama.apiKey "ollama-local"
  docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli \
    models set ollama/qwen3.5:4b
}

save_searxng_config_2_env
ensure_control_ui_allowed_origins
enable_https
disable_device_approve
fix_compaction_issue
## config_searxng_in_openclaw_env
enable_tools
setup_ollama

cat .env

docker compose -f ${COMPOSE_FILE} stop
docker compose -f ${COMPOSE_FILE} up -d

echo ""
echo "setup completed"
echo "useful commands:"
echo "docker compose -f ${COMPOSE_FILE} run --rm openclaw-cli configure # select Model or Channels if you choose skip during onboarding"
echo "useful tips:"
echo "cd ${OPENCLAW_CONFIG_DIR} && git init"
echo "cd ${OPENCLAW_WORKSPACE_DIR} && rm -rf .git && git init"
