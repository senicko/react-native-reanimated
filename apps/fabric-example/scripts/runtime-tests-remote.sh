#!/usr/bin/env bash
# Drive the iOS runtime tests against a REMOTE simulator (argent cloud).
#
# Runs from any OS that has node + the `sim-remote` CLI (authenticated) —
# no Xcode, no xcrun, no macOS required. The app must be a self-contained
# Release* build (see export-runtime-tests-app.js).
#
# The reporting path is unchanged from local runs: runtime-tests-server.js
# listens on this host, and `sim-remote proxy` reverse-tunnels the sim's
# localhost:<port> here, so the app's ws://localhost:8082 dial arrives at
# this machine. The library is selected via launchd env inside the remote
# sim (`sim-remote setenv`), the remote analogue of SIMCTL_CHILD_*.
#
# Usage:
#   runtime-tests-remote.sh pick    [--udid <UUID>]
#   runtime-tests-remote.sh install --udid <UUID> --app-path <path/to/FabricExample.app>
#   runtime-tests-remote.sh run     --udid <UUID> --library <reanimated|worklets|self-tests>
#                                   [--configuration ReleaseRuntimeTests] [--only "<suites>"]
#                                   [--metro-port <port>]
#                                   [--connect-timeout <secs>] [--idle-timeout <secs>]
#
# `pick` prints the UDID of the best remote simulator (an explicit --udid
# passes through; otherwise the first available iPhone, preferring booted);
# `install` boots the sim and uploads the app (once per job);
# `run` executes one library's suites (once per workflow step, like --launch).
#
# Debug* configurations are supported: the app loads its JS from a Metro
# server on THIS host at launch. `run` then starts (or reuses) Metro on
# --metro-port, opens a second reverse tunnel for it, and points the app at
# it via RCT_jsLocation. The reporting port becomes metro-port + 1 — that is
# how Debug apps derive it from their Metro URL.

set -euo pipefail

BUNDLE_ID="org.reactjs.native.example.FabricExample"
WS_PORT=8082
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
METRO_LOG="${TMPDIR:-/tmp}/metro-runtime-tests.log"

die() { echo "[runtime-tests-remote] $*" >&2; exit 1; }
log() { echo "[runtime-tests-remote] $*"; }

command -v sim-remote >/dev/null 2>&1 || die "sim-remote CLI not found on PATH"

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || die "missing subcommand: install | run"
shift

UDID="" APP_PATH="" LIBRARY="" CONFIGURATION="ReleaseRuntimeTests"
ONLY="" CONNECT_TIMEOUT=900 IDLE_TIMEOUT=900 METRO_PORT=8081
while [ $# -gt 0 ]; do
  case "$1" in
    --udid) UDID="${2#remote:}"; shift 2 ;;
    --app-path) APP_PATH="$2"; shift 2 ;;
    --library) LIBRARY="$2"; shift 2 ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --metro-port) METRO_PORT="$2"; shift 2 ;;
    --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

# Reverse tunnel: the sim's localhost:<port> -> this host. `proxy start`
# errors with "tunnel already active" on re-runs — tolerate that (same
# semantics as argent's proxyStart wrapper) so runs can blindly ensure
# their tunnels exist.
ensure_tunnel() {
  local port="$1" out
  log "ensuring reverse tunnel for port $port"
  if ! out=$(sim-remote proxy start "$UDID" "$port" 2>&1); then
    if echo "$out" | grep -qi "already"; then
      log "tunnel already active on port $port"
    else
      echo "$out" >&2
      die "proxy start failed for port $port"
    fi
  fi
}

metro_running() {
  curl -sf "http://127.0.0.1:$METRO_PORT/status" 2>/dev/null \
    | grep -q "packager-status:running"
}

# Start Metro on this host unless one is already serving. Mirrors the local
# runner: --reset-cache because a Metro cache built under a different Bundle
# Mode serves stale module maps. Left running on exit — later `run`
# invocations (and re-runs) reuse it; CI job teardown reaps it.
ensure_metro() {
  if metro_running; then
    log "Metro already running on :$METRO_PORT, reusing it"
    return
  fi
  log "starting Metro on :$METRO_PORT (log: $METRO_LOG)"
  (cd "$PROJECT_ROOT" && nohup yarn start --port "$METRO_PORT" --reset-cache > "$METRO_LOG" 2>&1 &)
  for _ in $(seq 1 90); do
    sleep 2
    if metro_running; then
      log "Metro is ready"
      return
    fi
  done
  die "Metro did not become ready within 180s (see $METRO_LOG)"
}
case "$SUBCOMMAND" in
  install | run)
    [ -n "$UDID" ] || die "--udid is required (bare UUID or remote:<UUID>)"
    ;;
