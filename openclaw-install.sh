#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR_DEFAULT="$HOME/.openclaw/conf"
INSTALL_DIR_DEFAULT="$HOME/.openclaw"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$STATE_DIR_DEFAULT}"
export OPENCLAW_STATE_DIR

CONFIG_FILE="$OPENCLAW_STATE_DIR/openclaw.json"
STEP_ID=0
RUN_MODE="install"
INSTALL_MODE="online"
MODEL_REGION="global"
AUTH_CHOICE="openai-codex"
LOCAL_PKG_DIR="$SCRIPT_DIR/offline-packages"
OPENCLAW_NPM_PREFIX=""
LOCAL_OPENCLAW_PKG=""
LOCAL_CLAWHUB_PKG=""
LOCAL_CHINA_PLUGIN_PKG=""
LOCAL_NODE_PKG=""
LOCAL_DOCKER_PKG=""
LOCAL_OPENCLAW_VERSION=""
LOCAL_CLAWHUB_VERSION=""
LOCAL_CHINA_PLUGIN_VERSION=""
LOCAL_NODE_VERSION=""

CHANNELS_SELECTED=()
ACCOUNT_IDS=()
ACCOUNT_CHANNELS=()
CONFIGURED_REFS=()
OCCUPIED_REFS=()
CREATED_AGENT_IDS=()

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

step() {
  STEP_ID=$((STEP_ID + 1))
  printf '\n========== STEP %d: %s ==========\n' "$STEP_ID" "$1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

contains() {
  local needle="$1"
  shift || true
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

append_if_missing() {
  local file="$1"
  local line="$2"
  touch "$file"
  grep -Fqx "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

ensure_dir() {
  mkdir -p "$1"
}

prepend_path_if_missing() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) export PATH="$dir:$PATH" ;;
  esac
}

refresh_npm_global_bin_path() {
  local npm_prefix npm_bin
  if [[ -n "$OPENCLAW_NPM_PREFIX" && -d "$OPENCLAW_NPM_PREFIX/bin" ]]; then
    prepend_path_if_missing "$OPENCLAW_NPM_PREFIX/bin"
  fi

  npm_prefix="$(npm config get prefix 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
  [[ -n "$npm_prefix" ]] || return 0
  npm_bin="$npm_prefix/bin"
  prepend_path_if_missing "$npm_bin"
  hash -r 2>/dev/null || true
}

persist_openclaw_bin_path() {
  local rc_file path_line
  rc_file="$(detect_shell_rc_file)"
  path_line="export PATH=\"$OPENCLAW_NPM_PREFIX/bin:\$PATH\""
  append_if_missing "$rc_file" "$path_line"
  prepend_path_if_missing "$OPENCLAW_NPM_PREFIX/bin"
  hash -r 2>/dev/null || true
}

set_openclaw_entry_from_package_dir() {
  local pkg_dir="$1"
  local rel_bin abs_bin
  [[ -n "$pkg_dir" && -d "$pkg_dir" ]] || return 1
  OPENCLAW_RESOLVED_PKG_DIR="$pkg_dir"

  for rel_bin in "openclaw.mjs" "dist/entry.js" "dist/cli/entry.js" "dist/index.js" "bin/openclaw" "bin/openclaw.js"; do
    abs_bin="$pkg_dir/$rel_bin"
    if [[ -f "$abs_bin" ]]; then
      OPENCLAW_NODE_ENTRY="$abs_bin"
      OPENCLAW_CMD_PATH=""
      return 0
    fi
  done

  if command -v node >/dev/null 2>&1 && [[ -f "$pkg_dir/package.json" ]]; then
    rel_bin="$(node -e '
      const fs = require("node:fs");
      const pkgDir = process.argv[1];
      try {
        const raw = fs.readFileSync(`${pkgDir}/package.json`, "utf8");
        const pkg = JSON.parse(raw);
        if (typeof pkg.bin === "string") {
          process.stdout.write(pkg.bin);
        } else if (pkg.bin && typeof pkg.bin === "object") {
          const candidate = pkg.bin.openclaw || Object.values(pkg.bin)[0];
          if (typeof candidate === "string") process.stdout.write(candidate);
        }
      } catch {}
    ' "$pkg_dir" 2>/dev/null || true)"

    if [[ -n "$rel_bin" && -f "$pkg_dir/$rel_bin" ]]; then
      OPENCLAW_NODE_ENTRY="$pkg_dir/$rel_bin"
      OPENCLAW_CMD_PATH=""
      return 0
    fi
  fi

  return 1
}

resolve_openclaw_from_npm_ls() {
  local parseable pkg_dir
  command -v npm >/dev/null 2>&1 || return 1

  if [[ -n "$OPENCLAW_NPM_PREFIX" ]]; then
    parseable="$(npm ls -g --prefix "$OPENCLAW_NPM_PREFIX" --parseable openclaw 2>/dev/null || true)"
  else
    parseable="$(npm ls -g --parseable openclaw 2>/dev/null || true)"
  fi
  pkg_dir="$(printf '%s\n' "$parseable" | grep -E '/openclaw$' | tail -n 1 || true)"
  [[ -n "$pkg_dir" ]] || return 1

  set_openclaw_entry_from_package_dir "$pkg_dir"
}

OPENCLAW_CMD_PATH=""
OPENCLAW_NODE_ENTRY=""
OPENCLAW_RESOLVED_PKG_DIR=""

print_openclaw_resolution_diagnostics() {
  warn "openclaw 解析诊断: node=$(command -v node || true) npm=$(command -v npm || true)"
  warn "openclaw 解析诊断: node -v=$(node -v 2>/dev/null || true) npm -v=$(npm -v 2>/dev/null || true)"
  warn "openclaw 解析诊断: installDir=$INSTALL_DIR_DEFAULT"
  warn "openclaw 解析诊断: npmPrefix=$OPENCLAW_NPM_PREFIX"
  warn "openclaw 解析诊断: pkgDir=$OPENCLAW_RESOLVED_PKG_DIR"
  warn "openclaw 解析诊断: nodeEntry=$OPENCLAW_NODE_ENTRY"
  warn "openclaw 解析诊断: cmdPath=$OPENCLAW_CMD_PATH"
}

resolve_openclaw_command() {
  if [[ -n "$OPENCLAW_CMD_PATH" && -x "$OPENCLAW_CMD_PATH" ]]; then
    return 0
  fi
  if [[ -n "$OPENCLAW_NODE_ENTRY" && -f "$OPENCLAW_NODE_ENTRY" ]]; then
    return 0
  fi

  local bin npm_root npm_prefix pkg_dir entry

  bin="$(type -P openclaw || true)"
  if [[ -n "$bin" ]]; then
    OPENCLAW_CMD_PATH="$bin"
    return 0
  fi

  refresh_npm_global_bin_path
  bin="$(type -P openclaw || true)"
  if [[ -n "$bin" ]]; then
    OPENCLAW_CMD_PATH="$bin"
    return 0
  fi

  if command -v npm >/dev/null 2>&1; then
    if [[ -n "$OPENCLAW_NPM_PREFIX" ]]; then
      pkg_dir="$OPENCLAW_NPM_PREFIX/lib/node_modules/openclaw"
      if set_openclaw_entry_from_package_dir "$pkg_dir"; then
        return 0
      fi

      bin="$OPENCLAW_NPM_PREFIX/bin/openclaw"
      if [[ -x "$bin" ]]; then
        OPENCLAW_CMD_PATH="$bin"
        return 0
      fi
    fi

    npm_root="$(npm root -g 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
    if [[ -n "$npm_root" ]]; then
      pkg_dir="$npm_root/openclaw"
      if set_openclaw_entry_from_package_dir "$pkg_dir"; then
        return 0
      fi
    fi

    npm_prefix="$(npm config get prefix 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
    if [[ -n "$npm_prefix" ]]; then
      pkg_dir="$npm_prefix/lib/node_modules/openclaw"
      if set_openclaw_entry_from_package_dir "$pkg_dir"; then
        return 0
      fi
    fi

    if resolve_openclaw_from_npm_ls; then
      return 0
    fi
  fi

  for entry in \
    "$HOME/.npm-global/lib/node_modules/openclaw" \
    "/usr/local/lib/node_modules/openclaw" \
    "/opt/homebrew/lib/node_modules/openclaw"
  do
    if set_openclaw_entry_from_package_dir "$entry"; then
      return 0
    fi
  done

  return 1
}

oc() {
  resolve_openclaw_command || {
    print_openclaw_resolution_diagnostics
    die "找不到 openclaw 可执行入口（PATH/npm root/包目录均未命中）"
  }

  if [[ -n "$OPENCLAW_NODE_ENTRY" ]]; then
    command -v node >/dev/null 2>&1 || die "缺少 node，无法通过 entry.js 运行 openclaw"
    node "$OPENCLAW_NODE_ENTRY" "$@"
    return
  fi

  if [[ -n "$OPENCLAW_CMD_PATH" ]]; then
    "$OPENCLAW_CMD_PATH" "$@"
    return
  fi

  print_openclaw_resolution_diagnostics
  die "openclaw 入口解析异常：既没有 node entry，也没有可执行 bin"
}

json_set_auto() {
  local key="$1"
  local val="$2"
  if [[ "$val" =~ ^(true|false|null|-?[0-9]+)$ ]]; then
    oc config set "$key" "$val" --json >/dev/null
  else
    oc config set "$key" "$val" >/dev/null
  fi
}

# Always store value as a string (never as JSON number/boolean).
# Use for credential-like fields (botId, secret, token, apiKey, etc.)
# that must remain strings even when the user enters purely numeric values.
# Wraps the value in JSON quotes so `config set --json` treats it as a string literal.
json_set_string() {
  local key="$1"
  local val="$2"
  oc config set "$key" "\"$val\"" --json >/dev/null
}

channel_default_account_prefix() {
  case "$1" in
    telegram)    printf 'tg' ;;
    dingtalk)    printf 'dt' ;;
    wecom)       printf 'wc' ;;
    feishu-china) printf 'fs' ;;
    *)           printf 'ch' ;;
  esac
}

