#!/usr/bin/env bash
# Run one privacy-bounded VoiceInk++ unified-log trace without orphaning log stream.

set -euo pipefail
umask 077

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TRACE_ROOT="${VOICEINK_TRACE_STATE_DIR:-/tmp/voiceink-plus-plus-live-delivery-trace-$(id -u)}"
TRACE_LOG_DIR="${VOICEINK_TRACE_LOG_DIR:-$HOME/Library/Logs/VoiceInkPlusPlus/DeliveryTrace}"
RUNNER_PID_FILE="$TRACE_ROOT/runner.pid"
STREAM_PID_FILE="$TRACE_ROOT/stream.pid"
FIFO_PATH="$TRACE_ROOT/stream.fifo"
LOCK_DIR="$TRACE_ROOT/operation.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"
LAUNCHD_LABEL="com.ethansk.voiceink.live-delivery-trace.$(id -u)"
LAUNCHD_SERVICE="gui/$(id -u)/$LAUNCHD_LABEL"

PREDICATE='process == "VoiceInkPlusPlus" && ((subsystem == "com.ethansk.VoiceInkPlusPlus" && (category == "VIPPDebug" || category == "FocusLock")) || (subsystem == "com.prakashjoshipax.voiceink" && (category == "ShortcutMonitor" || category == "RecordingShortcutManager" || category == "CursorPaster" || category == "StreamingTranscriptionSession" || category == "StreamingTranscriptionService")))'

usage() {
  printf 'usage: %s start|status|stop|show [line-count]\n' "$0" >&2
}

trace_file_for_day() {
  local day="$1"
  printf '%s/trace-%s.log\n' "$TRACE_LOG_DIR" "$day"
}

today_trace_file() {
  trace_file_for_day "$(date +%F)"
}

prepare_trace_log_directory() {
  mkdir -p "$TRACE_LOG_DIR"
  chmod 700 "$TRACE_LOG_DIR"
  # Keep seven rolling days of privacy-bounded metadata. Cleanup runs at start,
  # status/show, and each daily rollover so a long-lived trace also self-cleans.
  find "$TRACE_LOG_DIR" -type f -name 'trace-????-??-??.log' -mmin +10080 -delete
}

ensure_trace_file() {
  local day="$1"
  local file
  file="$(trace_file_for_day "$day")"
  if [ -L "$file" ]; then
    printf 'refusing symlink trace file: %s\n' "$file" >&2
    return 1
  fi
  if [ ! -s "$file" ]; then
    printf '# VoiceInk++ lineage metadata; transcript contents and provider errors are excluded.\n' > "$file"
  fi
  chmod 600 "$file"
  printf '%s\n' "$file"
}

append_trace_line() {
  local line="$1"
  local day="${line%% *}"
  local file
  case "$day" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) day="$(date +%F)" ;;
  esac
  file="$(ensure_trace_file "$day")"
  printf '%s\n' "$line" >> "$file"
}

