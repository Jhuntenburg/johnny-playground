#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PORT="${ART_DEBUG_PORT:-8888}"
CDP_PORT="${ART_DEBUG_CDP_PORT:-9222}"
PAGE_PATH="${1:-art.html}"
SERVER_LOG="/tmp/johnny-art-http.log"
BROWSER_LOG="/tmp/johnny-art-browser.log"

pick_browser() {
  if [[ -n "${ART_DEBUG_BROWSER:-}" && -x "${ART_DEBUG_BROWSER}" ]]; then
    echo "${ART_DEBUG_BROWSER}"
    return 0
  fi

  local candidates=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  if command -v electron >/dev/null 2>&1; then
    command -v electron
    return 0
  fi

  return 1
}

wait_for_url() {
  local url="$1"
  local attempts="${2:-50}"
  local delay="${3:-0.2}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay}"
  done

  return 1
}

pick_free_port() {
  local start_port="$1"
  local port

  for ((port = start_port; port < start_port + 25; port++)); do
    if ! lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "${port}"
      return 0
    fi
  done

  return 1
}

if [[ ! -f "${ROOT_DIR}/${PAGE_PATH}" ]]; then
  echo "Missing page: ${ROOT_DIR}/${PAGE_PATH}" >&2
  exit 1
fi

if ! BROWSER_BIN="$(pick_browser)"; then
  echo "Could not find Chrome/Chromium/Electron. Set ART_DEBUG_BROWSER to a browser binary." >&2
  exit 1
fi

if ! APP_PORT="$(pick_free_port "${APP_PORT}")"; then
  echo "Could not find a free app port starting at ${ART_DEBUG_PORT:-8888}." >&2
  exit 1
fi

if ! CDP_PORT="$(pick_free_port "${CDP_PORT}")"; then
  echo "Could not find a free CDP port starting at ${ART_DEBUG_CDP_PORT:-9222}." >&2
  exit 1
fi

APP_URL="http://127.0.0.1:${APP_PORT}/${PAGE_PATH}"
PROFILE_DIR="/tmp/johnny-art-chrome-profile-${CDP_PORT}"

mkdir -p "${PROFILE_DIR}"

nohup python3 -m http.server "${APP_PORT}" --bind 127.0.0.1 --directory "${ROOT_DIR}" >"${SERVER_LOG}" 2>&1 &
SERVER_PID=$!

if ! wait_for_url "http://127.0.0.1:${APP_PORT}/${PAGE_PATH}" 50 0.1; then
  echo "Static server did not come up on ${APP_URL}" >&2
  exit 1
fi

nohup "${BROWSER_BIN}" \
  --remote-debugging-port="${CDP_PORT}" \
  --user-data-dir="${PROFILE_DIR}" \
  --no-first-run \
  --no-default-browser-check \
  "${APP_URL}" >"${BROWSER_LOG}" 2>&1 &
BROWSER_PID=$!

if ! wait_for_url "http://127.0.0.1:${CDP_PORT}/json/version" 80 0.25; then
  echo "Chrome DevTools endpoint did not come up on port ${CDP_PORT}" >&2
  exit 1
fi

PAGE_WS_URL="$(
  APP_URL="${APP_URL}" CDP_PORT="${CDP_PORT}" python3 - <<'PY'
import json
import os
import urllib.request

app_url = os.environ["APP_URL"]
cdp_port = os.environ["CDP_PORT"]

with urllib.request.urlopen(f"http://127.0.0.1:{cdp_port}/json/list", timeout=2) as response:
    pages = json.load(response)

match = None
for page in pages:
    if page.get("url") == app_url:
        match = page
        break

if match:
    print(match.get("webSocketDebuggerUrl", ""))
PY
)"

echo "Art app URL: ${APP_URL}"
echo "HTTP server PID: ${SERVER_PID}"
echo "Browser PID: ${BROWSER_PID}"
echo "Browser binary: ${BROWSER_BIN}"
echo "DevTools version endpoint: http://127.0.0.1:${CDP_PORT}/json/version"
echo "DevTools page list: http://127.0.0.1:${CDP_PORT}/json/list"
if [[ -n "${PAGE_WS_URL}" ]]; then
  echo "Art page CDP websocket: ${PAGE_WS_URL}"
else
  echo "Art page CDP websocket: not found yet; open the page list endpoint above and grab the tab for ${APP_URL}"
fi
echo "Logs: ${SERVER_LOG} and ${BROWSER_LOG}"

if [[ -n "${PAGE_WS_URL}" && -x "${ROOT_DIR}/probe-art-cdp.mjs" ]]; then
  echo "Live page snapshot:"
  if ! ART_DEBUG_WS_URL="${PAGE_WS_URL}" "${ROOT_DIR}/probe-art-cdp.mjs"; then
    echo "Probe could not read the live page yet."
  fi
  echo "Mobile snapshot (390x844 @3x):"
  if ! ART_DEBUG_WS_URL="${PAGE_WS_URL}" ART_DEBUG_WIDTH=390 ART_DEBUG_HEIGHT=844 ART_DEBUG_DPR=3 "${ROOT_DIR}/probe-art-cdp.mjs"; then
    echo "Mobile probe could not read the live page yet."
  fi
  echo "Mobile max-brush snapshot:"
  if ! ART_DEBUG_WS_URL="${PAGE_WS_URL}" ART_DEBUG_WIDTH=390 ART_DEBUG_HEIGHT=844 ART_DEBUG_DPR=3 "${ROOT_DIR}/probe-art-cdp.mjs" '(() => {
    const slider = document.getElementById("size-slider");
    slider.value = "100";
    slider.dispatchEvent(new Event("input", { bubbles: true }));
    const preview = document.getElementById("size-preview");
    const rect = preview.getBoundingClientRect();
    return {
      sliderValue: slider.value,
      previewWidth: rect.width,
      previewHeight: rect.height,
      previewText: document.getElementById("size-label").textContent,
      viewportScale: window.visualViewport ? window.visualViewport.scale : null
    };
  })()'; then
    echo "Mobile max-brush probe could not read the live page yet."
  fi
fi