next_account_id() {
  local channel="$1"
  local prefix seq candidate
  prefix="$(channel_default_account_prefix "$channel")"
  seq=1
  while true; do
    candidate="${prefix}${seq}"
    if contains "$candidate" "${ACCOUNT_IDS[@]+"${ACCOUNT_IDS[@]}"}"; then
      seq=$((seq + 1))
    else
      printf '%s' "$candidate"
      return 0
    fi
  done
}

read_field() {
  local prompt="$1"
  local default="${2:-}"
  local required="${3:-true}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "  $prompt (默认 $default): " value
    value="$(trim "$value")"
    [[ -n "$value" ]] || value="$default"
  else
    while true; do
      read -r -p "  $prompt: " value
      value="$(trim "$value")"
      if [[ -n "$value" ]] || [[ "$required" == "false" ]]; then
        break
      fi
      warn "  此字段为必填项，请重新输入"
    done
  fi
  printf '%s' "$value"
}

print_checklist() {
  cat <<'EOF'
# China - dingtalk（交互式填写 AppKey/AppSecret）
openclaw china setup
# 重启并复查
openclaw gateway restart
openclaw channels status --probe

# Health and status
openclaw status
openclaw status --deep
openclaw gateway status
openclaw channels status --probe
openclaw models status --check
openclaw dashboard
openclaw dashboard --no-open

# Gateway service lifecycle
openclaw gateway install
openclaw gateway start
openclaw gateway stop
openclaw gateway restart
openclaw gateway status
openclaw gateway uninstall

# Onboarding and auth refresh
openclaw onboard
openclaw onboard --auth-choice openai-codex
openclaw onboard --auth-choice openai-api-key
openclaw onboard --skip-search
openclaw plugins list

# Agents and routing
openclaw agents list --bindings
openclaw agents add <id>
openclaw agents bind --agent <id> --bind <channel[:accountId]>
openclaw agents unbind --agent <id> --bind <channel[:accountId]>

# Channels
openclaw channels list
openclaw channels add --channel <name>
openclaw channels remove --channel <name> --delete
openclaw config set channels.telegram.groupPolicy open
openclaw config get channels.telegram.groupPolicy

# Skills and hooks
npm install -g clawhub
clawhub login
clawhub search "<query>"
clawhub install <slug>
clawhub list
clawhub update --all
openclaw skills list --eligible
openclaw skills check
openclaw hooks list
openclaw hooks enable boot-md
openclaw hooks enable bootstrap-extra-files
openclaw hooks enable command-logger
openclaw hooks enable session-memory
openclaw hooks check

# Plugins (provider dependencies)
openclaw plugins list
openclaw plugins doctor
openclaw plugins enable <plugin-id>
openclaw plugins install <npm-spec>
openclaw plugins install @openclaw-china/channels
openclaw china setup
openclaw channels status --probe

# Config and logs
export OPENCLAW_STATE_DIR="$HOME/.openclaw/conf"
openclaw config get gateway.port
openclaw config set gateway.port 18789
openclaw config get agents.defaults.model.primary
openclaw config set agents.defaults.model.primary "gpt-codex-5.3"
openclaw logs --follow
EOF
}

run_uninstall_cmd() {
  "$@"
}

