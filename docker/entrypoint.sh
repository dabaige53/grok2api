#!/bin/sh
set -eu

umask 077

quality_guard_dir=/var/lib/grok2api-quality-guard
mkdir -p "${quality_guard_dir}"
chown grok2api:grok2api "${quality_guard_dir}"
chmod 0700 "${quality_guard_dir}"

if [ ! -f "${GROK2API_CONFIG_SOURCE}" ]; then
  echo "missing config: ${GROK2API_CONFIG_SOURCE}" >&2
  echo "mount config.yaml to /run/grok2api/config.yaml" >&2
  exit 1
fi

cp "${GROK2API_CONFIG_SOURCE}" /app/config.yaml
chown grok2api:grok2api /app/config.yaml
chmod 0600 /app/config.yaml

su-exec grok2api:grok2api "$@" &
app_pid=$!
guard_pid=""

stop_children() {
  if [ -n "${guard_pid}" ]; then
    kill -TERM "${guard_pid}" 2>/dev/null || true
  fi
  kill -TERM "${app_pid}" 2>/dev/null || true
}

wait_for_children() {
  stop_children
  if [ -n "${guard_pid}" ]; then
    wait "${guard_pid}" 2>/dev/null || true
  fi
  wait "${app_pid}" 2>/dev/null || true
}

trap 'wait_for_children; exit 0' INT TERM

# Render runs this project as one Docker service rather than a Compose stack.
# Start the optional guard beside the API only when the API has produced an
# enabled bootstrap file; both processes use the same private state directory.
(
  bootstrap="${quality_guard_dir}/bootstrap.json"
  while kill -0 "${app_pid}" 2>/dev/null; do
    if [ -s "${bootstrap}" ]; then
      if grep -q '"enabled":true' "${bootstrap}"; then
        exec su-exec grok2api:grok2api env \
          GROK2API_QUALITY_GUARD_BASE_URL=http://127.0.0.1:8000 \
          /usr/local/bin/grok2api-egress-quality-guard
      fi
      exit 0
    fi
    sleep 1
  done
  exit 0
) &
guard_pid=$!

set +e
wait "${app_pid}"
app_status=$?
set -e
if [ -n "${guard_pid}" ]; then
  kill -TERM "${guard_pid}" 2>/dev/null || true
  wait "${guard_pid}" 2>/dev/null || true
fi
exit "${app_status}"