append_redacted_transcription_failure() {
  local line="$1"
  local before_error="${line%% error=*}"
  local after_error=""
  if [[ "$line" == *' generation='* ]]; then
    after_error=" generation=${line##* generation=}"
  fi
  append_trace_line "${before_error} error=<redacted>${after_error}"
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

launchd_service_exists() {
  launchctl print "$LAUNCHD_SERVICE" >/dev/null 2>&1
}

remove_launchd_service() {
  if launchd_service_exists; then
    launchctl kill SIGTERM "$LAUNCHD_SERVICE" 2>/dev/null || true
    launchctl remove "$LAUNCHD_LABEL" 2>/dev/null || true
  fi
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
  # `nohup` children launched from Codex's bounded command runner are reaped when
  # that runner exits. Keep the trace in one launchd-owned submitted job instead;
  # remove any stale submitted job before creating its replacement.
  remove_launchd_service
  rm -f "$RUNNER_PID_FILE" "$STREAM_PID_FILE" "$FIFO_PATH"
  return 0
}

run_trace() {
  local stream_pid=""
  local active_day="$(date +%F)"

  mkdir -p "$TRACE_ROOT"
  prepare_trace_log_directory
  ensure_trace_file "$active_day" >/dev/null
  atomic_pid_write "$$" "$RUNNER_PID_FILE"
  rm -f "$FIFO_PATH"
  mkfifo "$FIFO_PATH"

  cleanup_runner() {
    if [ -n "$stream_pid" ] && pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
      kill -TERM "$stream_pid" 2>/dev/null || true
      wait "$stream_pid" 2>/dev/null || true
    fi
    rm -f "$STREAM_PID_FILE" "$FIFO_PATH"
    if [ "$(read_pid "$RUNNER_PID_FILE" || true)" = "$$" ]; then
      rm -f "$RUNNER_PID_FILE"
    fi
  }
  trap cleanup_runner EXIT INT TERM HUP

  /usr/bin/log stream --style compact --level debug --predicate "$PREDICATE" > "$FIFO_PATH" 2>&1 &
  stream_pid=$!
  atomic_pid_write "$stream_pid" "$STREAM_PID_FILE"

  # The allowlist retains routing, immutable job lineage, provider timing/counts,
  # and delivery metadata only. Do not broaden it to arbitrary messages: traces
  # must never persist dictated/transcribed text, prompts, or provider error bodies.
  while IFS= read -r line; do
    if [ "${line%% *}" != "$active_day" ] && [[ "${line%% *}" == [0-9][0-9][0-9][0-9]-* ]]; then
      active_day="${line%% *}"
      prepare_trace_log_directory
      ensure_trace_file "$active_day" >/dev/null
    fi
    case "$line" in
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'paste retarget:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline enqueue '*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline enqueue REFUSED'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline queue DISCARD'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline run START'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline run END'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline remove '*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: transcribe START'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: transcribe SUCCESS'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: DELIVERY REFUSED'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: delivery DEFERRED'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: delivery RESUMED'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: about to DELIVER'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: delivery RETURNED'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'paste:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'toggleRecord:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'toggleRecorderPanel:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'record start:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'Next stop:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'shortcut:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'focuslock:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'cancelSession:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'resetRecordingSession:'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'cleanupResources: DEFERRED'*|\
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'deliver: enter'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Captured editable input'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Captured Telegram exact-input identity'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Captured recording-start'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Recording-start main-composer'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Promoted recording-start'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Focused input capture'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Focused input restore'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Restored and verified focused input'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Background exact'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Telegram retained'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Telegram visual identity'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Background internal focus'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Exact-input'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Semantic Send'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'semantic Send'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Bounded OpenAI FooterActions'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Resolved OpenAI FooterActions'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Retained exact submit'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Nearby submit'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Resolved explicitly labelled Send'*|\
      *'[com.ethansk.VoiceInkPlusPlus:FocusLock]'*'Application activation'*|\
      *'[com.prakashjoshipax.voiceink:ShortcutMonitor]'*'Next Track'*|\
      *'[com.prakashjoshipax.voiceink:ShortcutMonitor]'*'Event tap'*|\
      *'[com.prakashjoshipax.voiceink:RecordingShortcutManager]'*'Recording shortcut'*|\
      *'[com.prakashjoshipax.voiceink:RecordingShortcutManager]'*'Next Track'*|\
      *'[com.prakashjoshipax.voiceink:RecordingShortcutManager]'*'Event-tap'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionSession]'*'Streaming session prepare'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionSession]'*'Streaming session connected'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionSession]'*'Streaming finalization started'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionSession]'*'Streaming stop/transcribe started'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionSession]'*'Streaming transcript received'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionSession]'*'Streaming finalized without usable text'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionSession]'*'Using batch fallback for'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionSession]'*'Batch fallback completed'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming start requested'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming connected'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming stop requested'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming drain finished'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming first committed event'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming first partial event'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming final wait finished'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming stop completed'*|\
      *'[com.prakashjoshipax.voiceink:StreamingTranscriptionService]'*'Streaming cancelled'*|\
      *'[com.prakashjoshipax.voiceink:CursorPaster]'*'Cancelled foreground paste'*|\
      *'[com.prakashjoshipax.voiceink:CursorPaster]'*'Cancelled foreground AppleScript paste'*|\
      *'[com.prakashjoshipax.voiceink:CursorPaster]'*'Cancelled foreground CGEvent paste'*|\
      *'[com.prakashjoshipax.voiceink:CursorPaster]'*'Failed to prepare clipboard for paste'*|\
      *'[com.prakashjoshipax.voiceink:CursorPaster]'*'Accessibility permission is required to paste'*|\
      *'[com.prakashjoshipax.voiceink:CursorPaster]'*'Failed to create Cmd+V keyboard events'*|\
      *'[com.prakashjoshipax.voiceink:CursorPaster]'*'Issued humanized foreground CGEvent auto-send'* )
        append_trace_line "$line"
        ;;
      *'[com.ethansk.VoiceInkPlusPlus:VIPPDebug]'*'pipeline: transcribe FAILED'*)
        append_redacted_transcription_failure "$line"
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
  prepare_trace_log_directory
  if ! cleanup_stale_state; then
    runner_pid="$(read_pid "$RUNNER_PID_FILE")"
    printf 'trace already running runnerPid=%s logDir=%s\n' "$runner_pid" "$TRACE_LOG_DIR"
    release_lock
    return 0
  fi

  ensure_trace_file "$(date +%F)" >/dev/null
  # A plain background/nohup process is still a descendant of Codex's bounded
  # command runner and is killed as soon as that tool call closes. Submit one
  # launchd-owned job so `start` really survives into the user's physical test.
  # The runner writes its own PID file before opening the log-stream FIFO.
  launchctl submit -l "$LAUNCHD_LABEL" -- \
    /usr/bin/env "VOICEINK_TRACE_STATE_DIR=$TRACE_ROOT" \
    "VOICEINK_TRACE_LOG_DIR=$TRACE_LOG_DIR" \
    "$SCRIPT_PATH" __run

  for attempt in $(seq 1 60); do
    runner_pid="$(read_pid "$RUNNER_PID_FILE" || true)"
    stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"
    if [ -n "$runner_pid" ] && [ -n "$stream_pid" ] && \
       pid_is_live "$runner_pid" && runner_is_ours "$runner_pid" && \
       pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
      printf 'trace started runnerPid=%s streamPid=%s logDir=%s\n' "$runner_pid" "$stream_pid" "$TRACE_LOG_DIR"
      release_lock
      return 0
    fi
    sleep 0.05
  done

  printf 'trace failed to start cleanly\n' >&2
  [ -z "$runner_pid" ] || terminate_managed_pid "$runner_pid" runner || true
  stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"
  [ -z "$stream_pid" ] || terminate_managed_pid "$stream_pid" stream || true
  remove_launchd_service
  rm -f "$RUNNER_PID_FILE" "$STREAM_PID_FILE" "$FIFO_PATH"
  release_lock
  return 1
}