remove_export_line() {
  local file="$1"
  local prefix="$2"
  [[ -f "$file" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  if grep -Fv "$prefix" "$file" > "$tmp"; then
    :
  else
    : > "$tmp"
  fi
  run_uninstall_cmd mv "$tmp" "$file"
}

safe_remove_dir() {
  local p
  p="$(trim "$1")"
  [[ -n "$p" ]] || return 0
  [[ "$p" != "/" ]] || die "拒绝删除根目录 /"
  [[ "$p" != "$HOME" ]] || die "拒绝删除 HOME 目录"
  [[ -d "$p" ]] || return 0
  run_uninstall_cmd rm -rf "$p"
}

uninstall_openclaw() {
  step "卸载确认"
  log "将执行完全卸载：服务、全局包、配置和数据目录都会被删除。"

  step "停止并卸载网关服务"
  if resolve_openclaw_command; then
    run_uninstall_cmd oc gateway stop || true
    run_uninstall_cmd oc gateway uninstall || true
  else
    warn "未检测到 openclaw 命令，跳过 gateway 卸载"
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    if command -v launchctl >/dev/null 2>&1; then
      run_uninstall_cmd launchctl bootout "gui/$UID/ai.openclaw.gateway" || true
    fi
    [[ -f "$plist" ]] && run_uninstall_cmd rm -f "$plist"
  fi

  step "卸载全局 npm 包"
  if command -v npm >/dev/null 2>&1; then
    if [[ -n "$OPENCLAW_NPM_PREFIX" ]]; then
      run_uninstall_cmd npm uninstall -g --prefix "$OPENCLAW_NPM_PREFIX" openclaw || true
      run_uninstall_cmd npm uninstall -g --prefix "$OPENCLAW_NPM_PREFIX" clawhub || true
    fi
    run_uninstall_cmd npm uninstall -g openclaw || true
    run_uninstall_cmd npm uninstall -g clawhub || true
  else
    warn "未检测到 npm，跳过全局包卸载"
  fi

  step "删除 OpenClaw 数据目录"
  local install_guess
  install_guess="$INSTALL_DIR_DEFAULT"
  if [[ "$OPENCLAW_STATE_DIR" == */conf ]]; then
    install_guess="${OPENCLAW_STATE_DIR%/conf}"
  fi

  safe_remove_dir "$install_guess"
  [[ "$install_guess" == "$HOME/.openclaw" ]] || safe_remove_dir "$HOME/.openclaw"

  step "清理 Docker 沙盒容器与镜像"
  if command -v docker >/dev/null 2>&1; then
    log "正在查找并清理 OpenClaw 的 Docker 沙盒实例..."
    # 查找所有以 openclaw-sbx- 开头的容器并强制删除
    local sandbox_containers
    sandbox_containers="$(docker ps -a --filter "name=openclaw-sbx-" --format "{{.ID}}" || true)"
    if [[ -n "$sandbox_containers" ]]; then
      log "检测到相关沙盒容器，正在停止并清理..."
      # shellcheck disable=SC2046
      run_uninstall_cmd docker stop -t 2 $sandbox_containers >/dev/null 2>&1 || true
      # shellcheck disable=SC2046
      run_uninstall_cmd docker rm -f $sandbox_containers >/dev/null 2>&1 || true
      log "已清理相关 Docker 沙盒容器。"
    else
      log "没有需要清理的 Docker 沙盒容器。"
    fi
    # 可选：如果你想连镜像也清理（通常是 openclaw/sandbox 等），可以在此追加逻辑
  else
    warn "未检测到 Docker，跳过沙盒容器清理"
  fi

  step "清理 shell 环境变量"
  remove_export_line "$HOME/.zshrc" "export OPENCLAW_STATE_DIR="
  remove_export_line "$HOME/.bashrc" "export OPENCLAW_STATE_DIR="
  remove_export_line "$HOME/.profile" "export OPENCLAW_STATE_DIR="

  log "\nOpenClaw 卸载完成。"
}

case "${1:-}" in
  h|-h|--help)
    print_checklist
    exit 0
    ;;
  uninstall|u|--uninstall)
    RUN_MODE="uninstall"
    ;;
  ""|install)
    RUN_MODE="install"
    ;;
  *)
    die "未知参数: ${1:-}. 可用参数: h|-h|--help|uninstall|u|--uninstall"
    ;;
esac

init_install_paths() {
  OPENCLAW_STATE_DIR="${INSTALL_DIR_DEFAULT}/conf"
  OPENCLAW_NPM_PREFIX="${INSTALL_DIR_DEFAULT}/npm-global"
  export OPENCLAW_STATE_DIR
  CONFIG_FILE="$OPENCLAW_STATE_DIR/openclaw.json"
}

choose_install_mode() {
  local input
  while true; do
    log "请选择安装方式："
    log "  [1] 联网安装（可安装 OpenClaw 最新版本）"
    log "  [2] 本地安装（使用本地 offline-packages 中已下载的 Node.js / Docker / OpenClaw 相关包）"
    read -r -p "输入 1 或 2（默认 1）: " input
    input="$(trim "$input")"
    case "$input" in
      ""|"1")
        INSTALL_MODE="online"
        return 0
        ;;
      "2")
        INSTALL_MODE="local"
        return 0
        ;;
      *)
        warn "无效输入，请输入 1 或 2"
        ;;
    esac
  done
}

choose_model_region() {
  local input
  while true; do
    log "请选择模型区域："
    log "  [1] 国外模型（默认，走 Codex 授权）"
    log "  [2] 国内模型（走 MiniMax 跳转授权）"
    read -r -p "输入 1 或 2（默认 1）: " input
    input="$(trim "$input")"
    case "$input" in
      ""|"1")
        MODEL_REGION="global"
        AUTH_CHOICE="openai-codex"
        return 0
        ;;
      "2")
        MODEL_REGION="cn"
        AUTH_CHOICE="minimax-portal"
        return 0
        ;;
      *)
        warn "无效输入，请输入 1 或 2"
        ;;
    esac
  done
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x64' ;;
    arm64|aarch64) printf 'arm64' ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

download_file() {
  local url="$1"
  local out="$2"
  if [[ -f "$out" ]]; then
    log "复用本地文件: $out"
    return 0
  fi
  curl -fL "$url" -o "$out"
}

encode_npm_package() {
  local pkg="$1"
  if [[ "$pkg" == @*/* ]]; then
    local scope name
    scope="${pkg%%/*}"
    name="${pkg##*/}"
    scope="${scope#@}"
    printf '%%40%s%%2F%s' "$scope" "$name"
  else
    printf '%s' "$pkg"
  fi
}

package_prefix() {
  local pkg="$1"
  printf '%s' "$pkg" | sed -E 's/^@//; s#/#-#g'
}

download_npm_latest_tarball() {
  local pkg="$1"
  local encoded meta version tarball prefix out
  encoded="$(encode_npm_package "$pkg")"
  meta="$(curl -fsSL "https://registry.npmjs.org/${encoded}/latest")"
  version="$(printf '%s' "$meta" | jq -r '.version')"
  tarball="$(printf '%s' "$meta" | jq -r '.dist.tarball')"
  [[ -n "$version" && "$version" != "null" ]] || die "无法解析 ${pkg} 版本"
  [[ -n "$tarball" && "$tarball" != "null" ]] || die "无法解析 ${pkg} tarball 地址"

  prefix="$(package_prefix "$pkg")"
  out="$LOCAL_PKG_DIR/${prefix}-${version}.tgz"
  download_file "$tarball" "$out"

  case "$pkg" in
    openclaw)
      LOCAL_OPENCLAW_VERSION="$version"
      LOCAL_OPENCLAW_PKG="$out"
      ;;
    clawhub)
      LOCAL_CLAWHUB_VERSION="$version"
      LOCAL_CLAWHUB_PKG="$out"
      ;;
    @openclaw-china/channels)
      LOCAL_CHINA_PLUGIN_VERSION="$version"
      LOCAL_CHINA_PLUGIN_PKG="$out"
      ;;
  esac
}

download_local_node_package() {
  local os arch index ext filename url os_lc
  os="$(uname -s)"
  arch="$(normalize_arch)"
  os_lc="$(printf '%s' "$os" | tr '[:upper:]' '[:lower:]')"
  if [[ "$os" == "Darwin" ]]; then
    ext="tar.gz"
  elif [[ "$os" == "Linux" ]]; then
    ext="tar.xz"
  else
    die "本脚本当前仅支持 macOS/Linux"
  fi

  index="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt)"
  filename="$(printf '%s\n' "$index" | awk '{print $2}' | grep -E "^node-v[0-9.]+-${os_lc}-${arch}\.${ext}$" | head -n 1)"
  [[ -n "$filename" ]] || die "无法定位 Node 本地安装包"

  LOCAL_NODE_VERSION="$(printf '%s' "$filename" | sed -E 's/^node-v([0-9.]+)-.*/\1/')"
  LOCAL_NODE_PKG="$LOCAL_PKG_DIR/$filename"
  url="https://nodejs.org/dist/latest-v22.x/$filename"
  download_file "$url" "$LOCAL_NODE_PKG"
}

download_local_docker_package() {
  local os arch
  os="$(uname -s)"
  arch="$(normalize_arch)"
  if [[ "$os" == "Darwin" ]]; then
    local docker_arch
    if [[ "$arch" == "arm64" ]]; then
      docker_arch="arm64"
    else
      docker_arch="amd64"
    fi
    LOCAL_DOCKER_PKG="$LOCAL_PKG_DIR/Docker-${docker_arch}.dmg"
    download_file "https://desktop.docker.com/mac/main/${docker_arch}/Docker.dmg" "$LOCAL_DOCKER_PKG"
    return 0
  fi

  if [[ "$os" == "Linux" ]]; then
    LOCAL_DOCKER_PKG="$LOCAL_PKG_DIR/get-docker.sh"
    download_file "https://get.docker.com" "$LOCAL_DOCKER_PKG"
    chmod +x "$LOCAL_DOCKER_PKG"
    return 0
  fi

  die "不支持的系统: $os"
}

