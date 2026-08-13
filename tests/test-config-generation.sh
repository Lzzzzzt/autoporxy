#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
INSTALL_SH_LIB_ONLY=1 source "${PROJECT_DIR}/install.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

set_common_values() {
  NODE_NAME=TestNode
  HYSTERIA_IMAGE=tobyxdd/hysteria:latest
  XRAY_IMAGE=ghcr.io/xtls/xray-core:latest
  SHADOWTLS_IMAGE=ghcr.io/ihciah/shadow-tls:latest
  NGINX_IMAGE=nginx:latest
  DEBIAN_IMAGE=debian:latest
  SNELL_VERSION=5.0.1
  SNELL_CLIENT_VERSION=5
  SERVER_ADDRESS=203.0.113.10
  HY2_DOMAIN=hy2.example.com
  ACME_EMAIL=
  HY2_PORT=23456
  XRAY_PORT=34567
  SNELL_PORT=45678
  HY2_MASQUERADE_URL=https://www.apple.com/
  HY2_OUTBOUND_MODE=46
  HY2_FAST_OPEN=true
  HY2_CONGESTION=bbr
  HY2_BBR_PROFILE=standard
  HY2_SPEED_TEST=false
  HY2_UDP_IDLE_TIMEOUT=60s
  REALITY_SHOW=false
  REALITY_MAX_TIME_DIFF=0
  REALITY_FINGERPRINT=chrome
  XRAY_DOMAIN_STRATEGY=UseIPv4v6
  XRAY_LOG_LEVEL=warning
  SHADOWTLS_STRICT=true
  SHADOWTLS_FAST_OPEN=true
  SHADOWTLS_STRICT_ENV=1
  SHADOWTLS_FAST_OPEN_ENV=1
  SHADOWTLS_LOG_LEVEL=warn
  SNELL_IPV6=false
  SNELL_TFO=true
  SNELL_DNS=
  SNELL_CLIENT_REUSE=true
  SNELL_CLIENT_TFO=true
  HY2_PASSWORD=test-hy2-password
  SNELL_PSK=test-snell-psk
  SHADOWTLS_PASSWORD=test-shadowtls-password
  VLESS_UUID=11111111-1111-4111-8111-111111111111
  REALITY_PRIVATE_KEY=test-private-key
  REALITY_PUBLIC_KEY=test-public-key
  REALITY_SHORT_ID=0123456789abcdef
  SELF_WEB_PORT=8443
}

configure_modes() {
  local hy2_mode=$1 reality_mode=$2 shadowtls_mode=$3 same_domain=$4
  HY2_MASQUERADE_MODE=$hy2_mode
  REALITY_MODE=$reality_mode
  SHADOWTLS_MODE=$shadowtls_mode
  REALITY_SNI=reality.example.com
  SHADOWTLS_SNI=shadow.example.com
  if [[ "$same_domain" == "true" ]]; then
    REALITY_SNI=$HY2_DOMAIN
    SHADOWTLS_SNI=$HY2_DOMAIN
  fi

  if [[ "$REALITY_MODE" == "self" ]]; then
    REALITY_TARGET_HOST=reality-web
    REALITY_TARGET_PORT=$SELF_WEB_PORT
  else
    REALITY_TARGET_HOST=www.cloudflare.com
    REALITY_TARGET_PORT=443
  fi
  if [[ "$SHADOWTLS_MODE" == "self" ]]; then
    SHADOWTLS_TARGET_HOST=reality-web
    SHADOWTLS_TARGET_PORT=$SELF_WEB_PORT
  else
    SHADOWTLS_TARGET_HOST=www.apple.com
    SHADOWTLS_TARGET_PORT=443
  fi

  SELF_WEB_DOMAINS=
  if self_web_enabled; then
    COMPOSE_PROFILES=self
    [[ "$REALITY_MODE" == "self" ]] && append_self_web_domain "$REALITY_SNI"
    [[ "$SHADOWTLS_MODE" == "self" ]] && append_self_web_domain "$SHADOWTLS_SNI"
  else
    COMPOSE_PROFILES=
  fi
  return 0
}

assert_contains() {
  local file=$1 expected=$2
  grep -Fq -- "$expected" "$file" || {
    printf 'Expected %s to contain: %s\n' "$file" "$expected" >&2
    return 1
  }
}

run_case() {
  local name=$1 hy2_mode=$2 reality_mode=$3 shadowtls_mode=$4 same_domain=$5
  local case_dir="${TEST_ROOT}/${name}" compose_config
  install -d -m 0700 "$case_dir"
  DATA_DIR="${case_dir}/data"
  ENV_FILE="${case_dir}/stack.env"
  CLIENT_FILE="${case_dir}/client-config.txt"

  set_common_values
  configure_modes "$hy2_mode" "$reality_mode" "$shadowtls_mode" "$same_domain"
  write_service_configs
  write_env
  write_client_config

  if [[ "$HY2_MASQUERADE_MODE" == "self" ]]; then
    assert_contains "${DATA_DIR}/hysteria/config.yaml" 'type: file'
    assert_contains "${DATA_DIR}/hysteria/config.yaml" 'dir: /www/masq'
  else
    assert_contains "${DATA_DIR}/hysteria/config.yaml" 'type: proxy'
    assert_contains "${DATA_DIR}/hysteria/config.yaml" 'url: "https://www.apple.com/"'
  fi

  if self_web_enabled; then
    [[ -s "${DATA_DIR}/reality/nginx.conf" ]]
    IFS=',' read -r -a domains <<< "$SELF_WEB_DOMAINS"
    for domain in "${domains[@]}"; do
      assert_contains "${DATA_DIR}/reality/nginx.conf" "server_name ${domain};"
      assert_contains "${DATA_DIR}/hysteria/config.yaml" "$domain"
    done
  else
    [[ ! -e "${DATA_DIR}/reality/nginx.conf" ]]
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    compose_config=$(docker compose --env-file "$ENV_FILE" -f "${PROJECT_DIR}/docker-compose.yml" config)
    if [[ "$SHADOWTLS_MODE" == "self" ]]; then
      [[ "$compose_config" == *"${SHADOWTLS_SNI}:reality-web:8443;reality-web:8443"* ]]
    else
      [[ "$compose_config" == *"${SHADOWTLS_SNI}:www.apple.com:443;www.apple.com:443"* ]]
    fi
  fi

  printf '[OK] %s\n' "$name"
}

run_case all-remote remote remote remote false
run_case hy2-self self remote remote false
run_case reality-self remote self remote false
run_case shadowtls-self remote remote self false
run_case all-self-same-domain self self self true
run_case all-self-distinct-domain self self self false

prompt_value() { printf '%s' "$2"; }
detect_public_ipv4() { printf '%s' '203.0.113.10'; }
ENV_FILE="${TEST_ROOT}/all-self-distinct-domain/stack.env"
collect_settings >/dev/null
[[ "$HY2_MASQUERADE_MODE" == "self" ]]
[[ "$REALITY_MODE" == "self" && "$REALITY_TARGET_HOST" == "reality-web" ]]
[[ "$SHADOWTLS_MODE" == "self" && "$SHADOWTLS_TARGET_HOST" == "reality-web" ]]
[[ "$REALITY_TARGET_PORT" == "8443" && "$SHADOWTLS_TARGET_PORT" == "8443" ]]
[[ "$SELF_WEB_DOMAINS" == "reality.example.com,shadow.example.com" ]]
[[ "$COMPOSE_PROFILES" == "self" ]]
printf '[OK] existing self-mode settings round trip\n'

awk -F= '$1 !~ /^(HY2_MASQUERADE_MODE|SHADOWTLS_MODE|SHADOWTLS_TARGET_HOST|SELF_WEB_PORT|SELF_WEB_DOMAINS)$/' \
  "${TEST_ROOT}/reality-self/stack.env" > "${TEST_ROOT}/legacy.env"
ENV_FILE="${TEST_ROOT}/legacy.env"
collect_settings >/dev/null
[[ "$HY2_MASQUERADE_MODE" == "remote" ]]
[[ "$REALITY_MODE" == "self" && "$REALITY_TARGET_HOST" == "reality-web" ]]
[[ "$SHADOWTLS_MODE" == "remote" && "$SHADOWTLS_TARGET_HOST" == "$SHADOWTLS_SNI" ]]
[[ "$SELF_WEB_PORT" == "8443" && "$SELF_WEB_DOMAINS" == "reality.example.com" ]]
printf '[OK] legacy settings migration\n'
