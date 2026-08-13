#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${SCRIPT_DIR}/.env"
DATA_DIR="${SCRIPT_DIR}/data"
CLIENT_FILE="${SCRIPT_DIR}/client-config.txt"
SYSCTL_FILE="/etc/sysctl.d/99-proxy-stack.conf"
MODULES_FILE="/etc/modules-load.d/proxy-stack.conf"
TEMP_DIR=""

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m'
  RESET=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" CYAN="" RESET=""
fi

log() { printf '%s==>%s %s\n' "$CYAN" "$RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '%s[ERROR]%s 安装在第 %s 行失败（退出码 %s）。\n' "$RED" "$RESET" "${BASH_LINENO[0]:-unknown}" "$exit_code" >&2
  printf '修复问题后可安全地重新运行 sudo ./install.sh。\n' >&2
  exit "$exit_code"
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

trap on_error ERR
trap cleanup EXIT

prompt_value() {
  local prompt=$1 default_value=$2 result
  if [[ -n "$default_value" ]]; then
    read -r -p "${prompt} [${default_value}]: " result
  else
    read -r -p "${prompt}: " result
  fi
  printf '%s' "${result:-$default_value}"
}

prompt_yes_no() {
  local prompt=$1 default_answer=${2:-y} answer suffix
  if [[ "$default_answer" == "y" ]]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
  while true; do
    read -r -p "${prompt} ${suffix}: " answer
    answer=${answer:-$default_answer}
    case "${answer,,}" in
      y|yes|是) return 0 ;;
      n|no|否) return 1 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