prepare_local_packages() {
  ensure_dir "$LOCAL_PKG_DIR"
  log "检查本地离线安装包目录: $LOCAL_PKG_DIR"

  LOCAL_OPENCLAW_PKG="$(ls -1 "$LOCAL_PKG_DIR"/openclaw-*.tgz 2>/dev/null | grep -v 'openclaw-china' | tail -n 1 || true)"
  LOCAL_CLAWHUB_PKG="$(ls -1 "$LOCAL_PKG_DIR"/clawhub-*.tgz 2>/dev/null | tail -n 1 || true)"
  LOCAL_CHINA_PLUGIN_PKG="$(ls -1 "$LOCAL_PKG_DIR"/openclaw-china-channels-*.tgz 2>/dev/null | tail -n 1 || true)"

  if [[ -n "$LOCAL_OPENCLAW_PKG" ]]; then
    LOCAL_OPENCLAW_VERSION="$(basename "$LOCAL_OPENCLAW_PKG" | sed -E 's/^openclaw-([0-9.]+)\.tgz$/\1/')"
  else
    die "本地安装缺少离线包: $LOCAL_PKG_DIR/openclaw-*.tgz"
  fi

  if [[ -n "$LOCAL_CLAWHUB_PKG" ]]; then
    LOCAL_CLAWHUB_VERSION="$(basename "$LOCAL_CLAWHUB_PKG" | sed -E 's/^clawhub-([0-9.]+)\.tgz$/\1/')"
  else
    die "本地安装缺少离线包: $LOCAL_PKG_DIR/clawhub-*.tgz"
  fi

  if [[ -n "$LOCAL_CHINA_PLUGIN_PKG" ]]; then
    LOCAL_CHINA_PLUGIN_VERSION="$(basename "$LOCAL_CHINA_PLUGIN_PKG" | sed -E 's/^openclaw-china-channels-([0-9.]+)\.tgz$/\1/')"
  else
    die "本地安装缺少离线包: $LOCAL_PKG_DIR/openclaw-china-channels-*.tgz"
  fi

  if [[ -z "$LOCAL_NODE_PKG" ]]; then
    LOCAL_NODE_PKG="$(ls -1 "$LOCAL_PKG_DIR"/node-v*-"$(uname -s | tr '[:upper:]' '[:lower:]')"-"$(normalize_arch)".tar.* 2>/dev/null | tail -n 1 || true)"
  fi
  if [[ -n "$LOCAL_NODE_PKG" ]]; then
    LOCAL_NODE_VERSION="$(basename "$LOCAL_NODE_PKG" | sed -E 's/^node-v([0-9.]+)-.*/\1/')"
  else
    die "本地安装缺少离线 Node 包: $LOCAL_PKG_DIR/node-v*-$(uname -s | tr '[:upper:]' '[:lower:]')-$(normalize_arch).tar.*"
  fi

  if [[ -z "$LOCAL_DOCKER_PKG" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      if [[ "$(normalize_arch)" == "arm64" ]]; then
        LOCAL_DOCKER_PKG="$LOCAL_PKG_DIR/Docker-arm64.dmg"
      else
        LOCAL_DOCKER_PKG="$LOCAL_PKG_DIR/Docker-amd64.dmg"
      fi
      [[ -f "$LOCAL_DOCKER_PKG" ]] || LOCAL_DOCKER_PKG=""
    else
      LOCAL_DOCKER_PKG="$LOCAL_PKG_DIR/get-docker.sh"
      [[ -f "$LOCAL_DOCKER_PKG" ]] || LOCAL_DOCKER_PKG=""
    fi
  fi
  if [[ -z "$LOCAL_DOCKER_PKG" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      die "本地安装缺少离线 Docker 包: $LOCAL_PKG_DIR/Docker-$( [[ "$(normalize_arch)" == "arm64" ]] && printf 'arm64' || printf 'amd64').dmg"
    else
      die "本地安装缺少离线 Docker 包: $LOCAL_PKG_DIR/get-docker.sh"
    fi
  fi

  log "本地安装包版本：openclaw=${LOCAL_OPENCLAW_VERSION}, clawhub=${LOCAL_CLAWHUB_VERSION}, @openclaw-china/channels=${LOCAL_CHINA_PLUGIN_VERSION}, node=${LOCAL_NODE_VERSION}"
}

detect_pkg_manager() {
  if command -v brew >/dev/null 2>&1; then
    printf 'brew'
  elif command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v pacman >/dev/null 2>&1; then
    printf 'pacman'
  else
    printf 'unknown'
  fi
}

install_missing_bins() {
  local missing=()
  local b
  for b in bash curl git jq tar; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  log "缺失依赖: ${missing[*]}"
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm" in
    brew)
      brew install curl git jq node
      ;;
    apt)
      sudo apt-get update && sudo apt-get install -y curl git jq tar ca-certificates nodejs npm
      ;;
    dnf)
      sudo dnf install -y curl git jq tar ca-certificates nodejs npm
      ;;
    pacman)
      sudo pacman -Sy --noconfirm curl git jq tar ca-certificates nodejs npm
      ;;
    *)
      die "未检测到可用包管理器，请先手动安装: ${missing[*]}"
      ;;
  esac
}

ensure_node_22() {
  local major
  if ! command -v node >/dev/null 2>&1; then
    if [[ "$INSTALL_MODE" == "local" ]]; then
      install_or_upgrade_node_local
    else
      local pm
      pm="$(detect_pkg_manager)"
      case "$pm" in
        brew) brew install node ;;
        apt) sudo apt-get update && sudo apt-get install -y nodejs npm ;;
        dnf) sudo dnf install -y nodejs npm ;;
        pacman) sudo pacman -Sy --noconfirm nodejs npm ;;
        *) die "未检测到 Node，且无法自动安装" ;;
      esac
    fi
  fi
  major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
  if [[ -z "$major" ]]; then
    die "无法识别 Node 版本"
  fi
  if (( major < 22 )); then
    warn "检测到 Node v${major}，尝试升级到 22+"
    if [[ "$INSTALL_MODE" == "local" ]]; then
      install_or_upgrade_node_local
    else
      local pm
      pm="$(detect_pkg_manager)"
      case "$pm" in
        brew) brew upgrade node ;;
        apt) sudo apt-get update && sudo apt-get install -y nodejs npm ;;
        dnf) sudo dnf install -y nodejs npm ;;
        pacman) sudo pacman -Sy --noconfirm nodejs npm ;;
        *) die "无法自动升级 Node，请手动安装 Node 22+" ;;
      esac
    fi
    major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
    (( major >= 22 )) || die "Node 版本仍低于 22（当前 v${major}）"
  fi
}

