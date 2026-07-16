#!/usr/bin/env bash
# Run one privacy-bounded VoiceInk++ unified-log trace without orphaning log stream.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TRACE_ROOT="${VOICEINK_TRACE_STATE_DIR:-/tmp/voiceink-plus-plus-live-delivery-trace-$(id -u)}"
RUNNER_PID_FILE="$TRACE_ROOT/runner.pid"
STREAM_PID_FILE="$TRACE_ROOT/stream.pid"
TRACE_FILE="$TRACE_ROOT/trace.log"
FIFO_PATH="$TRACE_ROOT/stream.fifo"
LOCK_DIR="$TRACE_ROOT/operation.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

PREDICATE='process == "VoiceInkPlusPlus" && ((subsystem == "com.ethansk.VoiceInkPlusPlus" && (category == "VIPPDebug" || category == "FocusLock")) || (subsystem == "com.prakashjoshipax.voiceink" && (category == "ShortcutMonitor" || category == "RecordingShortcutManager")))'

usage() {
  printf 'usage: %s start|status|stop|show [line-count]\n' "$0" >&2
}

read_pid() {
  local file="$1"
  local value=""
  if [ -f "$file" ]; then
    IFS= read -r value < "$file" || true
  fi
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$value" ;;
  esac
}

pid_is_live() {
  local pid="$1"
  local state=""
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')"
  [ -n "$state" ] && [ "${state#Z}" = "$state" ]
}

runner_is_ours() {
  local pid="$1"
  local command=""
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in
    *"$SCRIPT_PATH"*"__run"*) return 0 ;;
    *) return 1 ;;
  esac
}

operation_is_ours() {
  local pid="$1"
  local command=""
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in
    *"$SCRIPT_PATH"*'start'*|*"$SCRIPT_PATH"*'stop'*) return 0 ;;
    *) return 1 ;;
  esac
}

stream_is_ours() {
  local pid="$1"
  local command=""
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in
    *"/usr/bin/log stream"*"com.ethansk.VoiceInkPlusPlus"*"ShortcutMonitor"*) return 0 ;;
    *) return 1 ;;
  esac
}

atomic_pid_write() {
  local pid="$1"
  local destination="$2"
  local temporary="$destination.tmp.$$"
  printf '%s\n' "$pid" > "$temporary"
  mv "$temporary" "$destination"
}

