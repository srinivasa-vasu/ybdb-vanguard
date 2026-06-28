#!/usr/bin/env bash
# wait-for-svc.sh — wait for one or more services to be ready
# Usage: wait-for-svc.sh URL1 LABEL1 [URL2 LABEL2 ...]
#
# URL forms:
#   http://... or https://...  — poll until curl returns HTTP 2xx/3xx
#   pid:/path/to/file.pid      — wait until the PID file exists and the
#                                process it names is alive
#
# -k on curl accepts self-signed certs (WSO2, Keycloak dev mode, etc.)

_svc_wait() {
  local url="$1" label="$2"
  if [[ "${url}" == pid:* ]]; then
    local pidfile="${url#pid:}"
    until [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}" 2>/dev/null)" 2>/dev/null; do
      printf "\r⏳ waiting for %s..." "${label}"; sleep 2
    done
  else
    until curl -sfk "${url}" >/dev/null 2>&1; do
      printf "\r⏳ waiting for %s..." "${label}"; sleep 3
    done
  fi
  printf "\r✅ %-50s\n" "${label} is ready"
}

while [ $# -ge 2 ]; do
  _svc_wait "$1" "$2"
  shift 2
done