install_or_upgrade_node_local() {
  [[ -n "$LOCAL_NODE_PKG" ]] || die "本地 Node 安装包未准备好"
  local target_root extracted
  target_root="/usr/local/lib/nodejs"

  sudo mkdir -p "$target_root"
  case "$LOCAL_NODE_PKG" in
    *.tar.gz) sudo tar -xzf "$LOCAL_NODE_PKG" -C "$target_root" ;;
    *.tar.xz) sudo tar -xJf "$LOCAL_NODE_PKG" -C "$target_root" ;;
    *) die "不支持的 Node 本地包格式: $LOCAL_NODE_PKG" ;;
  esac

  extracted="$(tar -tf "$LOCAL_NODE_PKG" | head -n 1 | cut -d/ -f1)"
  [[ -n "$extracted" ]] || die "无法识别本地 Node 安装目录"

  sudo ln -sf "$target_root/$extracted/bin/node" /usr/local/bin/node
  sudo ln -sf "$target_root/$extracted/bin/npm" /usr/local/bin/npm
  [[ -x "$target_root/$extracted/bin/npx" ]] && sudo ln -sf "$target_root/$extracted/bin/npx" /usr/local/bin/npx
  [[ -x "$target_root/$extracted/bin/corepack" ]] && sudo ln -sf "$target_root/$extracted/bin/corepack" /usr/local/bin/corepack

  prepend_path_if_missing "/usr/local/bin"
  hash -r 2>/dev/null || true
  command -v node >/dev/null 2>&1 || die "本地 Node 系统安装失败"
  command -v npm >/dev/null 2>&1 || die "本地 npm 系统安装失败"
}

npm_tls_preflight() {
  npm ping >/dev/null
  npm view openclaw version >/dev/null
}

detect_shell_rc_file() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh) printf '%s' "$HOME/.zshrc" ;;
    bash) printf '%s' "$HOME/.bashrc" ;;
    *) printf '%s' "$HOME/.profile" ;;
  esac
}

docker_client_major_version() {
  local raw major
  raw="$(docker version --format '{{.Client.Version}}' 2>/dev/null || docker --version 2>/dev/null || true)"
  major="$(printf '%s' "$raw" | sed -E 's/[^0-9]*([0-9]+).*/\1/' || true)"
  if [[ -n "$major" && "$major" =~ ^[0-9]+$ ]]; then
    printf '%s' "$major"
  else
    printf '0'
  fi
}

wait_for_docker_ready() {
  local attempts delay i
  attempts="${1:-30}"
  delay="${2:-2}"
  for ((i = 0; i < attempts; i++)); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

ensure_docker_cli_on_macos() {
  command -v docker >/dev/null 2>&1 && return 0

  local docker_bin
  docker_bin="/Applications/Docker.app/Contents/Resources/bin/docker"
  if [[ -x "$docker_bin" ]]; then
    export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
  fi

  command -v docker >/dev/null 2>&1
}

start_docker_runtime() {
  local attempts delay
  attempts="${1:-30}"
  delay="${2:-2}"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    ensure_docker_cli_on_macos || true
    open -a Docker >/dev/null 2>&1 || true
    wait_for_docker_ready "$attempts" "$delay" && return 0
    return 1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker || true
  elif command -v service >/dev/null 2>&1; then
    sudo service docker start || true
  fi
  wait_for_docker_ready "$attempts" "$delay"
}

install_or_update_docker_online() {
  local os pm
  os="$(uname -s)"
  if [[ "$os" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install --cask docker || brew upgrade --cask docker || true
      return 0
    fi
    die "macOS 在线安装 Docker 需要 Homebrew"
  fi

  pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin
      ;;
    dnf)
      sudo dnf install -y docker docker-compose-plugin
      ;;
    pacman)
      sudo pacman -Sy --noconfirm docker docker-compose
      ;;
    *)
      die "无法在线安装 Docker（未识别包管理器）"
      ;;
  esac
}

install_or_update_docker_local() {
  [[ -n "$LOCAL_DOCKER_PKG" ]] || die "本地 Docker 安装包未准备好"
  local os
  os="$(uname -s)"

  if [[ "$os" == "Darwin" ]]; then
    hdiutil attach "$LOCAL_DOCKER_PKG" -nobrowse -quiet || die "挂载 Docker dmg 失败"
    if [[ -d "/Volumes/Docker/Docker.app" ]]; then
      sudo rm -rf "/Applications/Docker.app" || true
      sudo cp -R "/Volumes/Docker/Docker.app" "/Applications/"
    else
      hdiutil detach "/Volumes/Docker" -quiet || true
      die "未在 dmg 中找到 Docker.app"
    fi
    hdiutil detach "/Volumes/Docker" -quiet || true
    return 0
  fi

  if [[ "$os" == "Linux" ]]; then
    sudo sh "$LOCAL_DOCKER_PKG"
    return 0
  fi

  die "不支持的系统: $os"
}

ensure_docker_for_sandbox() {
  local need_install major installed_now wait_attempts
  need_install=0
  installed_now=0
  wait_attempts=45

  if ! command -v docker >/dev/null 2>&1; then
    need_install=1
  else
    major="$(docker_client_major_version)"
    if (( major < 24 )); then
      warn "检测到 Docker 版本较低（${major}），将尝试升级"
      need_install=1
    fi
  fi

  if (( need_install == 1 )); then
    log "未检测到可用 Docker（或版本过低），开始安装/升级 Docker..."
    if [[ "$INSTALL_MODE" == "local" ]]; then
      install_or_update_docker_local
    else
      install_or_update_docker_online
    fi
    installed_now=1
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    ensure_docker_cli_on_macos || true
  fi

  command -v docker >/dev/null 2>&1 || die "Docker CLI 未就绪，请确认 Docker 已正确安装"

  if (( installed_now == 1 )); then
    wait_attempts=180
    log "首次安装 Docker 后需要初始化，正在等待 Docker daemon 就绪（最长约 6 分钟）..."
  fi

  if ! start_docker_runtime "$wait_attempts" 2; then
    if (( installed_now == 1 )) && [[ "$(uname -s)" == "Darwin" ]]; then
      warn "Docker Desktop 可能仍在首次初始化，请在弹出的 Docker 窗口完成系统授权后按回车重试"
      read -r -p "完成后按回车继续重试: " _docker_retry_input || true
      start_docker_runtime 90 2 || die "Docker daemon 未就绪，请先启动 Docker 后重试"
    else
      die "Docker daemon 未就绪，请先启动 Docker 后重试"
    fi
  fi

  docker info >/dev/null 2>&1 || die "Docker 不可用"

  if ! docker compose version >/dev/null 2>&1; then
    warn "未检测到 docker compose 插件，OpenClaw 某些能力可能受限"
  fi
}

persist_env() {
  ensure_dir "$OPENCLAW_STATE_DIR"

  local rc_file
  rc_file="$(detect_shell_rc_file)"

  append_if_missing "$rc_file" "export OPENCLAW_STATE_DIR=\"$OPENCLAW_STATE_DIR\""
  if [[ -n "$OPENCLAW_NPM_PREFIX" ]]; then
    persist_openclaw_bin_path
  fi
  export OPENCLAW_STATE_DIR
  log "环境变量已写入: $rc_file"
}

install_openclaw() {
  [[ -n "$OPENCLAW_NPM_PREFIX" ]] || OPENCLAW_NPM_PREFIX="$INSTALL_DIR_DEFAULT/npm-global"
  ensure_dir "$OPENCLAW_NPM_PREFIX"

  if [[ "$INSTALL_MODE" == "online" ]]; then
    npm install -g --prefix "$OPENCLAW_NPM_PREFIX" openclaw@latest
  else
    [[ -n "$LOCAL_OPENCLAW_PKG" ]] || die "本地安装包未准备好: openclaw"
    npm install -g --prefix "$OPENCLAW_NPM_PREFIX" "$LOCAL_OPENCLAW_PKG"
  fi

  persist_openclaw_bin_path
  refresh_npm_global_bin_path
  OPENCLAW_CMD_PATH=""
  OPENCLAW_NODE_ENTRY=""
  OPENCLAW_RESOLVED_PKG_DIR=""
  local prefix_bin prefix_pkg
  prefix_bin="$OPENCLAW_NPM_PREFIX/bin/openclaw"
  prefix_pkg="$OPENCLAW_NPM_PREFIX/lib/node_modules/openclaw"

  if [[ -x "$prefix_bin" ]]; then
    OPENCLAW_CMD_PATH="$prefix_bin"
  elif set_openclaw_entry_from_package_dir "$prefix_pkg"; then
    :
  elif resolve_openclaw_command; then
    :
  else
    warn "未直接定位到 openclaw 入口"
    warn "检查路径: bin=$prefix_bin"
    warn "检查路径: pkg=$prefix_pkg"
    print_openclaw_resolution_diagnostics
  fi

  oc --version >/dev/null
}

