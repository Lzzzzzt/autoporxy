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
REALITY_TARGET_PORT=""
SHADOWTLS_TARGET_PORT=""
SELF_WEB_PORT=""
SELF_WEB_DOMAINS=""

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

random_high_port() {
  local random_hex candidate excluded conflict
  while true; do
    random_hex=$(openssl rand -hex 4)
    candidate=$((10000 + (16#$random_hex % 55536)))
    conflict=false
    for excluded in "$@"; do
      if [[ -n "$excluded" && "$candidate" == "$excluded" ]]; then
        conflict=true
        break
      fi
    done
    [[ "$conflict" == "false" ]] || continue
    if command -v ss >/dev/null 2>&1 \
      && { port_listening tcp "$candidate" || port_listening udp "$candidate"; }; then
      continue
    fi
    printf '%s' "$candidate"
    return 0
  done
}

validate_bool() { [[ "$1" == "true" || "$1" == "false" ]]; }
validate_nonnegative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
validate_node_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]; }
validate_image() { [[ "$1" =~ ^[A-Za-z0-9._/@:+-]+$ ]]; }
validate_url() {
  local pattern='^https://[A-Za-z0-9._~:/?&=%+#-]+$'
  [[ "$1" =~ $pattern ]]
}
validate_hy2_mode() { [[ "$1" =~ ^(auto|46|64|4|6)$ ]]; }
validate_congestion() { [[ "$1" == "bbr" || "$1" == "reno" ]]; }
validate_bbr_profile() { [[ "$1" =~ ^(standard|conservative|aggressive)$ ]]; }
validate_duration() { [[ "$1" =~ ^[1-9][0-9]*(ms|s|m|h)$ ]]; }
validate_fingerprint() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
validate_steal_mode() { [[ "$1" == "remote" || "$1" == "self" ]]; }
validate_xray_log_level() { [[ "$1" =~ ^(debug|info|warning|error|none)$ ]]; }
validate_shadow_log_level() { [[ "$1" =~ ^(trace|debug|info|warn|error|off)$ ]]; }
validate_domain_strategy() {
  [[ "$1" =~ ^(AsIs|UseIP|UseIPv6v4|UseIPv6|UseIPv4v6|UseIPv4|ForceIP|ForceIPv6v4|ForceIPv6|ForceIPv4v6|ForceIPv4)$ ]]
}
validate_snell_version() { [[ "$1" =~ ^[45]\.[0-9]+\.[0-9]+([A-Za-z0-9.-]*)?$ ]]; }
validate_snell_dns() { [[ -z "$1" || "$1" =~ ^[0-9A-Fa-f:.,]+$ ]]; }

self_web_enabled() {
  [[ "${REALITY_MODE:-remote}" == "self" || "${SHADOWTLS_MODE:-remote}" == "self" ]]
}

append_self_web_domain() {
  local domain=$1
  if [[ -z "$SELF_WEB_DOMAINS" ]]; then
    SELF_WEB_DOMAINS=$domain
  elif [[ ",${SELF_WEB_DOMAINS}," != *",${domain},"* ]]; then
    SELF_WEB_DOMAINS+="${SELF_WEB_DOMAINS:+,}${domain}"
  fi
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
  local detected_ip old_value default_hy2_port default_xray_port default_snell_port
  local old_hy2_masquerade_mode old_reality_mode old_reality_sni
  local old_shadowtls_mode old_shadowtls_sni default_reality_sni default_reality_port
  local default_shadowtls_sni default_shadowtls_port default_self_web_port
  detected_ip=$(detect_public_ipv4)

  printf '\n%s\n' '--- 节点与镜像配置 ---'
  old_value=$(env_get NODE_NAME)
  ask_until_valid NODE_NAME "客户端节点名称" "${old_value:-VPS}" validate_node_name

  old_value=$(env_get HYSTERIA_IMAGE)
  ask_until_valid HYSTERIA_IMAGE "Hysteria 镜像" "${old_value:-tobyxdd/hysteria:latest}" validate_image
  old_value=$(env_get XRAY_IMAGE)
  ask_until_valid XRAY_IMAGE "Xray 镜像" "${old_value:-ghcr.io/xtls/xray-core:latest}" validate_image
  old_value=$(env_get SHADOWTLS_IMAGE)
  ask_until_valid SHADOWTLS_IMAGE "ShadowTLS 镜像" "${old_value:-ghcr.io/ihciah/shadow-tls:latest}" validate_image
  old_value=$(env_get DEBIAN_IMAGE)
  ask_until_valid DEBIAN_IMAGE "Snell 基础镜像" "${old_value:-debian:latest}" validate_image
  old_value=$(env_get SNELL_VERSION)
  ask_until_valid SNELL_VERSION "Snell Server 版本 (4.x/5.x)" "${old_value:-5.0.1}" validate_snell_version
  SNELL_CLIENT_VERSION=${SNELL_VERSION%%.*}
  NGINX_IMAGE=$(env_get NGINX_IMAGE)
  NGINX_IMAGE=${NGINX_IMAGE:-nginx:latest}

  printf '\n%s\n' '--- 地址、证书与端口 ---'
  old_value=$(env_get SERVER_ADDRESS)
  ask_until_valid SERVER_ADDRESS "客户端连接地址（VPS IPv4 或直连域名）" "${old_value:-$detected_ip}" validate_endpoint
  old_value=$(env_get HY2_DOMAIN)
  ask_until_valid HY2_DOMAIN "Hysteria 2 域名（必须已有直连 A 记录）" "${old_value:-}" validate_domain
  HY2_DOMAIN=${HY2_DOMAIN,,}
  old_value=$(env_get ACME_EMAIL)
  ask_until_valid ACME_EMAIL "Let's Encrypt 邮箱（可留空）" "${old_value:-}" validate_email

  old_value=$(env_get HY2_PORT)
  default_hy2_port=${old_value:-$(random_high_port)}
  ask_until_valid HY2_PORT "Hysteria 2 对外监听 UDP 端口（首次部署默认随机）" "$default_hy2_port" validate_port
  old_value=$(env_get XRAY_PORT)
  default_xray_port=${old_value:-$(random_high_port "$HY2_PORT")}
  ask_until_valid XRAY_PORT "VLESS Reality 对外监听 TCP 端口（首次部署默认随机）" "$default_xray_port" validate_port
  old_value=$(env_get SNELL_PORT)
  default_snell_port=${old_value:-$(random_high_port "$HY2_PORT" "$XRAY_PORT")}
  ask_until_valid SNELL_PORT "Snell + ShadowTLS 对外监听 TCP 端口（首次部署默认随机）" "$default_snell_port" validate_port

  (( XRAY_PORT != SNELL_PORT )) || die "Reality 与 Snell 都使用 TCP，端口不能相同。"
  (( XRAY_PORT != 80 && SNELL_PORT != 80 )) || die "TCP 80 保留给 Hysteria ACME HTTP-01。"
  printf '已选择对外端口：HY2 %s/udp，Reality %s/tcp，Snell/ShadowTLS %s/tcp\n' \
    "$HY2_PORT" "$XRAY_PORT" "$SNELL_PORT"

  printf '\n%s\n' '--- Hysteria 2 高级配置 ---'
  old_hy2_masquerade_mode=$(env_get HY2_MASQUERADE_MODE)
  ask_until_valid HY2_MASQUERADE_MODE "HY2 伪装模式 (remote=外部网站/self=本机静态站点)" \
    "${old_hy2_masquerade_mode:-remote}" validate_steal_mode
  old_value=$(env_get HY2_MASQUERADE_URL)
  if [[ "$HY2_MASQUERADE_MODE" == "remote" ]]; then
    ask_until_valid HY2_MASQUERADE_URL "HY2 外部伪装网址" "${old_value:-https://www.apple.com/}" validate_url
  else
    HY2_MASQUERADE_URL=${old_value:-https://www.apple.com/}
    log "HY2 将直接提供本机静态站点，不回源公网网站。"
  fi
  old_value=$(env_get HY2_OUTBOUND_MODE)
  ask_until_valid HY2_OUTBOUND_MODE "HY2 出站地址族模式 (auto/46/64/4/6)" "${old_value:-46}" validate_hy2_mode
  old_value=$(env_get HY2_FAST_OPEN)
  ask_until_valid HY2_FAST_OPEN "HY2 出站 Fast Open (true/false)" "${old_value:-true}" validate_bool
  old_value=$(env_get HY2_CONGESTION)
  ask_until_valid HY2_CONGESTION "HY2 拥塞算法 (bbr/reno)" "${old_value:-bbr}" validate_congestion
  old_value=$(env_get HY2_BBR_PROFILE)
  ask_until_valid HY2_BBR_PROFILE "HY2 BBR 配置 (standard/conservative/aggressive)" "${old_value:-standard}" validate_bbr_profile
  old_value=$(env_get HY2_SPEED_TEST)
  ask_until_valid HY2_SPEED_TEST "允许 HY2 客户端测速 (true/false)" "${old_value:-false}" validate_bool
  old_value=$(env_get HY2_UDP_IDLE_TIMEOUT)
  ask_until_valid HY2_UDP_IDLE_TIMEOUT "HY2 UDP 空闲超时" "${old_value:-60s}" validate_duration

  printf '\n%s\n' '--- VLESS Reality 高级配置 ---'
  old_reality_mode=$(env_get REALITY_MODE)
  ask_until_valid REALITY_MODE "Reality 模式 (remote=外部目标/self=偷自己)" \
    "${old_reality_mode:-remote}" validate_steal_mode
  old_reality_sni=$(env_get REALITY_SNI)
  if [[ "$REALITY_MODE" == "self" ]]; then
    if [[ "$old_reality_mode" == "self" && -n "$old_reality_sni" ]]; then
      default_reality_sni=$old_reality_sni
    else
      default_reality_sni=$HY2_DOMAIN
    fi
    ask_until_valid REALITY_SNI "Reality 偷自己域名（A 记录必须直连本机）" "$default_reality_sni" validate_domain
    REALITY_TARGET_HOST=reality-web
    default_self_web_port=$(env_get SELF_WEB_PORT)
    if [[ -z "$default_self_web_port" && "$old_reality_mode" == "self" ]]; then
      default_self_web_port=$(env_get REALITY_TARGET_PORT)
    fi
  else
    ask_until_valid REALITY_SNI "Reality 伪装 SNI 域名" "${old_reality_sni:-www.apple.com}" validate_domain
    old_value=$(env_get REALITY_TARGET_HOST)
    ask_until_valid REALITY_TARGET_HOST "Reality 外部目标地址（域名或 IP）" "${old_value:-$REALITY_SNI}" validate_endpoint
    if [[ -z "$old_reality_mode" || "$old_reality_mode" == "remote" ]]; then
      default_reality_port=$(env_get REALITY_TARGET_PORT)
    else
      default_reality_port=443
    fi
    ask_until_valid REALITY_TARGET_PORT "Reality 外部目标 TCP 端口" "${default_reality_port:-443}" validate_port
  fi
  REALITY_SNI=${REALITY_SNI,,}
  REALITY_TARGET_HOST=${REALITY_TARGET_HOST,,}
  old_value=$(env_get REALITY_SHOW)
  ask_until_valid REALITY_SHOW "Reality 调试输出 (true/false)" "${old_value:-false}" validate_bool
  old_value=$(env_get REALITY_MAX_TIME_DIFF)
  ask_until_valid REALITY_MAX_TIME_DIFF "Reality 最大时差毫秒 (0 为不限)" "${old_value:-0}" validate_nonnegative_integer
  old_value=$(env_get REALITY_FINGERPRINT)
  ask_until_valid REALITY_FINGERPRINT "Reality 客户端 TLS 指纹" "${old_value:-chrome}" validate_fingerprint
  old_value=$(env_get XRAY_DOMAIN_STRATEGY)
  ask_until_valid XRAY_DOMAIN_STRATEGY "Xray Freedom 地址策略" "${old_value:-UseIPv4v6}" validate_domain_strategy
  old_value=$(env_get XRAY_LOG_LEVEL)
  ask_until_valid XRAY_LOG_LEVEL "Xray 日志级别" "${old_value:-warning}" validate_xray_log_level

  printf '\n%s\n' '--- Snell + ShadowTLS 高级配置 ---'
  old_shadowtls_mode=$(env_get SHADOWTLS_MODE)
  ask_until_valid SHADOWTLS_MODE "ShadowTLS 模式 (remote=外部握手站/self=偷自己)" \
    "${old_shadowtls_mode:-remote}" validate_steal_mode
  old_shadowtls_sni=$(env_get SHADOWTLS_SNI)
  if [[ "$SHADOWTLS_MODE" == "self" ]]; then
    if [[ "$old_shadowtls_mode" == "self" && -n "$old_shadowtls_sni" ]]; then
      default_shadowtls_sni=$old_shadowtls_sni
    else
      default_shadowtls_sni=$HY2_DOMAIN
    fi
    ask_until_valid SHADOWTLS_SNI "ShadowTLS 偷自己域名（A 记录必须直连本机）" \
      "$default_shadowtls_sni" validate_domain
    SHADOWTLS_TARGET_HOST=reality-web
    if [[ -z "$default_self_web_port" ]]; then
      default_self_web_port=$(env_get SELF_WEB_PORT)
      if [[ -z "$default_self_web_port" && "$old_shadowtls_mode" == "self" ]]; then
        default_self_web_port=$(env_get SHADOWTLS_TARGET_PORT)
      fi
    fi
  else
    ask_until_valid SHADOWTLS_SNI "ShadowTLS v3 握手 SNI 域名" \
      "${old_shadowtls_sni:-www.apple.com}" validate_domain
    old_value=$(env_get SHADOWTLS_TARGET_HOST)
    ask_until_valid SHADOWTLS_TARGET_HOST "ShadowTLS 外部握手目标地址（域名或 IP）" \
      "${old_value:-$SHADOWTLS_SNI}" validate_endpoint
    if [[ -z "$old_shadowtls_mode" || "$old_shadowtls_mode" == "remote" ]]; then
      default_shadowtls_port=$(env_get SHADOWTLS_TARGET_PORT)
    else
      default_shadowtls_port=443
    fi
    ask_until_valid SHADOWTLS_TARGET_PORT "ShadowTLS 外部握手目标 TCP 端口" \
      "${default_shadowtls_port:-443}" validate_port
  fi
  SHADOWTLS_SNI=${SHADOWTLS_SNI,,}
  SHADOWTLS_TARGET_HOST=${SHADOWTLS_TARGET_HOST,,}
  old_value=$(env_get SHADOWTLS_STRICT)
  ask_until_valid SHADOWTLS_STRICT "ShadowTLS strict 模式 (true/false)" "${old_value:-true}" validate_bool
  old_value=$(env_get SHADOWTLS_FAST_OPEN)
  ask_until_valid SHADOWTLS_FAST_OPEN "ShadowTLS TCP Fast Open (true/false)" "${old_value:-true}" validate_bool
  old_value=$(env_get SHADOWTLS_LOG_LEVEL)
  ask_until_valid SHADOWTLS_LOG_LEVEL "ShadowTLS 日志级别" "${old_value:-warn}" validate_shadow_log_level
  old_value=$(env_get SNELL_IPV6)
  ask_until_valid SNELL_IPV6 "Snell 出站 IPv6 (true/false)" "${old_value:-false}" validate_bool
  old_value=$(env_get SNELL_TFO)
  ask_until_valid SNELL_TFO "Snell Server TCP Fast Open (true/false)" "${old_value:-true}" validate_bool
  old_value=$(env_get SNELL_DNS)
  ask_until_valid SNELL_DNS "Snell DNS 服务器（IP，可留空）" "${old_value:-}" validate_snell_dns
  old_value=$(env_get SNELL_CLIENT_REUSE)
  ask_until_valid SNELL_CLIENT_REUSE "Surge Snell 连接复用 (true/false)" "${old_value:-true}" validate_bool
  old_value=$(env_get SNELL_CLIENT_TFO)
  ask_until_valid SNELL_CLIENT_TFO "Surge Snell TCP Fast Open (true/false)" "${old_value:-true}" validate_bool

  if self_web_enabled; then
    SELF_WEB_PORT=${default_self_web_port:-8443}
    if ! validate_port "$SELF_WEB_PORT" || (( 10#$SELF_WEB_PORT < 1024 )); then
      warn "现有内部 TLS 站点端口 ${SELF_WEB_PORT} 无效或需要额外低端口权限，已改用 8443。"
      SELF_WEB_PORT=8443
    fi
    old_value=$(env_get NGINX_IMAGE)
    ask_until_valid NGINX_IMAGE "共享内部 TLS 站点 Nginx 镜像" "${old_value:-nginx:latest}" validate_image
    COMPOSE_PROFILES=self
    SELF_WEB_DOMAINS=""
    if [[ "$REALITY_MODE" == "self" ]]; then
      REALITY_TARGET_PORT=$SELF_WEB_PORT
      append_self_web_domain "$REALITY_SNI"
    fi
    if [[ "$SHADOWTLS_MODE" == "self" ]]; then
      SHADOWTLS_TARGET_PORT=$SELF_WEB_PORT
      append_self_web_domain "$SHADOWTLS_SNI"
    fi
  else
    SELF_WEB_PORT=8443
    SELF_WEB_DOMAINS=""
    COMPOSE_PROFILES=""
  fi

  if [[ "$SHADOWTLS_MODE" == "remote" && "$SHADOWTLS_TARGET_PORT" == "$SNELL_PORT" \
    && ( "$SHADOWTLS_TARGET_HOST" == "$SERVER_ADDRESS" || "$SHADOWTLS_TARGET_HOST" == "$HY2_DOMAIN" ) ]]; then
    die "ShadowTLS 外部握手目标指向本机 Snell/ShadowTLS 入口，会形成回连循环。"
  fi

  SHADOWTLS_STRICT_ENV=""
  SHADOWTLS_FAST_OPEN_ENV=""
  if [[ "$SHADOWTLS_STRICT" == "true" ]]; then SHADOWTLS_STRICT_ENV=1; fi
  if [[ "$SHADOWTLS_FAST_OPEN" == "true" ]]; then SHADOWTLS_FAST_OPEN_ENV=1; fi
}

check_dns() {
  local detected_ip resolved domain label index
  local -a domains labels
  detected_ip=$(detect_public_ipv4)
  domains=("$HY2_DOMAIN")
  labels=("Hysteria")
  if [[ "$REALITY_MODE" == "self" && "$REALITY_SNI" != "$HY2_DOMAIN" ]]; then
    domains+=("$REALITY_SNI")
    labels+=("Reality 偷自己")
  fi
  if [[ "$SHADOWTLS_MODE" == "self" && "$SHADOWTLS_SNI" != "$HY2_DOMAIN" \
    && ( "$REALITY_MODE" != "self" || "$SHADOWTLS_SNI" != "$REALITY_SNI" ) ]]; then
    domains+=("$SHADOWTLS_SNI")
    labels+=("ShadowTLS 偷自己")
  fi
  for index in "${!domains[@]}"; do
    domain=${domains[$index]}
    label=${labels[$index]}
    resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)
    if [[ -z "$resolved" ]]; then
      warn "${label} 域名 ${domain} 暂时没有可解析的 A 记录；ACME 签发会失败。"
      prompt_yes_no "仍然继续？" n || die "请先配置 DNS A 记录。"
    elif [[ -n "$detected_ip" && ",${resolved}," != *",${detected_ip},"* ]]; then
      warn "${label} 域名 ${domain} 解析为 ${resolved}，但本机公网 IPv4 是 ${detected_ip}。"
      prompt_yes_no "确认 DNS/转发配置正确并继续？" n || die "请修正 DNS 后重试。"
    else
      ok "${label} DNS A 记录：${domain} -> ${resolved}"
    fi
  done
}

check_tls13_target() {
  local target=$1 server_name=$2 label=$3 port=$4 tls_output
  tls_output=$(timeout 10 openssl s_client -connect "${target}:${port}" -servername "$server_name" -tls1_3 </dev/null 2>/dev/null || true)
  if [[ "$tls_output" == *'TLSv1.3'* ]]; then
    ok "${label} 支持 TLS 1.3：${target}:${port} (SNI ${server_name})"
  else
    warn "无法确认 ${target}:${port} 支持 TLS 1.3；${label} 可能无法正常工作。"
    prompt_yes_no "仍使用 ${target}:${port}？" n || die "请重新运行并选择支持 TLS 1.3 的目标。"
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

compose_owns_host_port() {
  local service=$1 container_port=$2 protocol=$3 host_port=$4 bindings
  [[ -f "$ENV_FILE" ]] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  bindings=$(docker compose --project-directory "$SCRIPT_DIR" port \
    --protocol "$protocol" "$service" "$container_port" 2>/dev/null || true)
  [[ -n "$bindings" ]] || return 1
  printf '%s\n' "$bindings" \
    | awk -v port="$host_port" '$0 ~ (":" port "$") { found=1 } END { exit !found }'
}

preflight_ports() {
  local item protocol port service container_port
  for item in \
    "tcp|80|hysteria|80" \
    "tcp|${XRAY_PORT}|xray|443" \
    "tcp|${SNELL_PORT}|shadow-tls|32413" \
    "udp|${HY2_PORT}|hysteria|32123"; do
    IFS='|' read -r protocol port service container_port <<< "$item"
    if port_listening "$protocol" "$port"; then
      if compose_owns_host_port "$service" "$container_port" "$protocol" "$port"; then
        log "${protocol^^} ${port} 当前由本项目 ${service} 使用，部署时将复用。"
      else
        die "${protocol^^} ${port} 已被其他程序占用。请释放端口或重新运行后选择其他端口。"
      fi
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
    printf 'COMPOSE_PROFILES=%s\n' "$COMPOSE_PROFILES"
    printf 'NODE_NAME=%s\n' "$NODE_NAME"
    printf 'HYSTERIA_IMAGE=%s\n' "$HYSTERIA_IMAGE"
    printf 'XRAY_IMAGE=%s\n' "$XRAY_IMAGE"
    printf 'SHADOWTLS_IMAGE=%s\n' "$SHADOWTLS_IMAGE"
    printf 'NGINX_IMAGE=%s\n' "$NGINX_IMAGE"
    printf 'SELF_WEB_PORT=%s\n' "$SELF_WEB_PORT"
    printf 'SELF_WEB_DOMAINS=%s\n' "$SELF_WEB_DOMAINS"
    printf 'DEBIAN_IMAGE=%s\n' "$DEBIAN_IMAGE"
    printf 'SNELL_VERSION=%s\n' "$SNELL_VERSION"
    printf 'SNELL_CLIENT_VERSION=%s\n' "$SNELL_CLIENT_VERSION"
    printf 'SERVER_ADDRESS=%s\n' "$SERVER_ADDRESS"
    printf 'HY2_DOMAIN=%s\n' "$HY2_DOMAIN"
    printf 'ACME_EMAIL=%s\n' "$ACME_EMAIL"
    printf 'HY2_PORT=%s\n' "$HY2_PORT"
    printf 'XRAY_PORT=%s\n' "$XRAY_PORT"
    printf 'SNELL_PORT=%s\n' "$SNELL_PORT"
    printf 'HY2_MASQUERADE_MODE=%s\n' "$HY2_MASQUERADE_MODE"
    printf 'HY2_MASQUERADE_URL=%s\n' "$HY2_MASQUERADE_URL"
    printf 'HY2_OUTBOUND_MODE=%s\n' "$HY2_OUTBOUND_MODE"
    printf 'HY2_FAST_OPEN=%s\n' "$HY2_FAST_OPEN"
    printf 'HY2_CONGESTION=%s\n' "$HY2_CONGESTION"
    printf 'HY2_BBR_PROFILE=%s\n' "$HY2_BBR_PROFILE"
    printf 'HY2_SPEED_TEST=%s\n' "$HY2_SPEED_TEST"
    printf 'HY2_UDP_IDLE_TIMEOUT=%s\n' "$HY2_UDP_IDLE_TIMEOUT"
    printf 'REALITY_MODE=%s\n' "$REALITY_MODE"
    printf 'REALITY_SNI=%s\n' "$REALITY_SNI"
    printf 'REALITY_TARGET_HOST=%s\n' "$REALITY_TARGET_HOST"
    printf 'REALITY_TARGET_PORT=%s\n' "$REALITY_TARGET_PORT"
    printf 'REALITY_SHOW=%s\n' "$REALITY_SHOW"
    printf 'REALITY_MAX_TIME_DIFF=%s\n' "$REALITY_MAX_TIME_DIFF"
    printf 'REALITY_FINGERPRINT=%s\n' "$REALITY_FINGERPRINT"
    printf 'XRAY_DOMAIN_STRATEGY=%s\n' "$XRAY_DOMAIN_STRATEGY"
    printf 'XRAY_LOG_LEVEL=%s\n' "$XRAY_LOG_LEVEL"
    printf 'SHADOWTLS_MODE=%s\n' "$SHADOWTLS_MODE"
    printf 'SHADOWTLS_SNI=%s\n' "$SHADOWTLS_SNI"
    printf 'SHADOWTLS_TARGET_HOST=%s\n' "$SHADOWTLS_TARGET_HOST"
    printf 'SHADOWTLS_TARGET_PORT=%s\n' "$SHADOWTLS_TARGET_PORT"
    printf 'SHADOWTLS_STRICT=%s\n' "$SHADOWTLS_STRICT"
    printf 'SHADOWTLS_FAST_OPEN=%s\n' "$SHADOWTLS_FAST_OPEN"
    printf 'SHADOWTLS_STRICT_ENV=%s\n' "$SHADOWTLS_STRICT_ENV"
    printf 'SHADOWTLS_FAST_OPEN_ENV=%s\n' "$SHADOWTLS_FAST_OPEN_ENV"
    printf 'SHADOWTLS_LOG_LEVEL=%s\n' "$SHADOWTLS_LOG_LEVEL"
    printf 'SNELL_IPV6=%s\n' "$SNELL_IPV6"
    printf 'SNELL_TFO=%s\n' "$SNELL_TFO"
    printf 'SNELL_DNS=%s\n' "$SNELL_DNS"
    printf 'SNELL_CLIENT_REUSE=%s\n' "$SNELL_CLIENT_REUSE"
    printf 'SNELL_CLIENT_TFO=%s\n' "$SNELL_CLIENT_TFO"
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

write_self_web_server_block() {
  local domain=$1 default_suffix=$2
  cat >> "${DATA_DIR}/reality/nginx.conf" <<EOF

  server {
    listen ${SELF_WEB_PORT} ssl${default_suffix};
    http2 on;
    server_name ${domain};

    ssl_certificate /var/lib/hysteria/acme/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.crt;
    ssl_certificate_key /var/lib/hysteria/acme/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1h;

    root /usr/share/nginx/html;
    index index.html;
    location / {
      try_files \$uri \$uri/ =404;
    }
  }
EOF
}

write_service_configs() {
  install -d -m 0700 \
    "${DATA_DIR}/snell" \
    "${DATA_DIR}/hysteria/acme" \
    "${DATA_DIR}/reality" \
    "${DATA_DIR}/xray"
  install -d -m 0755 "${DATA_DIR}/reality/www"

  cat > "${DATA_DIR}/snell/snell-server.conf" <<EOF
[snell-server]
listen = 0.0.0.0:23413
psk = ${SNELL_PSK}
ipv6 = ${SNELL_IPV6}
tfo = ${SNELL_TFO}
EOF
  if [[ -n "$SNELL_DNS" ]]; then
    printf 'dns = %s\n' "$SNELL_DNS" >> "${DATA_DIR}/snell/snell-server.conf"
  fi

  cat > "${DATA_DIR}/hysteria/config.yaml" <<EOF
listen: :32123

acme:
  domains:
    - ${HY2_DOMAIN}
EOF
  if [[ "$REALITY_MODE" == "self" && "$REALITY_SNI" != "$HY2_DOMAIN" ]]; then
    printf '    - %s\n' "$REALITY_SNI" >> "${DATA_DIR}/hysteria/config.yaml"
  fi
  if [[ "$SHADOWTLS_MODE" == "self" && "$SHADOWTLS_SNI" != "$HY2_DOMAIN" \
    && ( "$REALITY_MODE" != "self" || "$SHADOWTLS_SNI" != "$REALITY_SNI" ) ]]; then
    printf '    - %s\n' "$SHADOWTLS_SNI" >> "${DATA_DIR}/hysteria/config.yaml"
  fi
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

speedTest: ${HY2_SPEED_TEST}
udpIdleTimeout: ${HY2_UDP_IDLE_TIMEOUT}

congestion:
  type: ${HY2_CONGESTION}
EOF
  if [[ "$HY2_CONGESTION" == "bbr" ]]; then
    printf '  bbrProfile: %s\n' "$HY2_BBR_PROFILE" >> "${DATA_DIR}/hysteria/config.yaml"
  fi
  cat >> "${DATA_DIR}/hysteria/config.yaml" <<EOF

outbounds:
  - name: direct
    type: direct
    direct:
      mode: ${HY2_OUTBOUND_MODE}
      fastOpen: ${HY2_FAST_OPEN}
EOF

  if [[ "$HY2_MASQUERADE_MODE" == "self" ]]; then
    cat >> "${DATA_DIR}/hysteria/config.yaml" <<EOF
masquerade:
  type: file
  file:
    dir: /www/masq
EOF
  else
    cat >> "${DATA_DIR}/hysteria/config.yaml" <<EOF
masquerade:
  type: proxy
  proxy:
    url: "${HY2_MASQUERADE_URL}"
    rewriteHost: true
EOF
  fi

  cat > "${DATA_DIR}/reality/www/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${NODE_NAME}</title></head>
<body><main><h1>Welcome</h1><p>This site is up and running.</p></main></body>
</html>
EOF

  if self_web_enabled; then
    cat > "${DATA_DIR}/reality/nginx.conf" <<EOF
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;

events {
  worker_connections 1024;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log /dev/stdout;
  error_log /dev/stderr warn;
  server_tokens off;
EOF
    local default_suffix=" default_server"
    if [[ "$REALITY_MODE" == "self" ]]; then
      write_self_web_server_block "$REALITY_SNI" "$default_suffix"
      default_suffix=""
    fi
    if [[ "$SHADOWTLS_MODE" == "self" \
      && ( "$REALITY_MODE" != "self" || "$SHADOWTLS_SNI" != "$REALITY_SNI" ) ]]; then
      write_self_web_server_block "$SHADOWTLS_SNI" "$default_suffix"
    fi
    printf '}\n' >> "${DATA_DIR}/reality/nginx.conf"
  fi

  cat > "${DATA_DIR}/xray/config.json" <<EOF
{
  "log": {
    "loglevel": "${XRAY_LOG_LEVEL}"
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
          "show": ${REALITY_SHOW},
          "target": "${REALITY_TARGET_HOST}:${REALITY_TARGET_PORT}",
          "xver": 0,
          "maxTimeDiff": ${REALITY_MAX_TIME_DIFF},
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
        "domainStrategy": "${XRAY_DOMAIN_STRATEGY}"
      }
    }
  ]
}
EOF
  chmod 0600 "${DATA_DIR}/snell/snell-server.conf" "${DATA_DIR}/hysteria/config.yaml" "${DATA_DIR}/xray/config.json"
  chmod 0644 "${DATA_DIR}/reality/www/index.html"
  if self_web_enabled; then
    chmod 0600 "${DATA_DIR}/reality/nginx.conf"
  fi
}

write_client_config() {
  cat > "$CLIENT_FILE" <<EOF
================ Hysteria 2 URI ================
hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}#${NODE_NAME}-HY2

================ Surge Hysteria 2 ================
${NODE_NAME}-HY2 = hysteria2, ${HY2_DOMAIN}, ${HY2_PORT}, password=${HY2_PASSWORD}, sni=${HY2_DOMAIN}

================ Surge Snell + ShadowTLS v3 ================
${NODE_NAME}-Snell-STLS = snell, ${SERVER_ADDRESS}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=${SNELL_CLIENT_VERSION}, reuse=${SNELL_CLIENT_REUSE}, tfo=${SNELL_CLIENT_TFO}, shadow-tls-password=${SHADOWTLS_PASSWORD}, shadow-tls-sni=${SHADOWTLS_SNI}, shadow-tls-version=3

================ VLESS Reality URI ================
vless://${VLESS_UUID}@${SERVER_ADDRESS}:${XRAY_PORT}?type=raw&security=reality&sni=${REALITY_SNI}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&fp=${REALITY_FINGERPRINT}&flow=xtls-rprx-vision#${NODE_NAME}-Reality
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

wait_for_self_web() {
  self_web_enabled || return 0
  local container_id health attempt domain cert_file
  local -a self_domains
  container_id=$(docker compose ps -q reality-web)
  [[ -n "$container_id" ]] || die "共享内部 TLS 站点容器未创建。"
  IFS=',' read -r -a self_domains <<< "$SELF_WEB_DOMAINS"
  log "等待偷自己证书签发与共享内部 Nginx 就绪"
  for (( attempt=1; attempt<=60; attempt++ )); do
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")
    if [[ "$health" == "healthy" ]]; then
      for domain in "${self_domains[@]}"; do
        cert_file="${DATA_DIR}/hysteria/acme/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.crt"
        openssl x509 -in "$cert_file" -noout -checkhost "$domain" >/dev/null \
          || die "共享内部站点证书不包含域名 ${domain}。"
        openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null \
          || die "共享内部站点证书 ${domain} 即将在 24 小时内过期。"
      done
      ok "共享内部 TLS 站点已就绪：reality-web:${SELF_WEB_PORT} (${SELF_WEB_DOMAINS})"
      return 0
    fi
    sleep 2
  done
  docker compose logs --tail=100 hysteria reality-web
  die "共享内部 TLS 站点在 120 秒内未就绪，请检查偷自己域名、TCP 80 与 ACME 日志。"
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
  local -a services=(snell shadow-tls hysteria xray)
  if self_web_enabled; then
    services+=(reality-web)
  fi
  for service in "${services[@]}"; do
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
  wait_for_self_web
  ok "全部服务均已启动"
}

print_summary() {
  printf '\n%s\n' '================ 部署完成 ================'
  printf '对外监听端口：HY2 %s/udp，Reality %s/tcp，Snell/ShadowTLS %s/tcp\n\n' \
    "$HY2_PORT" "$XRAY_PORT" "$SNELL_PORT"
  printf '伪装模式：HY2 %s，Reality %s，ShadowTLS %s\n\n' \
    "$HY2_MASQUERADE_MODE" "$REALITY_MODE" "$SHADOWTLS_MODE"
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
  if [[ "$REALITY_MODE" == "remote" ]]; then
    check_tls13_target "$REALITY_TARGET_HOST" "$REALITY_SNI" "Reality 外部目标" "$REALITY_TARGET_PORT"
  else
    log "Reality 偷自己将使用内部目标 ${REALITY_TARGET_HOST}:${REALITY_TARGET_PORT}，部署后验证证书与 Nginx"
  fi
  if [[ "$SHADOWTLS_MODE" == "remote" ]]; then
    check_tls13_target "$SHADOWTLS_TARGET_HOST" "$SHADOWTLS_SNI" \
      "ShadowTLS 外部握手目标" "$SHADOWTLS_TARGET_PORT"
  else
    log "ShadowTLS 偷自己将使用内部目标 ${SHADOWTLS_TARGET_HOST}:${SHADOWTLS_TARGET_PORT}，部署后验证证书与 Nginx"
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

if [[ "${INSTALL_SH_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