status_trace() {
  local runner_pid=""
  local stream_pid=""

  prepare_trace_log_directory
  runner_pid="$(read_pid "$RUNNER_PID_FILE" || true)"
  stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"
  if [ -n "$runner_pid" ] && pid_is_live "$runner_pid" && runner_is_ours "$runner_pid" && \
     [ -n "$stream_pid" ] && pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
    printf 'running runnerPid=%s streamPid=%s logDir=%s\n' "$runner_pid" "$stream_pid" "$TRACE_LOG_DIR"
    return 0
  fi
  if [ -n "$stream_pid" ] && pid_is_live "$stream_pid" && stream_is_ours "$stream_pid"; then
    printf 'unhealthy orphanStreamPid=%s logDir=%s (run stop or start to clean it)\n' "$stream_pid" "$TRACE_LOG_DIR" >&2
    return 1
  fi
  if [ -n "$runner_pid" ] && pid_is_live "$runner_pid" && runner_is_ours "$runner_pid"; then
    printf 'unhealthy runnerPid=%s logDir=%s (run stop or start to clean it)\n' "$runner_pid" "$TRACE_LOG_DIR" >&2
    return 1
  fi
  printf 'stopped logDir=%s\n' "$TRACE_LOG_DIR"
}

stop_trace() {
  local runner_pid=""
  local stream_pid=""

  acquire_lock
  runner_pid="$(read_pid "$RUNNER_PID_FILE" || true)"
  stream_pid="$(read_pid "$STREAM_PID_FILE" || true)"

  remove_launchd_service

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
  printf 'trace stopped logDir=%s\n' "$TRACE_LOG_DIR"
  release_lock
}

show_trace() {
  local lines="${1:-200}"
  local files=()
  case "$lines" in
    ''|*[!0-9]*) printf 'line-count must be an integer\n' >&2; exit 2 ;;
  esac
  if [ "$lines" -lt 1 ] || [ "$lines" -gt 5000 ]; then
    printf 'line-count must be between 1 and 5000\n' >&2
    exit 2
  fi
  prepare_trace_log_directory
  shopt -s nullglob
  files=("$TRACE_LOG_DIR"/trace-????-??-??.log)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    printf 'no trace exists in %s\n' "$TRACE_LOG_DIR"
    return 0
  fi
  cat "${files[@]}" | tail -n "$lines"
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
