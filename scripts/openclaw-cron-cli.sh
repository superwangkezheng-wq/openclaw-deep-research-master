#!/bin/zsh

# Shared production adapter for the Node-backed OpenClaw CLI. Launchd provides
# a minimal PATH, so production callers must not rely on /usr/bin/env finding
# Node through the OpenClaw shebang.
OPENCLAW_NODE_BIN="${OPENCLAW_NODE_BIN:-/opt/homebrew/bin/node}"
OPENCLAW_BIN="${OPENCLAW_BIN:-/opt/homebrew/bin/openclaw}"
if [[ -z "${OPENCLAW_SYSTEM_BIN:-}" ]]; then
  OPENCLAW_SYSTEM_BIN="$(whence -p openclaw 2>/dev/null || true)"
fi
OPENCLAW_SYSTEM_BIN="${OPENCLAW_SYSTEM_BIN:-${OPENCLAW_BIN}}"

openclaw_cron_cli() {
  if [[ "${OPENCLAW_NODE_BIN}" != /* || ! -x "${OPENCLAW_NODE_BIN}" ]]; then
    echo "OpenClaw Node runtime must be an absolute executable: ${OPENCLAW_NODE_BIN}" >&2
    return 1
  fi
  if [[ "${OPENCLAW_BIN}" != /* || ! -x "${OPENCLAW_BIN}" ]]; then
    echo "OpenClaw CLI must be an absolute executable: ${OPENCLAW_BIN}" >&2
    return 1
  fi

  env -u OPENCLAW_CRON_JOBS_JSON \
    PATH="${OPENCLAW_NODE_BIN:h}:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "${OPENCLAW_NODE_BIN}" "${OPENCLAW_BIN}" "$@"
}