extract_first_url() {
  local text="$1"
  printf '%s\n' "$text" | grep -Eom1 'https?://[^[:space:]]+' || true
}

open_auth_url() {
  local url="$1"
  [[ -n "$url" ]] || return 1

  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 && return 0
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 && return 0
  fi

  if command -v wslview >/dev/null 2>&1; then
    wslview "$url" >/dev/null 2>&1 && return 0
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 && return 0
  fi

  return 1
}

run_onboard() {
  local onboard_log onboard_pipe line url opened onboard_status
  onboard_log="$(mktemp)"
  onboard_pipe="$(mktemp -u "${TMPDIR:-/tmp}/openclaw-onboard-pipe.XXXXXX")"
  mkfifo "$onboard_pipe"
  opened=0

  # 后台运行 onboard（stdout→FIFO，stdin 不连接终端 → hooks 自动跳过）
  (
    oc onboard \
      --accept-risk \
      --flow quickstart \
      --mode local \
      --auth-choice "$AUTH_CHOICE" \
      --skip-channels \
      --skip-skills \
      --skip-search \
      --skip-health \
      --skip-ui \
      --install-daemon \
      --node-manager npm \
      > "$onboard_pipe" 2>&1
  ) &
  local onboard_pid=$!

  # 前台逐行读取 FIFO 输出，实时显示 + 记录日志 + 自动打开授权 URL
  while IFS= read -r line; do
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$onboard_log"
    if (( opened == 0 )); then
      url="$(extract_first_url "$line")"
      if [[ -n "$url" ]]; then
        if open_auth_url "$url"; then
          log "已自动打开浏览器进行授权：$url"
        else
          warn "无法自动打开浏览器，请手动访问：$url"
        fi
        opened=1
      fi
    fi
  done < "$onboard_pipe"

  wait "$onboard_pid" || true
  onboard_status=$?
  rm -f "$onboard_pipe"

  # FIFO 模式下 stdin 断开终端，hooks multiselect 会触发 WizardCancelledError，
  # 导致 onboard 以 exit 1 退出。但 config（含 auth、model、agent 配置）
  # 在 hooks 步骤之前已写入磁盘，后续步骤可正常运行。这是预期行为。
  if (( onboard_status != 0 )); then
    warn "onboard 退出码 ${onboard_status}（hooks 自动跳过导致，属预期行为）"
  fi

  if (( opened == 0 )); then
    url="$(extract_first_url "$(cat "$onboard_log")")"
    if [[ -n "$url" ]]; then
      if open_auth_url "$url"; then
        log "已自动打开浏览器进行授权：$url"
      else
        warn "无法自动打开浏览器，请手动访问：$url"
      fi
    fi
  fi

  rm -f "$onboard_log"
}

install_skill_dependencies() {
  [[ -n "$OPENCLAW_NPM_PREFIX" ]] || OPENCLAW_NPM_PREFIX="$INSTALL_DIR_DEFAULT/npm-global"
  ensure_dir "$OPENCLAW_NPM_PREFIX"

  if [[ "$INSTALL_MODE" == "online" ]]; then
    npm install -g --prefix "$OPENCLAW_NPM_PREFIX" clawhub
    oc plugins install "$LOCAL_PKG_DIR/openclaw-china-channels-2026.3.11.tgz"
  else
    [[ -n "$LOCAL_CLAWHUB_PKG" ]] || die "本地安装包未准备好: clawhub"
    npm install -g --prefix "$OPENCLAW_NPM_PREFIX" "$LOCAL_CLAWHUB_PKG"
    oc plugins install "$LOCAL_PKG_DIR/openclaw-china-channels-2026.3.11.tgz"
  fi
  # 局部信任并启用 channels 插件（不要设置 plugins.allow，否则会导致所有自带频道被拦截）
  oc plugins enable channels >/dev/null 2>&1 || true
  oc config set plugins.entries.channels.enabled true --json >/dev/null 2>&1 || true
}

register_account_ref() {
  local channel="$1"
  local account_id="$2"
  ACCOUNT_IDS+=("$account_id")
  ACCOUNT_CHANNELS+=("$channel")
  CONFIGURED_REFS+=("$channel:$account_id")
}

configure_channel_account() {
  local channel="$1"
  local is_first="$2"
  local dm_policy="${3:-open}"
  local group_policy="${4:-open}"
  local account_id default_id bot_token client_id client_secret
  local mode bot_id secret webhook_path token aes_key app_id app_secret

  default_id="$(next_account_id "$channel")"
  account_id="$(read_field "账号标识 (用于内部区分多个机器人，仅英文数字)" "$default_id")"

  [[ "$account_id" =~ ^[A-Za-z0-9]+$ ]] || { warn "账号标识仅允许英文和数字: $account_id"; return 1; }
  if contains "$account_id" "${ACCOUNT_IDS[@]+"${ACCOUNT_IDS[@]}"}"; then
    warn "账号标识重复: $account_id"
    return 1
  fi

  case "$channel" in
    telegram)
      bot_token="$(read_field "Bot Token (从 @BotFather 获取)")"
      json_set_auto "channels.telegram.enabled" "true"
      json_set_auto "channels.telegram.accounts.${account_id}.botToken" "$bot_token"
      json_set_auto "channels.telegram.accounts.${account_id}.dmPolicy" "$dm_policy"
      json_set_auto "channels.telegram.accounts.${account_id}.groupPolicy" "$group_policy"
      if (( is_first == 1 )); then
        json_set_auto "channels.telegram.botToken" "$bot_token"
        json_set_auto "channels.telegram.groupPolicy" "$group_policy"
        json_set_auto "channels.telegram.dmPolicy" "$dm_policy"
      fi
      ;;
    dingtalk)
      client_id="$(read_field "Client ID (钉钉开放平台 AppKey)")"
      client_secret="$(read_field "Client Secret (钉钉开放平台 AppSecret)")"
      json_set_auto "channels.dingtalk.enabled" "true"
      json_set_string "channels.dingtalk.accounts.${account_id}.clientId" "$client_id"
      json_set_string "channels.dingtalk.accounts.${account_id}.clientSecret" "$client_secret"
      json_set_auto "channels.dingtalk.accounts.${account_id}.enableAICard" "false"
      json_set_auto "channels.dingtalk.accounts.${account_id}.dmPolicy" "$dm_policy"
      json_set_auto "channels.dingtalk.accounts.${account_id}.groupPolicy" "$group_policy"
      if (( is_first == 1 )); then
        json_set_auto "channels.dingtalk.defaultAccount" "$account_id"
      fi
      ;;
    wecom)
      log "  企业微信连接模式："
      log "    [1] WebSocket (推荐，无需公网地址)"
      log "    [2] Webhook (需要公网回调地址)"
      local mode_pick
      read -r -p "  请选择模式 (默认 1): " mode_pick
      mode_pick="$(trim "$mode_pick")"
      [[ -n "$mode_pick" ]] || mode_pick="1"

      if [[ "$mode_pick" == "2" ]]; then
        mode="webhook"
        webhook_path="$(read_field "Webhook 回调路径 (企业微信后台获取)")"
        token="$(read_field "Token (企业微信后台获取)")"
        aes_key="$(read_field "EncodingAESKey (企业微信后台获取)")"
        json_set_auto "channels.wecom.enabled" "true"
        json_set_string "channels.wecom.accounts.${account_id}.mode" "$mode"
        json_set_string "channels.wecom.accounts.${account_id}.webhookPath" "$webhook_path"
        json_set_string "channels.wecom.accounts.${account_id}.token" "$token"
        json_set_string "channels.wecom.accounts.${account_id}.encodingAESKey" "$aes_key"
      else
        mode="ws"
        bot_id="$(read_field "Bot ID (企业微信后台的 CorpID)")"
        secret="$(read_field "Secret (企业微信后台获取)")"
        json_set_auto "channels.wecom.enabled" "true"
        json_set_string "channels.wecom.accounts.${account_id}.mode" "$mode"
        json_set_string "channels.wecom.accounts.${account_id}.botId" "$bot_id"
        json_set_string "channels.wecom.accounts.${account_id}.secret" "$secret"
      fi
      json_set_auto "channels.wecom.accounts.${account_id}.dmPolicy" "$dm_policy"
      json_set_auto "channels.wecom.accounts.${account_id}.groupPolicy" "$group_policy"
      if (( is_first == 1 )); then
        json_set_auto "channels.wecom.defaultAccount" "$account_id"
      fi
      ;;
    feishu-china)
      app_id="$(read_field "App ID (飞书开放平台获取)")"
      app_secret="$(read_field "App Secret (飞书开放平台获取)")"
      json_set_auto "channels.feishu-china.enabled" "true"
      json_set_string "channels.feishu-china.accounts.${account_id}.appId" "$app_id"
      json_set_string "channels.feishu-china.accounts.${account_id}.appSecret" "$app_secret"
      json_set_auto "channels.feishu-china.accounts.${account_id}.sendMarkdownAsCard" "true"
      json_set_auto "channels.feishu-china.accounts.${account_id}.dmPolicy" "$dm_policy"
      json_set_auto "channels.feishu-china.accounts.${account_id}.groupPolicy" "$group_policy"
      if (( is_first == 1 )); then
        json_set_string "channels.feishu-china.appId" "$app_id"
        json_set_string "channels.feishu-china.appSecret" "$app_secret"
      fi
      ;;
    *)
      warn "不支持的渠道: $channel"
      return 1
      ;;
  esac

  register_account_ref "$channel" "$account_id"
  log "  ✓ 账号 $account_id 配置完成"
  return 0
}