env_get() {
  local key=$1 file=${2:-$ENV_FILE}
  [[ -f "$file" ]] || return 0
  awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

validate_domain() {
  local value=$1
  [[ ${#value} -le 253 ]] && [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_endpoint() {
  local value=$1 octet
  local -a octets
  if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
      (( 10#$octet <= 255 )) || return 1
    done
    return 0
  fi
  validate_domain "$value"
}

validate_email() {
  local value=$1
  [[ -z "$value" || "$value" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

validate_port() {
  local value=$1
  [[ "$value" =~ ^[1-9][0-9]*$ ]] && (( 10#$value <= 65535 ))
}

ask_until_valid() {
  local variable_name=$1 prompt=$2 default_value=$3 validator=$4 value
  while true; do
    value=$(prompt_value "$prompt" "$default_value")
    if "$validator" "$value"; then
      printf -v "$variable_name" '%s' "$value"
      return 0
    fi
    warn "输入值无效：${value}"
  done
}

require_linux_root() {
  [[ "$(uname -s)" == "Linux" ]] || die "此脚本只能在 Linux VPS 上运行。"
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "请用 root 运行，或先安装 sudo。"
    exec sudo --preserve-env=TERM bash "${SCRIPT_DIR}/install.sh" "$@"
  fi
  [[ -r /etc/os-release ]] || die "无法识别 Linux 发行版（缺少 /etc/os-release）。"
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID=${ID:-}
  OS_ID=${OS_ID,,}
  [[ -n "$OS_ID" ]] || die "/etc/os-release 中缺少 ID。"
  OS_LIKE=${ID_LIKE:-}
  case "$(uname -m)" in
    x86_64) SNELL_ARCH=amd64 ;;
    aarch64|arm64) SNELL_ARCH=aarch64 ;;
    *) die "当前仅支持 x86_64 和 aarch64，检测到：$(uname -m)" ;;
  esac
}

package_family() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  else
    die "仅支持带 apt 或 dnf 的发行版。"
  fi
}

install_base_dependencies() {
  local family
  family=$(package_family)
  log "安装基础依赖"
  if [[ "$family" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg openssl unzip iproute2 kmod coreutils findutils
  else
    dnf -y install ca-certificates curl gnupg2 openssl unzip iproute kmod coreutils findutils dnf-plugins-core
  fi
}

setup_apt_docker_repo() {
  local docker_os codename arch
  case "$OS_ID" in
    ubuntu)
      docker_os=ubuntu
      codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
      ;;
    debian)
      docker_os=debian
      codename=${VERSION_CODENAME:-}
      ;;
    *) die "Docker 自动安装暂不支持 ${OS_ID}；请先按 Docker 官方文档安装 Engine 与 Compose plugin。" ;;
  esac
  [[ -n "$codename" ]] || die "无法确定发行版代号。"
  arch=$(dpkg --print-architecture)
  install -m 0755 -d /etc/apt/keyrings
  curl --proto '=https' --tlsv1.2 -fsSL "https://download.docker.com/linux/${docker_os}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf '%s\n' \
    'Types: deb' \
    "URIs: https://download.docker.com/linux/${docker_os}" \
    "Suites: ${codename}" \
    'Components: stable' \
    "Architectures: ${arch}" \
    'Signed-By: /etc/apt/keyrings/docker.asc' \
    > /etc/apt/sources.list.d/docker.sources
  apt-get update
}

setup_dnf_docker_repo() {
  local repo_os
  case "$OS_ID" in
    fedora) repo_os=fedora ;;
    rhel) repo_os=rhel ;;
    centos|rocky|almalinux) repo_os=centos ;;
    *)
      if [[ " $OS_LIKE " == *' rhel '* || " $OS_LIKE " == *' fedora '* ]]; then
        repo_os=centos
      else
        die "Docker 自动安装暂不支持 ${OS_ID}；请先安装 Engine 与 Compose plugin。"
      fi
      ;;
  esac
  if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    dnf config-manager --add-repo "https://download.docker.com/linux/${repo_os}/docker-ce.repo"
  fi
}

install_docker() {
  local family
  family=$(package_family)
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker Engine 与 Compose plugin 已安装，跳过安装"
  else
    log "从 Docker 官方软件源安装 Engine 与 Compose plugin"
    if [[ "$family" == "apt" ]]; then
      setup_apt_docker_repo
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      setup_dnf_docker_repo
      dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  fi
  systemctl enable --now docker
  docker info >/dev/null
  docker compose version >/dev/null
  ok "Docker 可用：$(docker --version)"
}

configure_kernel() {
  local bbr_available
  log "配置 fq、BBR、TCP Fast Open 与网络缓冲区"
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  bbr_available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if [[ " $bbr_available " != *' bbr '* ]]; then
    warn "当前内核/虚拟化环境不提供 TCP BBR：${bbr_available:-unknown}"
    if ! prompt_yes_no "继续部署（不启用 BBR）？" n; then
      die "请升级内核或联系 VPS 服务商启用 BBR 后重试。"
    fi
  fi

  {
    printf '%s\n' '# Managed by proxy-stack/install.sh'
    printf '%s\n' 'net.core.default_qdisc = fq'
    if [[ " $bbr_available " == *' bbr '* ]]; then
      printf '%s\n' 'net.ipv4.tcp_congestion_control = bbr'
    fi
    printf '%s\n' 'net.ipv4.tcp_fastopen = 3'
    printf '%s\n' 'net.core.rmem_max = 16777216'
    printf '%s\n' 'net.core.wmem_max = 16777216'
  } > "$SYSCTL_FILE"
  if [[ " $bbr_available " == *' bbr '* ]]; then
    printf '%s\n' 'tcp_bbr' > "$MODULES_FILE"
  else
    rm -f -- "$MODULES_FILE"
  fi
  sysctl -p "$SYSCTL_FILE"

  if [[ " $bbr_available " == *' bbr '* ]]; then
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || die "BBR 写入后未生效。"
    [[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] || die "fq 写入后未生效。"
    ok "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)"
  fi
}

detect_public_ipv4() {
  local ip=""
  ip=$(curl --proto '=https' --tlsv1.2 -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ip=$(curl --proto '=https' --tlsv1.2 -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)
  fi
  if validate_endpoint "$ip" && [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s' "$ip"
  fi
  return 0
}

collect_settings() {
  local detected_ip old_value
  detected_ip=$(detect_public_ipv4)

  old_value=$(env_get SERVER_ADDRESS)
  ask_until_valid SERVER_ADDRESS "客户端连接地址（VPS IPv4 或直连域名）" "${old_value:-$detected_ip}" validate_endpoint
  old_value=$(env_get HY2_DOMAIN)
  ask_until_valid HY2_DOMAIN "Hysteria 2 域名（必须已有直连 A 记录）" "${old_value:-}" validate_domain
  HY2_DOMAIN=${HY2_DOMAIN,,}
  old_value=$(env_get ACME_EMAIL)
  ask_until_valid ACME_EMAIL "Let's Encrypt 邮箱（可留空）" "${old_value:-}" validate_email

  old_value=$(env_get HY2_PORT)
  ask_until_valid HY2_PORT "Hysteria 2 UDP 端口" "${old_value:-32123}" validate_port
  old_value=$(env_get XRAY_PORT)
  ask_until_valid XRAY_PORT "VLESS Reality TCP 端口" "${old_value:-443}" validate_port
  old_value=$(env_get SNELL_PORT)
  ask_until_valid SNELL_PORT "Snell + ShadowTLS TCP 端口" "${old_value:-32413}" validate_port

  (( XRAY_PORT != SNELL_PORT )) || die "Reality 与 Snell 都使用 TCP，端口不能相同。"
  (( XRAY_PORT != 80 && SNELL_PORT != 80 )) || die "TCP 80 保留给 Hysteria ACME HTTP-01。"

  old_value=$(env_get REALITY_SNI)
  ask_until_valid REALITY_SNI "Reality 伪装域名" "${old_value:-www.apple.com}" validate_domain
  REALITY_SNI=${REALITY_SNI,,}
  old_value=$(env_get SHADOWTLS_SNI)
  ask_until_valid SHADOWTLS_SNI "ShadowTLS v3 握手域名" "${old_value:-www.apple.com}" validate_domain
  SHADOWTLS_SNI=${SHADOWTLS_SNI,,}

  HYSTERIA_IMAGE=${HYSTERIA_IMAGE:-$(env_get HYSTERIA_IMAGE)}
  HYSTERIA_IMAGE=${HYSTERIA_IMAGE:-tobyxdd/hysteria:v2.12.0}
  XRAY_IMAGE=${XRAY_IMAGE:-$(env_get XRAY_IMAGE)}
  XRAY_IMAGE=${XRAY_IMAGE:-ghcr.io/xtls/xray-core:26.7.28}
  SHADOWTLS_IMAGE=${SHADOWTLS_IMAGE:-$(env_get SHADOWTLS_IMAGE)}
  SHADOWTLS_IMAGE=${SHADOWTLS_IMAGE:-ghcr.io/ihciah/shadow-tls:v0.2.25}
  DEBIAN_IMAGE=${DEBIAN_IMAGE:-$(env_get DEBIAN_IMAGE)}
  DEBIAN_IMAGE=${DEBIAN_IMAGE:-debian:bookworm-slim}
  SNELL_VERSION=${SNELL_VERSION:-$(env_get SNELL_VERSION)}
  SNELL_VERSION=${SNELL_VERSION:-5.0.1}
}

check_dns() {
  local detected_ip resolved
  detected_ip=$(detect_public_ipv4)
  resolved=$(getent ahostsv4 "$HY2_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)
  if [[ -z "$resolved" ]]; then
    warn "${HY2_DOMAIN} 暂时没有可解析的 A 记录；ACME 与 HY2 启动会失败。"
    prompt_yes_no "仍然继续？" n || die "请先配置 DNS A 记录。"
  elif [[ -n "$detected_ip" && ",${resolved}," != *",${detected_ip},"* ]]; then
    warn "${HY2_DOMAIN} 解析为 ${resolved}，但本机公网 IPv4 是 ${detected_ip}。"
    prompt_yes_no "确认 DNS/转发配置正确并继续？" n || die "请修正 DNS 后重试。"
  else
    ok "DNS A 记录：${HY2_DOMAIN} -> ${resolved}"
  fi
}

check_tls13_target() {
  local target=$1 label=$2 tls_output
  tls_output=$(timeout 10 openssl s_client -connect "${target}:443" -servername "$target" -tls1_3 </dev/null 2>/dev/null || true)
  if [[ "$tls_output" == *'TLSv1.3'* ]]; then
    ok "${label} 支持 TLS 1.3：${target}"
  else
    warn "无法确认 ${target} 支持 TLS 1.3；${label} 可能无法正常工作。"
    prompt_yes_no "仍使用 ${target}？" n || die "请重新运行并选择支持 TLS 1.3 的域名。"
  fi
}

port_listening() {
  local protocol=$1 port=$2
  if [[ "$protocol" == "tcp" ]]; then
    ss -H -lnt | awk -v port="$port" '$4 ~ (":" port "$") { found=1 } END { exit !found }'
  else
    ss -H -lnu | awk -v port="$port" '$4 ~ (":" port "$") { found=1 } END { exit !found }'
  fi
}

preflight_ports() {
  [[ -f "$ENV_FILE" ]] && return 0
  local item protocol port
  for item in "tcp:80" "tcp:${XRAY_PORT}" "tcp:${SNELL_PORT}" "udp:${HY2_PORT}"; do
    protocol=${item%%:*}
    port=${item##*:}
    if port_listening "$protocol" "$port"; then
      die "${protocol^^} ${port} 已被占用。请释放端口或重新运行后选择其他端口。"
    fi
  done
}

generate_random_credentials() {
  HY2_PASSWORD=$(openssl rand -base64 32 | tr -d '\n=' | tr '/+' '_-')
  SNELL_PSK=$(openssl rand -base64 32 | tr -d '\n=' | tr '/+' '_-')
  SHADOWTLS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n=' | tr '/+' '_-')
  VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
  REALITY_SHORT_ID=$(openssl rand -hex 8)

  log "拉取 Xray 镜像并生成 REALITY X25519 密钥"
  docker pull "$XRAY_IMAGE"
  local key_output
  key_output=$(docker run --rm "$XRAY_IMAGE" x25519)
  REALITY_PRIVATE_KEY=$(printf '%s\n' "$key_output" | awk -F': *' '/PrivateKey|Private key/ {print $2; exit}')
  REALITY_PUBLIC_KEY=$(printf '%s\n' "$key_output" | awk -F': *' '/Password|PublicKey|Public key/ {print $2; exit}')
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "无法解析 xray x25519 输出：${key_output}"
}

load_or_generate_credentials() {
  local required key missing=0 regenerate=n
  required=(HY2_PASSWORD SNELL_PSK SHADOWTLS_PASSWORD VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID)
  if [[ -f "$ENV_FILE" ]]; then
    for key in "${required[@]}"; do
      printf -v "$key" '%s' "$(env_get "$key")"
      [[ -n "${!key}" ]] || missing=1
    done
    if (( missing == 0 )) && prompt_yes_no "检测到已有凭据，是否全部重新生成？" n; then
      regenerate=y
    elif (( missing != 0 )); then
      warn "现有 .env 缺少凭据，将重新生成全部凭据。"
      regenerate=y
    fi
  else
    regenerate=y
  fi
  if [[ "$regenerate" == "y" ]]; then
    generate_random_credentials
  fi
}

backup_existing_config() {
  [[ -f "$ENV_FILE" ]] || return 0
  local backup_dir timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_dir="${SCRIPT_DIR}/backups/${timestamp}"
  install -d -m 0700 "$backup_dir"
  cp -a "$ENV_FILE" "$backup_dir/"
  [[ -f "$CLIENT_FILE" ]] && cp -a "$CLIENT_FILE" "$backup_dir/"
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "$backup_dir/"
  ok "旧配置已备份到 ${backup_dir}"
}

download_snell() {
  local installed_version url archive binary
  installed_version=$(cat "${SCRIPT_DIR}/snell/.snell-version" 2>/dev/null || true)
  if [[ "$installed_version" == "$SNELL_VERSION" && -x "${SCRIPT_DIR}/snell/snell-server" ]]; then
    log "Snell Server v${SNELL_VERSION} 已存在，跳过下载"
    return 0
  fi
  TEMP_DIR=$(mktemp -d)
  archive="${TEMP_DIR}/snell.zip"
  url="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"
  log "从 Surge 官方地址下载 Snell Server v${SNELL_VERSION} (${SNELL_ARCH})"
  curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 "$url" -o "$archive"
  unzip -q "$archive" -d "$TEMP_DIR"
  binary=$(find "$TEMP_DIR" -type f -name snell-server -print -quit)
  [[ -n "$binary" && -s "$binary" ]] || die "Snell 压缩包中没有找到 snell-server。"
  install -m 0755 "$binary" "${SCRIPT_DIR}/snell/snell-server"
  printf '%s\n' "$SNELL_VERSION" > "${SCRIPT_DIR}/snell/.snell-version"
  ok "Snell Server 已下载"
}

write_env() {
  {
    printf '%s\n' 'COMPOSE_PROJECT_NAME=proxy-stack'
    printf 'HYSTERIA_IMAGE=%s\n' "$HYSTERIA_IMAGE"
    printf 'XRAY_IMAGE=%s\n' "$XRAY_IMAGE"
    printf 'SHADOWTLS_IMAGE=%s\n' "$SHADOWTLS_IMAGE"
    printf 'DEBIAN_IMAGE=%s\n' "$DEBIAN_IMAGE"
    printf 'SNELL_VERSION=%s\n' "$SNELL_VERSION"
    printf 'SERVER_ADDRESS=%s\n' "$SERVER_ADDRESS"
    printf 'HY2_DOMAIN=%s\n' "$HY2_DOMAIN"
    printf 'ACME_EMAIL=%s\n' "$ACME_EMAIL"
    printf 'HY2_PORT=%s\n' "$HY2_PORT"
    printf 'XRAY_PORT=%s\n' "$XRAY_PORT"
    printf 'SNELL_PORT=%s\n' "$SNELL_PORT"
    printf 'REALITY_SNI=%s\n' "$REALITY_SNI"
    printf 'SHADOWTLS_SNI=%s\n' "$SHADOWTLS_SNI"
    printf 'HY2_PASSWORD=%s\n' "$HY2_PASSWORD"
    printf 'SNELL_PSK=%s\n' "$SNELL_PSK"
    printf 'SHADOWTLS_PASSWORD=%s\n' "$SHADOWTLS_PASSWORD"
    printf 'VLESS_UUID=%s\n' "$VLESS_UUID"
    printf 'REALITY_PRIVATE_KEY=%s\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%s\n' "$REALITY_PUBLIC_KEY"
    printf 'REALITY_SHORT_ID=%s\n' "$REALITY_SHORT_ID"
  } > "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
}

write_service_configs() {
  install -d -m 0700 "${DATA_DIR}/snell" "${DATA_DIR}/hysteria/acme" "${DATA_DIR}/xray"

  cat > "${DATA_DIR}/snell/snell-server.conf" <<EOF
[snell-server]
listen = 0.0.0.0:23413
psk = ${SNELL_PSK}
ipv6 = false
tfo = true
EOF

  cat > "${DATA_DIR}/hysteria/config.yaml" <<EOF
listen: :32123

acme:
  domains:
    - ${HY2_DOMAIN}
EOF
  if [[ -n "$ACME_EMAIL" ]]; then
    printf '  email: %s\n' "$ACME_EMAIL" >> "${DATA_DIR}/hysteria/config.yaml"
  fi
  cat >> "${DATA_DIR}/hysteria/config.yaml" <<EOF
  ca: letsencrypt
  listenHost: 0.0.0.0
  dir: /var/lib/hysteria/acme
  type: http
  http:
    altPort: 80

auth:
  type: password
  password: "${HY2_PASSWORD}"

congestion:
  type: bbr
  bbrProfile: standard

outbounds:
  - name: direct
    type: direct
    direct:
      mode: 46
      fastOpen: true

masquerade:
  type: proxy
  proxy:
    url: https://www.apple.com/
    rewriteHost: true
EOF

  cat > "${DATA_DIR}/xray/config.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4v6"
      }
    }
  ]
}
EOF
  chmod 0600 "${DATA_DIR}/snell/snell-server.conf" "${DATA_DIR}/hysteria/config.yaml" "${DATA_DIR}/xray/config.json"
}

write_client_config() {
  cat > "$CLIENT_FILE" <<EOF
================ Hysteria 2 URI ================
hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}#HY2

================ Surge Hysteria 2 ================
HY2 = hysteria2, ${HY2_DOMAIN}, ${HY2_PORT}, password=${HY2_PASSWORD}, sni=${HY2_DOMAIN}

================ Surge Snell + ShadowTLS v3 ================
Snell-STLS = snell, ${SERVER_ADDRESS}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, reuse=true, tfo=true, shadow-tls-password=${SHADOWTLS_PASSWORD}, shadow-tls-sni=${SHADOWTLS_SNI}, shadow-tls-version=3

================ VLESS Reality URI ================
vless://${VLESS_UUID}@${SERVER_ADDRESS}:${XRAY_PORT}?type=raw&security=reality&sni=${REALITY_SNI}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&fp=chrome&flow=xtls-rprx-vision#Reality
EOF
  chmod 0600 "$CLIENT_FILE"
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    log "为已启用的 UFW 添加端口规则"
    ufw allow 80/tcp
    ufw allow "${XRAY_PORT}/tcp"
    ufw allow "${SNELL_PORT}/tcp"
    ufw allow "${HY2_PORT}/udp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "为已启用的 firewalld 添加端口规则"
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-port="${XRAY_PORT}/tcp"
    firewall-cmd --permanent --add-port="${SNELL_PORT}/tcp"
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp"
    firewall-cmd --reload
  else
    warn "未检测到已启用的 UFW/firewalld；未修改主机防火墙。"
  fi
  warn "请同时在云厂商安全组放行：80/tcp、${XRAY_PORT}/tcp、${SNELL_PORT}/tcp、${HY2_PORT}/udp。"
}

deploy() {
  cd "$SCRIPT_DIR"
  log "校验 Docker Compose 配置"
  docker compose config --quiet
  log "拉取镜像并构建 Snell 容器"
  docker compose pull
  docker compose build --pull snell
  log "启动代理栈"
  docker compose up -d --force-recreate --remove-orphans
  sleep 3
  docker compose ps

  local failed=0 service state
  for service in snell shadow-tls hysteria xray; do
    state=$(docker compose ps --status running --services | grep -Fx "$service" || true)
    if [[ -z "$state" ]]; then
      warn "服务未运行：${service}"
      failed=1
    fi
  done
  if (( failed != 0 )); then
    docker compose logs --tail=100
    die "至少一个服务启动失败，请查看上面的日志。"
  fi
  ok "全部服务均已启动"
}

print_summary() {
  printf '\n%s\n' '================ 部署完成 ================'
  cat "$CLIENT_FILE"
  printf '\n客户端配置已保存到：%s\n' "$CLIENT_FILE"
  printf '查看状态：cd %s && ./manage.sh status\n' "$SCRIPT_DIR"
  printf '查看日志：cd %s && ./manage.sh logs\n' "$SCRIPT_DIR"
  printf '%s\n' '============================================'
}

main() {
  require_linux_root "$@"
  printf '%s\n' 'Proxy Stack：Hysteria 2 + VLESS Reality + Snell/ShadowTLS v3'
  printf '目标系统：%s %s / %s\n\n' "${PRETTY_NAME:-$OS_ID}" "${VERSION_ID:-}" "$(uname -m)"
  prompt_yes_no "开始安装依赖并部署？" y || exit 0

  install_base_dependencies
  install_docker
  collect_settings
  check_dns
  check_tls13_target "$REALITY_SNI" "Reality 目标"
  if [[ "$SHADOWTLS_SNI" != "$REALITY_SNI" ]]; then
    check_tls13_target "$SHADOWTLS_SNI" "ShadowTLS 握手目标"
  fi
  preflight_ports

  if prompt_yes_no "启用/切换 TCP BBR + fq，并优化网络缓冲区？" y; then
    configure_kernel
  else
    warn "已跳过内核网络参数优化。"
  fi

  load_or_generate_credentials
  backup_existing_config
  download_snell
  write_env
  write_service_configs
  write_client_config
  configure_firewall
  deploy
  print_summary
}

main "$@"