acquire_lock() {
  local owner_pid=""
  mkdir -p "$TRACE_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    owner_pid="$(read_pid "$LOCK_PID_FILE" || true)"
    if [ -n "$owner_pid" ] && pid_is_live "$owner_pid" && operation_is_ours "$owner_pid"; then
      printf 'another live-delivery-trace operation is in progress pid=%s\n' "$owner_pid" >&2
      exit 1
    fi
    rm -f "$LOCK_PID_FILE"
    if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
      printf 'could not recover stale live-delivery-trace lock (%s)\n' "$LOCK_DIR" >&2
      exit 1
    fi
  fi
  atomic_pid_write "$$" "$LOCK_PID_FILE"
  trap 'rm -f "$LOCK_PID_FILE"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

release_lock() {
  rm -f "$LOCK_PID_FILE"
  rmdir "$LOCK_DIR" 2>/dev/null || true
  trap - EXIT
}

terminate_managed_pid() {
  local pid="$1"
  local kind="$2"
  local attempt

  if ! pid_is_live "$pid"; then
    return 0
  fi
  if [ "$kind" = "runner" ]; then
    runner_is_ours "$pid" || return 1
  else
    stream_is_ours "$pid" || return 1
  fi

  kill -TERM "$pid" 2>/dev/null || true
  for attempt in $(seq 1 40); do
    pid_is_live "$pid" || return 0
    sleep 0.05
  done
  if { [ "$kind" = "runner" ] && runner_is_ours "$pid"; } || \
     { [ "$kind" = "stream" ] && stream_is_ours "$pid"; }; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

cleanup_stale_state() {
  local runner_pid=""
  local stream_pid=""

  runner_pid="$(read_pid "$RUNNER_PID_FILE" || true)"
  stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"
  if [ -n "$runner_pid" ] && pid_is_live "$runner_pid" && runner_is_ours "$runner_pid" && \
     [ -n "$stream_pid" ] && pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
    return 1
  fi

  if [ -n "$runner_pid" ] && pid_is_live "$runner_pid" && runner_is_ours "$runner_pid"; then
    printf 'removing unhealthy managed trace runner pid=%s\n' "$runner_pid" >&2
    terminate_managed_pid "$runner_pid" runner || true
  fi
  if [ -n "$stream_pid" ] && pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
    printf 'removing orphaned managed log stream pid=%s\n' "$stream_pid" >&2
    terminate_managed_pid "$stream_pid" stream || true
  fi
  rm -f "$RUNNER_PID_FILE" "$STREAM_PID_FILE" "$FIFO_PATH"
  return 0
}

run_trace() {
  local stream_pid=""

  mkdir -p "$TRACE_ROOT"
  rm -f "$FIFO_PATH"
  mkfifo "$FIFO_PATH"

  cleanup_runner() {
    if [ -n "$stream_pid" ] && pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
      kill -TERM "$stream_pid" 2>/dev/null || true
      wait "$stream_pid" 2>/dev/null || true
    fi
    rm -f "$STREAM_PID_FILE" "$FIFO_PATH"
  }
  trap cleanup_runner EXIT INT TERM HUP

  /usr/bin/log stream --style compact --level debug --predicate "$PREDICATE" > "$FIFO_PATH" 2>&1 &
  stream_pid=$!
  atomic_pid_write "$stream_pid" "$STREAM_PID_FILE"

  # The allowlist retains routing and delivery metadata only. Do not broaden it
  # to arbitrary messages: traces must never persist dictated/transcribed text.
  while IFS= read -r line; do
    case "$line" in
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'paste retarget:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: about to DELIVER'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'paste:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'toggleRecord:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'toggleRecorderPanel:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'shortcut:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'focuslock:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'deliver: enter'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Captured editable input'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Focused input capture'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Focused input restore'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Restored and verified focused input'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Background exact'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Telegram retained'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Background internal focus'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Exact-input'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Semantic Send'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Retained exact submit'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Nearby submit'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Resolved explicitly labelled Send'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Application activation'*|\
      *'[com.prakashjoshipax.voiceink:ShortcutMonitor]'*'Next Track'*|\
      *'[com.prakashjoshipax.voiceink:ShortcutMonitor]'*'Event tap'*|\
      *'[com.prakashjoshipax.voiceink:RecordingShortcutManager]'*'Recording shortcut'*|\
      *'[com.prakashjoshipax.voiceink:RecordingShortcutManager]'*'Next Track'*|\
      *'[com.prakashjoshipax.voiceink:RecordingShortcutManager]'*'Event-tap'* )
        printf '%s\n' "$line" >> "$TRACE_FILE"
        ;;
    esac
  done < "$FIFO_PATH"

  wait "$stream_pid" 2>/dev/null || true
}

start_trace() {
  local runner_pid=""
  local stream_pid=""
  local attempt

  acquire_lock
  if ! cleanup_stale_state; then
    runner_pid="$(read_pid "$RUNNER_PID_FILE")"
    printf 'trace already running runnerPid=%s trace=%s\n' "$runner_pid" "$TRACE_FILE"
    release_lock
    return 0
  fi

  : > "$TRACE_FILE"
  printf '# VoiceInk++ delivery metadata trace; transcript contents are intentionally excluded.\n' >> "$TRACE_FILE"
  nohup "$SCRIPT_PATH" __run >/dev/null 2>&1 &
  runner_pid=$!
  atomic_pid_write "$runner_pid" "$RUNNER_PID_FILE"

  for attempt in $(seq 1 60); do
    stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"
    if [ -n "$stream_pid" ] && pid_is_live "$runner_pid" && runner_is_ours "$runner_pid" && \
       pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
      printf 'trace started runnerPid=%s streamPid=%s trace=%s\n' "$runner_pid" "$stream_pid" "$TRACE_FILE"
      release_lock
      return 0
    fi
    sleep 0.05
  done

  printf 'trace failed to start cleanly\n' >&2
  terminate_managed_pid "$runner_pid" runner || true
  stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"
  [ -z "$stream_pid" ] || terminate_managed_pid "$stream_pid" stream || true
  rm -f "$RUNNER_PID_FILE" "$STREAM_PID_FILE" "$FIFO_PATH"
  release_lock
  return 1
}

status_trace() {
  local runner_pid=""
  local stream_pid=""

  runner_pid="$(read_pid "$RUNNER_PID_FILE" || true)"
  stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"
  if [ -n "$runner_pid" ] && pid_is_live "$runner_pid" && runner_is_ours "$runner_pid" && \
     [ -n "$stream_pid" ] && pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
    printf 'running runnerPid=%s streamPid=%s trace=%s\n' "$runner_pid" "$stream_pid" "$TRACE_FILE"
    return 0
  fi
  if [ -n "$stream_pid" ] && pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
    printf 'unhealthy orphanStreamPid=%s trace=%s (run stop or start to clean it)\n' "$stream_pid" "$TRACE_FILE" >&2
    return 1
  fi
  if [ -n "$runner_pid" ] && pid_is_live "$runner_pid" && runner_is_ours "$runner_pid"; then
    printf 'unhealthy runnerPid=%s trace=%s (run stop or start to clean it)\n' "$runner_pid" "$TRACE_FILE" >&2
    return 1
  fi
  printf 'stopped trace=%s\n' "$TRACE_FILE"
}

stop_trace() {
  local runner_pid=""
  local stream_pid=""

  acquire_lock
  runner_pid="$(read_pid "$RUNNER_PID_FILE" || true)"
  stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"

  if [ -n "$runner_pid" ] && pid_is_live "$runner_pid"; then
    if runner_is_ours "$runner_pid"; then
      terminate_managed_pid "$runner_pid" runner || true
    else
      printf 'refusing to kill reused/unrecognized runner pid=%s\n' "$runner_pid" >&2
    fi
  fi
  stream_pid="$(read_pid "$STREAM_PID_FILE" || printf '%s' "$stream_pid")"
  if [ -n "$stream_pid" ] && pid_is_live "$stream_pid"; then
    if stream_is_ours "$stream_pid"; then
      terminate_managed_pid "$stream_pid" stream || true
    else
      printf 'refusing to kill reused/unrecognized stream pid=%s\n' "$stream_pid" >&2
    fi
  fi

  rm -f "$RUNNER_PID_FILE" "$STREAM_PID_FILE" "$FIFO_PATH"
  printf 'trace stopped trace=%s\n' "$TRACE_FILE"
  release_lock
}

show_trace() {
  local lines="${1:-200}"
  case "$lines" in
    ''|*[!0-9]*) printf 'line-count must be an integer\n' >&2; exit 2 ;;
  esac
  if [ "$lines" -lt 1 ] || [ "$lines" -gt 5000 ]; then
    printf 'line-count must be between 1 and 5000\n' >&2
    exit 2
  fi
  if [ ! -f "$TRACE_FILE" ]; then
    printf 'no trace exists at %s\n' "$TRACE_FILE"
    return 0
  fi
  tail -n "$lines" "$TRACE_FILE"
}

COMMAND="${1:-}"
case "$COMMAND" in
  start) [ "$#" -eq 1 ] || { usage; exit 2; }; start_trace ;;
  status) [ "$#" -eq 1 ] || { usage; exit 2; }; status_trace ;;
  stop) [ "$#" -eq 1 ] || { usage; exit 2; }; stop_trace ;;
  show) [ "$#" -le 2 ] || { usage; exit 2; }; show_trace "${2:-200}" ;;
  __run) run_trace ;;
  *) usage; exit 2 ;;
esac