select_channels_for_agent() {
  local agent_label="$1"
  local ALL_CHANNELS=("telegram" "dingtalk" "wecom" "feishu-china")

  log "\n为 ${agent_label} 选择管理渠道："
  local i
  for i in "${!ALL_CHANNELS[@]}"; do
    printf '  [%d] %s\n' "$((i + 1))" "${ALL_CHANNELS[$i]}"
  done

  local selected_raw
  read -r -p "请选择要配置的渠道（逗号分隔编号，回车全选）: " selected_raw
  selected_raw="$(trim "$selected_raw")"

  CHANNELS_SELECTED=()
  if [[ -z "$selected_raw" ]]; then
    CHANNELS_SELECTED=("${ALL_CHANNELS[@]}")
  else
    local _tok _n
    IFS=',' read -r -a _sel_tokens <<< "$selected_raw"
    for _tok in "${_sel_tokens[@]}"; do
      _tok="$(trim "$_tok")"
      if ! [[ "$_tok" =~ ^[0-9]+$ ]]; then
        warn "忽略无效输入: $_tok（请输入数字编号）"
        continue
      fi
      _n="$_tok"
      if (( _n < 1 || _n > ${#ALL_CHANNELS[@]} )); then
        warn "编号越界: $_n"
        continue
      fi
      local _ch="${ALL_CHANNELS[$((_n - 1))]}"
      contains "$_ch" "${CHANNELS_SELECTED[@]+"${CHANNELS_SELECTED[@]}"}" || CHANNELS_SELECTED+=("$_ch")
    done
  fi

  [[ ${#CHANNELS_SELECTED[@]} -gt 0 ]] || die "没有可配置渠道"
  log "已选择: ${CHANNELS_SELECTED[*]}"
}

configure_channels_for_agent() {
  local dm_policy="$1"
  local group_policy="$2"
  local ch account_seq add_more

  for ch in "${CHANNELS_SELECTED[@]}"; do
    log "\n━━━━━━━━━━ $ch ━━━━━━━━━━"
    account_seq=0
    while true; do
      account_seq=$((account_seq + 1))
      log "\n[$ch] 配置第 ${account_seq} 个账号"

      local is_first=0
      (( account_seq == 1 )) && is_first=1

      if configure_channel_account "$ch" "$is_first" "$dm_policy" "$group_policy"; then
        read -r -p "是否继续添加下一个 ${ch} 账号？(y/N): " add_more
        add_more="$(printf '%s' "$add_more" | tr '[:upper:]' '[:lower:]')"
        [[ "$add_more" == "y" || "$add_more" == "yes" ]] || break
      else
        warn "配置失败，请重试"
        account_seq=$((account_seq - 1))
      fi
    done
  done
}

# (Removed write_main_agents_md and write_sub_agents_md to keep default AGENTS.md)

bind_agent_ref() {
  local agent_id="$1"
  local ref="$2"
  local channel="${ref%%:*}"
  local account_id="${ref#*:}"
  
  local bind_err
  bind_err="$(mktemp)"

  if oc agents bind --agent "$agent_id" --bind "${channel}:${account_id}" >/dev/null 2>"$bind_err"; then
    rm -f "$bind_err"
    return 0
  fi

  if oc agents bind --agent "$agent_id" --bind "$channel" >/dev/null 2>>"$bind_err"; then
    warn "${channel}:${account_id} 精确绑定失败，已降级为仅按 channel 绑定. 错误信息: $(cat "$bind_err")"
    rm -f "$bind_err"
    return 0
  fi

  warn "绑定代理 ${agent_id} 到 ${ref} 失败: $(cat "$bind_err")"
  rm -f "$bind_err"
  return 1
}

slugify() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$s" ]] || s="agent"
  printf '%s' "$s"
}

patch_agent_policy_strict() {
  local agent_id="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$agent_id" '
    .agents.list |= map(
      if .id == $id then
        .sandbox = {"mode":"all","scope":"agent","workspaceAccess":"rw"} |
        .tools = ((.tools // {}) + {
          "profile":"messaging",
          "deny":[
            "exec","process","read","write","edit","apply_patch",
            "browser","canvas","cron","gateway","nodes",
            "sessions_spawn","subagents"
          ]
        })
      else . end
    )
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

patch_agent_policy_exec() {
  local agent_id="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$agent_id" '
    .agents.list |= map(
      if .id == $id then
        .sandbox = {
          "mode":"all",
          "scope":"agent",
          "workspaceAccess":"rw",
          "docker":{
            "memory":"1g",
            "cpus":1,
            "pidsLimit":200,
            "network":"bridge"
          }
        } |
        .tools = ((.tools // {}) + {
          "profile":"coding",
          "deny":["gateway","nodes","canvas"],
          "exec":{
            "host":"sandbox",
            "security":"allowlist",
            "safeBins":[
              "curl","wget","python3","node","bun",
              "cat","grep","awk","sed","head","tail",
              "date","echo","ls","find","wc","sort",
              "jq","tar","gzip","unzip"
            ]
          },
          "fs":{"workspaceOnly":true}
        })
      else . end
    )
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

# (Removed classify_policy function)

update_main_allow_agents() {
  [[ ${#CREATED_AGENT_IDS[@]} -gt 0 ]] || return 0
  local subs_json tmp
  subs_json="$(printf '%s\n' "${CREATED_AGENT_IDS[@]}" | jq -R . | jq -s .)"
  tmp="$(mktemp)"
  jq --argjson subs "$subs_json" '
    .agents.list |= map(
      if .id == "main" then
        .subagents = ((.subagents // {}) + {"allowAgents": $subs})
      else . end
    )
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

configure_main_agent() {
  log "\n╔══════════════════════════════════════╗"
  log "║        配置主 Agent (main)           ║"
  log "╚══════════════════════════════════════╝"

  local main_workspace="$HOME/.openclaw/workspace"
  # 不再写入 AGENTS.md，使用引擎默认的空编排行为

  select_channels_for_agent "主 Agent (main)"
  configure_channels_for_agent "pairing" "disabled"

  # 确保主 Agent 存在（onboard 可能未完整创建）
  oc agents add main --non-interactive --json >/dev/null 2>&1 || true

  # 绑定所有刚配置的渠道账号到主 Agent
  local ref
  for ref in "${CONFIGURED_REFS[@]}"; do
    bind_agent_ref "main" "$ref" || warn "主 Agent 绑定失败: $ref"
    OCCUPIED_REFS+=("$ref")
  done

  oc channels status --probe || warn "channels status probe 失败，请稍后复查"
  log "\n✓ 主 Agent (main) 配置完成 (dmPolicy=pairing, groupPolicy=disabled)"
}

configure_sub_agents() {
  local add_sub
  local sub_idx=0

  while true; do
    if (( sub_idx == 0 )); then
      read -r -p "\n是否配置子 Agent？(y/N): " add_sub
    else
      read -r -p "\n是否继续配置下一个子 Agent？(y/N): " add_sub
    fi
    add_sub="$(printf '%s' "$add_sub" | tr '[:upper:]' '[:lower:]')"
    [[ "$add_sub" == "y" || "$add_sub" == "yes" ]] || break

    sub_idx=$((sub_idx + 1))
    log "\n╔══════════════════════════════════════╗"
    log "║      配置第 ${sub_idx} 个子 Agent            ║"
    log "╚══════════════════════════════════════╝"

    # 输入 Agent 名称（唯一性校验）
    local agent_name agent_id base_id suffix
    while true; do
      read -r -p "  Agent 名称（仅英文）: " agent_name
      agent_name="$(trim "$agent_name")"
      [[ -n "$agent_name" ]] || { warn "Agent 名称不能为空"; continue; }
      [[ "$agent_name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || { warn "Agent 名称仅允许英文字母、数字、下划线和连字符，且必须以字母开头"; continue; }

      base_id="$(slugify "$agent_name")"
      agent_id="$base_id"
      if [[ "$agent_id" == "main" ]]; then
        warn "Agent 名称不能为 main（已被主 Agent 使用）"
        continue
      fi
      if contains "$agent_id" "${CREATED_AGENT_IDS[@]+"${CREATED_AGENT_IDS[@]}"}"; then
        warn "Agent 名称重复: $agent_id"
        continue
      fi
      break
    done

    # 不再要求输入工作职责
    local persona=""

    # 保存当前 CONFIGURED_REFS 的长度，用于后续只绑定本 Agent 新增的渠道
    local refs_before=${#CONFIGURED_REFS[@]}

    # 选择并配置渠道
    select_channels_for_agent "子 Agent ($agent_name)"
    configure_channels_for_agent "open" "open"

    # 创建 Agent
    local agent_workspace="$HOME/.openclaw/workspace-${agent_id}"
    oc agents add "$agent_id" --workspace "$agent_workspace" --non-interactive >/dev/null
    CREATED_AGENT_IDS+=("$agent_id")

    # 不写入工作职责，保持 AGENTS.md 默认行为
    # write_sub_agents_md "$agent_workspace" "$agent_name" "$persona"

    # 绑定本 Agent 新增的渠道账号
    local ref_idx
    for (( ref_idx = refs_before; ref_idx < ${#CONFIGURED_REFS[@]}; ref_idx++ )); do
      local ref="${CONFIGURED_REFS[$ref_idx]}"
      bind_agent_ref "$agent_id" "$ref" || warn "绑定失败: ${agent_id} -> ${ref}"
      OCCUPIED_REFS+=("$ref")
    done

    # 全部提示是否开启执行权限
    local enable_exec
    read -r -p "  是否为 ${agent_name} 开启执行权限？(y/N): " enable_exec
    enable_exec="$(printf '%s' "$enable_exec" | tr '[:upper:]' '[:lower:]')"
    if [[ "$enable_exec" == "y" || "$enable_exec" == "yes" ]]; then
      patch_agent_policy_exec "$agent_id"
    else
      patch_agent_policy_strict "$agent_id"
    fi

    oc channels status --probe || warn "channels status probe 失败，请稍后复查"
    log "\n✓ 子 Agent ($agent_name) 配置完成 (id=$agent_id, dmPolicy=open, groupPolicy=open)"
  done
}

configure_all_agents() {
  configure_main_agent
  configure_sub_agents
  update_main_allow_agents
  oc agents list --bindings || warn "无法读取 agents 绑定列表"
}

verify_and_finalize() {
  step "启用固定 hooks"
  oc hooks enable boot-md || warn "boot-md 启用失败"
  oc hooks enable bootstrap-extra-files || warn "bootstrap-extra-files 启用失败"
  oc hooks enable command-logger || warn "command-logger 启用失败"
  oc hooks enable session-memory || warn "session-memory 启用失败"

  step "启动与状态校验"
  oc gateway install || warn "gateway install 失败"
  oc gateway start || warn "gateway start 失败"

  oc status || warn "openclaw status 失败"
  oc channels status --probe || warn "channels probe 失败"
  oc hooks check || warn "hooks check 失败"
  oc models status --check || warn "models check 失败"
  oc config get agents.defaults.model.primary || warn "读取默认模型失败"

  if resolve_openclaw_command; then
    log "\n安装流程完成。以下为常用命令清单："
    print_checklist
  fi

  # 自动打开 WebUI（参照 codex 授权的浏览器打开方式）
  log "\n正在打开 OpenClaw 控制面板..."
  local dashboard_url
  dashboard_url="$(oc dashboard --no-open 2>/dev/null | grep -Eom1 'https?://[^[:space:]]+' || true)"
  if [[ -n "$dashboard_url" ]]; then
    if open_auth_url "$dashboard_url"; then
      log "已自动打开控制面板: $dashboard_url"
    else
      log "请手动访问控制面板: $dashboard_url"
    fi
  else
    log "你可以执行: openclaw dashboard 打开控制面板。"
  fi
}

main() {
  step "预检查与安装目录"
  init_install_paths
  choose_install_mode
  choose_model_region
  ensure_dir "$INSTALL_DIR_DEFAULT"
  ensure_dir "$OPENCLAW_STATE_DIR"

  step "依赖检查"
  install_missing_bins

  if [[ "$INSTALL_MODE" == "local" ]]; then
    step "下载本地安装依赖包"
    prepare_local_packages
  fi
  ensure_node_22
  if [[ "$INSTALL_MODE" == "online" ]]; then
    npm_tls_preflight
  fi

  persist_env

  step "检查 Docker 沙盒依赖"
  ensure_docker_for_sandbox

  step "安装 OpenClaw"
  install_openclaw

  step "执行 Onboard（安装模式）"
  run_onboard

  step "安装插件与依赖"
  install_skill_dependencies

  step "配置 Agent（主 Agent + 子 Agent + 渠道绑定）"
  configure_all_agents

  verify_and_finalize
}

trap 'warn "失败步骤: STEP ${STEP_ID}，命令: ${BASH_COMMAND}"' ERR

if [[ "$RUN_MODE" == "uninstall" ]]; then
  uninstall_openclaw
else
  main "$@"
fi