esac

case "$SUBCOMMAND" in
  pick)
    # stdout carries ONLY the udid — logs would pollute $(...) captures.
    if [ -n "$UDID" ]; then
      echo "$UDID"
      exit 0
    fi
    command -v jq >/dev/null 2>&1 || die "pick requires jq"
    PICKED=$(sim-remote simctl list devices --json \
      | jq -r '[.devices[][] | select(.isAvailable != false)
                | select(.name | startswith("iPhone"))]
               | sort_by(.state != "Booted") | .[0].udid // empty')
    [ -n "$PICKED" ] || die "no available remote iPhone simulator found"
    echo "$PICKED"
    ;;

  install)
    [ -n "$APP_PATH" ] || die "install requires --app-path"
    [ -d "$APP_PATH" ] || die "no .app at $APP_PATH (unpack the artifact first)"
    log "booting remote simulator $UDID"
    sim-remote simctl boot "$UDID" || true # tolerate already-booted
    sim-remote simctl bootstatus -b "$UDID"
    log "uploading $APP_PATH to the orchestrator (QUIC)"
    sim-remote simctl uninstall "$UDID" "$BUNDLE_ID" || true
    sim-remote simctl install "$UDID" "$APP_PATH"
    log "install done"
    ;;

  run)
    [ -n "$LIBRARY" ] || die "run requires --library"
    IS_RELEASE=true
    case "$CONFIGURATION" in
      Release*) ;;
      Debug*) IS_RELEASE=false ;;
      *) die "unknown configuration: $CONFIGURATION (expected Debug*|Release*)" ;;
    esac

    if ! $IS_RELEASE; then
      # Debug apps load their JS from Metro at launch and derive their
      # reporting WebSocket port as metro-port + 1 (from the Metro URL).
      WS_PORT=$((METRO_PORT + 1))
      ensure_metro
      ensure_tunnel "$METRO_PORT"
      # Explicitly point the app at this Metro (inside the sim, localhost
      # means the remote Mac — the tunnel makes this address land here).
      sim-remote spawn "$UDID" -- defaults write "$BUNDLE_ID" \
        RCT_jsLocation "localhost:$METRO_PORT"
    fi

    ensure_tunnel "$WS_PORT"

    log "selecting library '$LIBRARY' via launchd env"
    sim-remote setenv "$UDID" RUNTIME_TESTS_LIBRARY "$LIBRARY"

    # Start the results collector BEFORE launching the app so the first dial
    # cannot race the listener. Server mode: no --launch, device is ours.
    SERVER_ARGS=(
      --library "$LIBRARY" --platform ios --configuration "$CONFIGURATION"
      --port "$WS_PORT" --connect-timeout "$CONNECT_TIMEOUT" --idle-timeout "$IDLE_TIMEOUT"
    )
    if [ -n "$ONLY" ]; then
      SERVER_ARGS+=(--only "$ONLY")
    fi
    node "$SCRIPT_DIR/runtime-tests-server.js" "${SERVER_ARGS[@]}" &
    SERVER_PID=$!

    # If the launch itself fails, don't leave the collector hanging for the
    # full connect timeout.
    stop_server() { kill "$SERVER_PID" 2>/dev/null || true; }

    log "launching $BUNDLE_ID (library: $LIBRARY)"
    sim-remote simctl terminate "$UDID" "$BUNDLE_ID" || true
    if ! sim-remote simctl launch "$UDID" "$BUNDLE_ID"; then
      stop_server
      die "sim-remote launch failed"
    fi

    set +e
    wait "$SERVER_PID"
    EXIT_CODE=$?
    set -e
    log "library '$LIBRARY' finished with exit code $EXIT_CODE"
    exit "$EXIT_CODE"
    ;;

  *)
    die "unknown subcommand: $SUBCOMMAND (expected pick | install | run)"
    ;;
esac
