#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

[[ -f .env ]] || { printf '尚未部署，请先运行 sudo ./install.sh\n' >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { printf '未找到 docker。\n' >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：./manage.sh <命令>

  status       查看容器、监听端口和 BBR/fq 状态
  logs [服务]  持续查看全部或指定服务日志
  show         显示已生成的客户端配置
  restart      重启全部服务
  stop         停止全部服务
  start        启动全部服务
  update       拉取 .env 中配置的镜像并重新部署
  check        校验 Compose 与 Xray 配置
EOF
}

env_get() {
  local key=$1
  awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' .env
}

case "${1:-}" in
  status)
    docker compose ps
    dns_mode=$(env_get DNS_MODE)
    dns_server=$(env_get DNS_SERVER)
    if [[ "$dns_mode" == "custom" && -n "$dns_server" ]]; then
      printf '\nDNS：custom (%s)\n' "$dns_server"
    else
      printf '\nDNS：system（系统 DNS）\n'
    fi
    printf '\n监听端口：\n'
    ss -lntup 2>/dev/null | grep -E ":(80|$(env_get XRAY_PORT)|$(env_get SNELL_PORT)|$(env_get HY2_PORT))([[:space:]]|$)" || true
    printf '\n内核网络参数：\n'
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_fastopen 2>/dev/null || true
    ;;
  logs)
    if [[ -n "${2:-}" ]]; then
      docker compose logs -f --tail=200 "$2"
    else
      docker compose logs -f --tail=200
    fi
    ;;
  show)
    [[ -f client-config.txt ]] || { printf '缺少 client-config.txt，请重新运行 install.sh。\n' >&2; exit 1; }
    cat client-config.txt
    ;;
  restart)
    docker compose restart
    docker compose ps
    ;;
  stop)
    docker compose stop
    ;;
  start)
    docker compose up -d
    docker compose ps
    ;;
  update)
    docker compose config --quiet
    docker compose pull
    docker compose build --pull snell
    docker compose up -d --remove-orphans
    docker compose ps
    ;;
  check)
    docker compose config --quiet
    docker run --rm -v "${SCRIPT_DIR}/data/xray/config.json:/etc/xray/config.json:ro" "$(env_get XRAY_IMAGE)" run -test -config /etc/xray/config.json
    if [[ "$(env_get REALITY_MODE)" == "self" || "$(env_get SHADOWTLS_MODE)" == "self" ]]; then
      docker compose run --rm --no-deps --entrypoint nginx reality-web -t
    fi
    printf 'Compose、Xray 与启用的内部站点配置校验通过。\n'
    ;;
  -h|--help|help|'') usage ;;
  *) printf '未知命令：%s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac
