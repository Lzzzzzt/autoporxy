#!/bin/sh
set -u

: "${SELF_WEB_DOMAINS:?missing SELF_WEB_DOMAINS}"
: "${SELF_WEB_CERT_BASE:?missing SELF_WEB_CERT_BASE}"

domain_list=$(printf '%s' "$SELF_WEB_DOMAINS" | tr ',' ' ')

certificates_ready() {
  for domain in $domain_list; do
    cert_file="${SELF_WEB_CERT_BASE}/${domain}/${domain}.crt"
    key_file="${SELF_WEB_CERT_BASE}/${domain}/${domain}.key"
    [ -s "$cert_file" ] && [ -s "$key_file" ] || return 1
  done
}

while ! certificates_ready; do
  echo "Waiting for Hysteria ACME certificates: ${SELF_WEB_DOMAINS}"
  sleep 2
done

certificate_signature() {
  {
    for domain in $domain_list; do
      cksum \
        "${SELF_WEB_CERT_BASE}/${domain}/${domain}.crt" \
        "${SELF_WEB_CERT_BASE}/${domain}/${domain}.key"
    done
  } | cksum | awk '{ print $1 ":" $2 }'
}

nginx -t
nginx -g 'daemon off;' &
nginx_pid=$!
last_signature=$(certificate_signature)

terminate() {
  trap - INT TERM
  kill -TERM "$nginx_pid" 2>/dev/null || true
  wait "$nginx_pid" 2>/dev/null || true
  exit 0
}
trap terminate INT TERM

while kill -0 "$nginx_pid" 2>/dev/null; do
  sleep "${SELF_WEB_CERT_RELOAD_INTERVAL:-3600}" &
  wait $! 2>/dev/null || true
  kill -0 "$nginx_pid" 2>/dev/null || break
  current_signature=$(certificate_signature)
  if [ "$current_signature" != "$last_signature" ]; then
    echo "Self-hosted certificate changed; reloading Nginx"
    if nginx -t && nginx -s reload; then
      last_signature=$current_signature
    fi
  fi
done

wait "$nginx_pid"
