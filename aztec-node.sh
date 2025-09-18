#!/usr/bin/env bash
# aztec-node.sh
# Ubuntu 22.04/24.04
# - Idempotent (chạy lại an toàn)
# - Tự hỏi biến cấu hình lần đầu, lưu vào /opt/aztec/.env
# - Derive COINBASE từ VALIDATOR_PRIVATE_KEY bằng Node (chạy trong Docker tạm thời, không cài Node trên host)
# - Nâng cấp an toàn Aztec CLI + Docker image theo version trong .env
# - Dùng docker compose (plugin)
# ---------------------------------------------------------------

set -euo pipefail

APP_NAME="aztec-node"
LOCKFILE="/var/lock/${APP_NAME}.lock"
INSTALL_DIR="/opt/aztec"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

DOCKER_IMAGE_REPO="aztecprotocol/aztec"
DEFAULT_CLI_VERSION="1.2.0"
DEFAULT_IMAGE_TAG="latest"
DEFAULT_LOG_LEVEL="info"

# ----------------- Helpers -----------------
log()  { echo -e "\033[1;32m[$APP_NAME]\033[0m $*"; }
warn() { echo -e "\033[1;33m[$APP_NAME][WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[$APP_NAME][ERR]\033[0m $*"; }
die()  { err "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Vui lòng chạy với sudo/root."; }

with_lock() {
  exec 9>"$LOCKFILE"
  if ! command -v flock >/dev/null 2>&1; then
    warn "Thiếu 'flock', tiếp tục không dùng lock (không khuyến nghị)."
    return
  fi
  flock -n 9 || die "Script đang chạy nơi khác (lock $LOCKFILE)."
}

have() { command -v "$1" >/dev/null 2>&1; }

ensure_pkg() {
  local pkgs=("$@") to_install=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || to_install+=("$p"); done
  if ((${#to_install[@]})); then
    log "Cài gói: ${to_install[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}"
  fi
}

ensure_docker() {
  if ! have docker || ! docker --version | grep -q "Docker"; then
    log "Cài Docker CE + Compose plugin…"
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do apt-get remove -y "$pkg" >/dev/null 2>&1 || true; done
    ensure_pkg ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
      | tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt-get update -y
    ensure_pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl restart docker
  fi
  docker run --rm hello-world >/dev/null 2>&1 || die "Docker chưa chạy OK."
}

ensure_basics() {
  ensure_pkg curl jq lz4 git make gcc build-essential ufw nano htop tmux unzip grep sed gawk util-linux
}

ensure_firewall() {
  if have ufw && ufw status | grep -qi active; then
    for r in "22" "40400" "8080"; do ufw status | grep -qE " ${r}/(tcp|udp) " || ufw allow "$r" >/dev/null 2>&1 || true; done
  else
    warn "UFW không hoạt động hoặc chưa bật; bỏ qua mở cổng."
  fi
}

ensure_cli_installer() {
  if ! command -v aztec-up >/dev/null 2>&1 && ! command -v aztec >/dev/null 2>&1; then
    log "Cài Aztec CLI tools (non-interactive, không mở shell mới)…"
    # yes cài, no KHÔNG tự sửa PATH / KHÔNG mở shell mới
    printf 'y\nn\n' | bash <(curl -fsSL https://install.aztec.network)

    # Persist PATH cho các phiên sau
    if ! grep -q '.aztec/bin' /root/.bashrc 2>/dev/null; then
      echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> /root/.bashrc
    fi
  fi

  # ĐẢM BẢO PATH CHO PHIÊN HIỆN TẠI (không source .bashrc để tránh PS1)
  export PATH="/root/.aztec/bin:$PATH"
}


install_or_upgrade_cli() {
  local target="${1:-$DEFAULT_CLI_VERSION}"
  ensure_cli_installer
  if have aztec-up; then
    log "Cập nhật Aztec CLI → ${target}…"
    aztec-up "$target" || warn "aztec-up cảnh báo/không cần thiết."
  else
    warn "Không tìm thấy aztec-up; bỏ qua update CLI."
  fi
}

detect_public_ip() { curl -s ipv4.icanhazip.com || true; }

stamp_backup() {
  local f="$1"; [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.$(date +%Y%m%d%H%M%S).bak"
}

mk_dirs() { mkdir -p "$INSTALL_DIR"; }

# ----------------- .env handling -----------------
# Yêu cầu biến:
#  - ETHEREUM_RPC_URL (https)
#  - CONSENSUS_BEACON_URL (https)
#  - VALIDATOR_PRIVATE_KEY (0x + 64 hex)
#  - COINBASE (0x + 40 hex) → có thể derive từ private key
#  - P2P_IP (auto detect)
#  - AZTEC_CLI_VERSION (default 1.2.0)
#  - AZTEC_IMAGE_TAG (default latest)
#  - AZTEC_LOG_LEVEL (default info)

load_env_if_exists() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

ask_var() {
  local key="$1" prompt="$2" regex="$3" default="${4:-}"
  local cur="${!key:-}"
  if [[ -n "$cur" ]]; then
    echo "$key đã có."
    return
  fi
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "$prompt [$default]: " val
      val="${val:-$default}"
    else
      read -rp "$prompt: " val
    fi
    if [[ "$val" =~ $regex ]]; then
      export "$key"="$val"
      break
    else
      echo "Giá trị không hợp lệ, nhập lại."
    fi
  done
}

derive_address_from_pk() {
  # Dùng Docker Node 20 alpine + ethers để derive address từ private key (không cài Node trên host)
  local pk="$1"
  docker run --rm -e PRIV="$pk" node:20-alpine sh -lc \
    'npm i -g ethers@6 >/dev/null 2>&1 && node -e '\''const {Wallet}=require("ethers"); console.log(new Wallet(process.env.PRIV).address)'\''' \
    2>/dev/null | tail -n1
}

ensure_env_interactive() {
  load_env_if_exists

  ask_var ETHEREUM_RPC_URL "Nhập ETHEREUM_RPC_URL (RPC Sepolia HTTPS)" '^https?://'
  ask_var CONSENSUS_BEACON_URL "Nhập CONSENSUS_BEACON_URL (Beacon Sepolia HTTPS)" '^https?://'
  ask_var VALIDATOR_PRIVATE_KEY "Nhập VALIDATOR_PRIVATE_KEY (0x + 64 hex)" '^0x[0-9a-fA-F]{64}$'

  # Derive COINBASE nếu chưa có
  if [[ -z "${COINBASE:-}" ]]; then
    echo "Đang derive COINBASE từ VALIDATOR_PRIVATE_KEY…"
    local derived; derived="$(derive_address_from_pk "$VALIDATOR_PRIVATE_KEY" || true)"
    if [[ "$derived" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
      echo "COINBASE (auto) = $derived"
      COINBASE="$derived"
    else
      warn "Không derive được COINBASE tự động."
      ask_var COINBASE "Nhập COINBASE (0x + 40 hex)" '^0x[0-9a-fA-F]{40}$'
    fi
  else
    # Nếu có COINBASE, kiểm tra khớp private key (chỉ cảnh báo, không ép)
    local derived; derived="$(derive_address_from_pk "$VALIDATOR_PRIVATE_KEY" || true)"
    if [[ "$derived" =~ ^0x[0-9a-fA-F]{40}$ ]] && [[ "${COINBASE,,}" != "${derived,,}" ]]; then
      warn "COINBASE ($COINBASE) KHÔNG KHỚP với địa chỉ derive từ PRIVATE_KEY ($derived)."
      read -rp "Bạn muốn dùng địa chỉ derive ($derived) thay cho COINBASE hiện tại? [y/N]: " ans
      if [[ "${ans,,}" == "y" ]]; then COINBASE="$derived"; fi
    fi
  fi

  # P2P_IP
  if [[ -z "${P2P_IP:-}" ]]; then
    P2P_IP="$(detect_public_ip || true)"
    if [[ -z "$P2P_IP" ]]; then warn "Không phát hiện được P2P_IP, bạn có thể điền tay sau trong .env."; fi
  fi

  # Version/tag/log level (có default)
  : "${AZTEC_CLI_VERSION:=$DEFAULT_CLI_VERSION}"
  : "${AZTEC_IMAGE_TAG:=$DEFAULT_IMAGE_TAG}"
  : "${AZTEC_LOG_LEVEL:=$DEFAULT_LOG_LEVEL}"

  # Validate cuối cùng
  [[ "$ETHEREUM_RPC_URL" =~ ^https?:// ]] || die "ETHEREUM_RPC_URL không hợp lệ."
  [[ "$CONSENSUS_BEACON_URL" =~ ^https?:// ]] || die "CONSENSUS_BEACON_URL không hợp lệ."
  [[ "$VALIDATOR_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "VALIDATOR_PRIVATE_KEY không hợp lệ."
  [[ "$COINBASE" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "COINBASE không hợp lệ."

  # Ghi .env (backup nếu thay đổi)
  mkdir -p "$INSTALL_DIR"
  local tmp; tmp="$(mktemp)"
  cat >"$tmp"<<EOF
# ------ Aztec Node ENV (auto-generated) ------
ETHEREUM_RPC_URL=${ETHEREUM_RPC_URL}
CONSENSUS_BEACON_URL=${CONSENSUS_BEACON_URL}
VALIDATOR_PRIVATE_KEY=${VALIDATOR_PRIVATE_KEY}
COINBASE=${COINBASE}
P2P_IP=${P2P_IP}

# Versions
AZTEC_CLI_VERSION=${AZTEC_CLI_VERSION}
AZTEC_IMAGE_TAG=${AZTEC_IMAGE_TAG}
AZTEC_LOG_LEVEL=${AZTEC_LOG_LEVEL}
EOF

  if [[ -f "$ENV_FILE" ]] && ! cmp -s "$tmp" "$ENV_FILE"; then
    stamp_backup "$ENV_FILE"
  fi
  mv "$tmp" "$ENV_FILE"
  log "Đã lưu cấu hình vào $ENV_FILE"
}

# ----------------- docker-compose -----------------
ensure_compose_file() {
  local tag="${AZTEC_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
  local tmp; tmp="$(mktemp)"
  cat >"$tmp"<<'YAML'
services:
  aztec-node:
    container_name: aztec-sequencer
    network_mode: host
    image: __IMAGE_REPO__:__IMAGE_TAG__
    restart: unless-stopped
    env_file:
      - .env
    environment:
      ETHEREUM_HOSTS: ${ETHEREUM_RPC_URL}
      L1_CONSENSUS_HOST_URLS: ${CONSENSUS_BEACON_URL}
      DATA_DIRECTORY: /data
      VALIDATOR_PRIVATE_KEY: ${VALIDATOR_PRIVATE_KEY}
      COINBASE: ${COINBASE}
      P2P_IP: ${P2P_IP}
      LOG_LEVEL: ${AZTEC_LOG_LEVEL}
    entrypoint: >
      sh -c 'node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js
      start --network testnet --node --archiver --sequencer'
    ports:
      - "40400:40400/tcp"
      - "40400:40400/udp"
      - "8080:8080"
    volumes:
      - /root/.aztec/testnet/data/:/data
YAML

  sed -i "s#__IMAGE_REPO__#${DOCKER_IMAGE_REPO}#g" "$tmp"
  sed -i "s#__IMAGE_TAG__#${tag}#g" "$tmp"

  if [[ -f "$COMPOSE_FILE" ]] && ! cmp -s "$tmp" "$COMPOSE_FILE"; then
    stamp_backup "$COMPOSE_FILE"
  fi
  mv "$tmp" "$COMPOSE_FILE"
  log "Đã cập nhật $COMPOSE_FILE (image tag: $tag)"
}

compose_pull()   { (cd "$INSTALL_DIR" && docker compose pull); }
compose_up()     { (cd "$INSTALL_DIR" && docker compose up -d); }
compose_down()   { (cd "$INSTALL_DIR" && docker compose down -v || true); }
compose_restart(){ (cd "$INSTALL_DIR" && docker compose up -d); }

show_status() {
  if docker ps --format '{{.Names}}' | grep -q '^aztec-sequencer$'; then
    log "Container đang chạy:"
    docker ps --filter "name=aztec-sequencer"
  else
    warn "Container chưa chạy."
  fi
  echo
  log "Kiểm tra sync (đợi vài phút sau khi start):"
  cat <<'CMD'
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":67}' \
  http://localhost:8080 | jq -r ".result.proven.number"
# Đối chiếu height với https://aztecscan.xyz/
CMD
}

# ----------------- Commands -----------------
cmd_install() {
  require_root; with_lock
  log "Cài đặt/khởi chạy Aztec node (idempotent)…"
  ensure_basics
  ensure_docker
  ensure_firewall
  mk_dirs
  ensure_env_interactive
  ensure_compose_file
  install_or_upgrade_cli "${AZTEC_CLI_VERSION:-$DEFAULT_CLI_VERSION}"
  compose_pull
  compose_up
  show_status
}

cmd_upgrade() {
  require_root; with_lock
  log "Nâng cấp an toàn (CLI + Docker image)…"
  load_env_if_exists
  [[ -f "$ENV_FILE" ]] || die "Chưa có $ENV_FILE. Chạy --install trước."
  # Cho phép người dùng chỉnh .env thủ công trước khi upgrade
  ensure_compose_file
  install_or_upgrade_cli "${AZTEC_CLI_VERSION:-$DEFAULT_CLI_VERSION}"
  compose_pull
  compose_restart
  show_status
}

cmd_set_version() {
  require_root; with_lock
  local cli="${1:-}"; local img="${2:-}"
  [[ -n "$cli" || -n "$img" ]] || die "Dùng: --set-version <cli|-> <image|->"
  [[ -f "$ENV_FILE" ]] || die "Chưa có $ENV_FILE. Chạy --install trước."
  stamp_backup "$ENV_FILE"
  awk -v cli="$cli" -v img="$img" '
    BEGIN{FS=OFS="="}
    /^AZTEC_CLI_VERSION=/ {
      if (cli != "-") {$2=cli; print; next}
    }
    /^AZTEC_IMAGE_TAG=/ {
      if (img != "-") {$2=img; print; next}
    }
    {print}
    END{
      # nếu thiếu key thì thêm cuối file
    }
  ' "$ENV_FILE" > "${ENV_FILE}.new"

  # Thêm key nếu thiếu
  grep -q '^AZTEC_CLI_VERSION=' "${ENV_FILE}.new" || echo "AZTEC_CLI_VERSION=${cli/-/$DEFAULT_CLI_VERSION}" >> "${ENV_FILE}.new"
  grep -q '^AZTEC_IMAGE_TAG=' "${ENV_FILE}.new"  || echo "AZTEC_IMAGE_TAG=${img/-/$DEFAULT_IMAGE_TAG}" >> "${ENV_FILE}.new"

  mv "${ENV_FILE}.new" "$ENV_FILE"
  log "Đã cập nhật version trong $ENV_FILE"
}

cmd_status()  { show_status; }
cmd_restart() { require_root; with_lock; compose_restart; show_status; }

cmd_uninstall() {
  require_root; with_lock
  read -r -p "Gỡ container & xóa docker-compose/.env? (data ~/.aztec vẫn giữ) [y/N]: " ans
  if [[ "${ans,,}" == "y" ]]; then
    compose_down
    rm -f "$COMPOSE_FILE" "$ENV_FILE"
    log "Đã gỡ container & file cấu hình. Dữ liệu ~/.aztec giữ nguyên."
  else
    log "Bỏ qua."
  fi
}

print_help() {
  cat <<EOF
$APP_NAME - Aztec node manager (idempotent) + safe upgrade

Usage:
  $0 --install               Cài đặt/khởi chạy (tự hỏi & lưu /opt/aztec/.env nếu thiếu)
  $0 --upgrade               Nâng cấp an toàn (CLI + Docker image, dựa theo .env)
  $0 --set-version <cli|-> <image|->   Cập nhật version trong .env (dùng '-' để giữ nguyên)
  $0 --status                Xem trạng thái
  $0 --restart               Khởi động lại container
  $0 --uninstall             Gỡ container (giữ data ~/.aztec)
  $0 --help                  Trợ giúp

ENV file:  $ENV_FILE
Compose:   $COMPOSE_FILE
Image:     ${DOCKER_IMAGE_REPO}:\$AZTEC_IMAGE_TAG
EOF
}

# ----------------- Main -----------------
ACTION="${1:---help}"
case "$ACTION" in
  --install)      cmd_install ;;
  --upgrade)      cmd_upgrade ;;
  --set-version)  shift; cmd_set_version "${1:-}" "${2:-}";;
  --status)       cmd_status ;;
  --restart)      cmd_restart ;;
  --uninstall)    cmd_uninstall ;;
  --help|-h|*)    print_help ;;
esac
