#!/bin/sh
set -u

: "${REALITY_CERT_FILE:?missing REALITY_CERT_FILE}"
: "${REALITY_KEY_FILE:?missing REALITY_KEY_FILE}"

while [ ! -s "$REALITY_CERT_FILE" ] || [ ! -s "$REALITY_KEY_FILE" ]; do
  echo "Waiting for Hysteria ACME certificate: ${REALITY_CERT_FILE}"
  sleep 2
done

certificate_signature() {
  cksum "$REALITY_CERT_FILE" "$REALITY_KEY_FILE" | cksum | awk '{ print $1 ":" $2 }'
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
  sleep "${REALITY_CERT_RELOAD_INTERVAL:-3600}" &
  wait $! 2>/dev/null || true
  kill -0 "$nginx_pid" 2>/dev/null || break
  current_signature=$(certificate_signature)
  if [ "$current_signature" != "$last_signature" ]; then
    echo "Reality certificate changed; reloading Nginx"
    if nginx -t && nginx -s reload; then
      last_signature=$current_signature
    fi
  fi
done

wait "$nginx_pid"
