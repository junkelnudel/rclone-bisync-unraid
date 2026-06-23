#!/bin/bash
# ==============================================================================
# RCLONE BISYNC – SHARED LIBRARY
# ==============================================================================
#
# This file contains the complete sync logic that was previously duplicated in
# each child script. Job scripts only define their few own variables
# (LOCAL_DIR, REMOTE_NAME, bandwidth profile, excludes) and call `bisync_main`
# at the end.
#
# Usage in a job script:
# ----------------------
#   #!/bin/bash
#   JOB_NAME="<JOB-NAME>"
#   LOCAL_DIR="/mnt/user/<SHARE>/<FOLDER>"
#   REMOTE_NAME="<REMOTE-NAME>"
#   source "$(dirname "$0")/../lib/bisync-lib.sh"
#   bisync_main
#
# Variables expected from the job script (before `source` OR before bisync_main):
#   JOB_NAME              Required. Short name, e.g. "media-backup".
#   LOCAL_DIR             Required. Local sync path.
#   REMOTE_NAME           Required. rclone remote name without ":".
#
# Optional overrides (otherwise the defaults below apply):
#   BWLIMIT_PROFILE       String for --bwlimit. Empty = no limit.
#   EXTRA_EXCLUDES        Array of additional --exclude patterns (job-specific).
#   BASE_DIR              Root for appdata (default: /mnt/user/appdata/rclone-bisync).
#   RCLONE_BIN            Default: /usr/sbin/rcloneorig
#   PLUGIN_RCLONE_CONFIG  Default: /boot/config/plugins/rclone/.rclone.conf
#   TRANSFERS CHECKERS DRIVE_CHUNK_SIZE RETRIES LOW_LEVEL_RETRIES
#   RETRIES_SLEEP TPSLIMIT TPSLIMIT_BURST   (performance tuning)
#   MAX_DELETE            Default: 9999999 (deliberately high, see README/security)
#
# Exit codes (passed through to the master):
#   0        OK
#   7        resync requested / not auto-resolvable
#   130/143  controlled abort (INT/TERM)
#   other    error
# ==============================================================================

set -euo pipefail
umask 002

# ------------------------------------------------------------------------------
# Defaults (overridable per job script or via ENV).
# The path defaults follow the standard conventions of the Unraid rclone plugin.
# On other systems or with a different setup, set them in the job script.
# ------------------------------------------------------------------------------
: "${BASE_DIR:=/mnt/user/appdata/rclone-bisync}"        # root for logs/state/work/config
: "${RCLONE_BIN:=/usr/sbin/rcloneorig}"                 # rclone binary of the Unraid plugin
: "${PLUGIN_RCLONE_CONFIG:=/boot/config/plugins/rclone/.rclone.conf}"  # source config
: "${TZ:=UTC}"; export TZ                               # timezone for logs/schedules, e.g. Europe/Berlin

: "${TRANSFERS:=4}"
: "${CHECKERS:=6}"
: "${DRIVE_CHUNK_SIZE:=64M}"
: "${RETRIES:=6}"
: "${LOW_LEVEL_RETRIES:=30}"
: "${RETRIES_SLEEP:=60s}"
: "${TPSLIMIT:=8}"
: "${TPSLIMIT_BURST:=4}"
: "${MAX_DELETE:=9999999}"
: "${BWLIMIT_PROFILE:=}"

# ------------------------------------------------------------------------------
# Validation of required variables
# ------------------------------------------------------------------------------
: "${JOB_NAME:?bisync-lib: JOB_NAME is not set}"
: "${LOCAL_DIR:?bisync-lib: LOCAL_DIR is not set}"
: "${REMOTE_NAME:?bisync-lib: REMOTE_NAME is not set}"

REMOTE_PATH="${REMOTE_NAME}:"

# ------------------------------------------------------------------------------
# Derived paths
# ------------------------------------------------------------------------------
LOG_DIR="${BASE_DIR}/logs"
STATE_DIR="${BASE_DIR}/state"
WORK_DIR="${BASE_DIR}/work"
RCLONE_CONFIG_DIR="${BASE_DIR}/config"
RCLONE_CONFIG="${RCLONE_CONFIG_DIR}/rclone.conf"

mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

LOG_FILE="${LOG_DIR}/bisync-${REMOTE_NAME}-$(date +'%F_%H-%M-%S').log"

LOCK_DIR="/var/lock"
mkdir -p "$LOCK_DIR" 2>/dev/null || true
LOCK_FILE="${LOCK_DIR}/rclone-bisync-${REMOTE_NAME}.lock"
PAUSE_FILE="$(dirname "$LOCAL_DIR")/.pause-sync-${REMOTE_NAME}"

STATE_FILE="${STATE_DIR}/${REMOTE_NAME}.resync.ok"
FORBIDDEN_DELETE_FILE="${STATE_DIR}/${REMOTE_NAME}.forbidden-deletes.lst"
MANUAL_EXCLUDES_FILE="${STATE_DIR}/${REMOTE_NAME}.manual-excludes.lst"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log()  { echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"; logger -t rclone-bisync -- "$*" 2>/dev/null || true; }
warn() { log "WARN: $*"; }
fail() { log "ERROR: $*"; exit 1; }

# ------------------------------------------------------------------------------
# Status variables
# ------------------------------------------------------------------------------
PHASE="init"
RC=0
AUTORESYNC_DONE=0
IO_PERMISSION_ERROR=0
LOCAL_PERMISSION_ERROR=0
STRUCTURAL_ERROR=0
SELFHEAL_PERMISSION_RETRY_DONE=0
LAST_RUN_LOG_START_LINE=1
LAST_DECISION_LOG_START_LINE=1
declare -a LAST_SELFHEAL_TARGETS=()

regex_escape() { printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g'; }
LOCAL_DIR_ERE="$(regex_escape "$LOCAL_DIR")"

# ------------------------------------------------------------------------------
# Traps
# ------------------------------------------------------------------------------
cleanup() { flock -u 9 2>/dev/null || true; }
trap cleanup EXIT

on_err() {
  local code=$?
  # While rclone is running / right after, errors are handled by our own
  # logic, not by the global ERR trap.
  if [[ "$PHASE" == "run" || "$PHASE" == "post" ]]; then
    return 0
  fi
  fail "Unexpected script error in phase '$PHASE' (exit $code). Detail log: $LOG_FILE"
}
trap on_err ERR

trap 'warn "Abort signal received (INT/TERM). The sync is shutting down in a controlled manner."; exit 130' INT TERM

# ------------------------------------------------------------------------------
# Evaluate log patterns from a defined start line
# ------------------------------------------------------------------------------
is_missing_prior_listings_since() {
  tail -n +"${1:-1}" "$LOG_FILE" 2>/dev/null | grep -q "cannot find prior Path1 or Path2 listings"
}

is_retryable_without_resync_since() {
  tail -n +"${1:-1}" "$LOG_FILE" 2>/dev/null | grep -q "Error is retryable without --resync"
}

is_quota_error_since() {
  tail -n +"${1:-1}" "$LOG_FILE" 2>/dev/null | grep -Eiq \
    'googleapi: Error 403:.*(rateLimitExceeded|userRateLimitExceeded|sharingRateLimitExceeded|downloadQuotaExceeded|quotaExceeded)|googleapi: Error 429|HTTP error 429|429 Too Many Requests|Too Many Requests|Retry-After|RESOURCE_EXHAUSTED|Quota exceeded|quota metric'
}

is_structural_non_resync_error_since() {
  tail -n +"${1:-1}" "$LOG_FILE" 2>/dev/null | grep -Eiq \
    'Winner cannot be determined|rename failed.*object not found|file not in Google drive root'
}

has_local_permission_error_since() {
  tail -n +"${1:-1}" "$LOG_FILE" 2>/dev/null \
    | grep -Ei 'operation not permitted|permission denied' \
    | grep -F "$LOCAL_DIR" >/dev/null
}

collect_local_permission_targets_since() {
  local start="${1:-1}" path target
  tail -n +"$start" "$LOG_FILE" 2>/dev/null \
    | grep -Ei 'operation not permitted|permission denied' \
    | grep -F "$LOCAL_DIR" \
    | grep -Eio "${LOCAL_DIR_ERE}[^:]*" \
    | sort -u \
    | while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if [[ -d "$path" ]]; then
          target="$path"
        elif [[ -e "$path" ]]; then
          target="$(dirname "$path")"
        elif [[ -d "$(dirname "$path")" ]]; then
          target="$(dirname "$path")"
        else
          continue
        fi
        printf '%s\n' "$target"
      done | sort -u
}

prune_targets_from_forbidden_list() {
  [[ $# -gt 0 ]] || return 0
  [[ -f "$FORBIDDEN_DELETE_FILE" ]] || return 0
  local tmp_targets tmp_out
  tmp_targets="$(mktemp)"; tmp_out="$(mktemp)"
  printf '%s\n' "$@" | sort -u > "$tmp_targets"
  awk 'NR==FNR {drop[$0]=1; next} !($0 in drop)' "$tmp_targets" "$FORBIDDEN_DELETE_FILE" > "$tmp_out" \
    && mv "$tmp_out" "$FORBIDDEN_DELETE_FILE"
  rm -f "$tmp_targets" "$tmp_out"
}

repair_local_permission_targets_since() {
  local start="${1:-1}" failed=0 target
  LAST_SELFHEAL_TARGETS=()
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    LAST_SELFHEAL_TARGETS+=("$target")
  done < <(collect_local_permission_targets_since "$start")

  [[ "${#LAST_SELFHEAL_TARGETS[@]}" -eq 0 ]] && return 1

  if [[ "$EUID" -ne 0 ]]; then
    warn "Local permission error detected, but the script is not running as root. Targeted self-heal is therefore not possible."
    return 1
  fi

  warn "Local permission error detected. Affected folders are selectively set to nobody:users; exactly one retry follows."
  for target in "${LAST_SELFHEAL_TARGETS[@]}"; do
    if [[ ! -d "$target" ]]; then
      warn "SELFHEAL skipped: target folder does not exist: $target"; failed=1; continue
    fi
    log "SELFHEAL: setting ownership to nobody:users for '$target'"
    if ! chown nobody:users "$target" 2>>"$LOG_FILE"; then
      warn "SELFHEAL failed: chown not possible for $target"; failed=1; continue
    fi
    if ! su -s /bin/bash nobody -c "touch -c -m \"$target\"" >/dev/null 2>&1; then
      warn "SELFHEAL verification failed: nobody cannot update $target via touch"; failed=1
    fi
  done

  if [[ "$failed" -eq 0 ]]; then
    prune_targets_from_forbidden_list "${LAST_SELFHEAL_TARGETS[@]}" || true
    return 0
  fi
  return 1
}

update_forbidden_list_from_log_since() {
  local start="${1:-1}"
  IO_PERMISSION_ERROR=0
  local tmp="$STATE_DIR/.forbidden.${REMOTE_NAME}.tmp"
  : > "$tmp" 2>/dev/null || true

  tail -n +"$start" "$LOG_FILE" 2>/dev/null \
    | grep "insufficientFilePermissions" \
    | sed "s/.*ERROR : \(.*\): Couldn't delete.*/\1/" \
    >> "$tmp" || true

  if tail -n +"$start" "$LOG_FILE" 2>/dev/null | grep -q "not deleting directories as there were IO errors"; then
    IO_PERMISSION_ERROR=1
  fi

  if [[ -s "$tmp" ]]; then
    IO_PERMISSION_ERROR=1
    log "Remote/IO problem paths detected. These paths will be added to the future exclude list:"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      log "  EXCLUDE: $line"
    done < "$tmp"

    if [[ -f "$FORBIDDEN_DELETE_FILE" ]]; then
      sort -u "$FORBIDDEN_DELETE_FILE" "$tmp" > "${FORBIDDEN_DELETE_FILE}.new" \
        && mv "${FORBIDDEN_DELETE_FILE}.new" "$FORBIDDEN_DELETE_FILE"
    else
      sort -u "$tmp" > "$FORBIDDEN_DELETE_FILE"
    fi
  fi
  rm -f "$tmp" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Run rclone bisync
# ------------------------------------------------------------------------------
run_bisync_once() {
  local extra_flags=("$@")
  LAST_RUN_LOG_START_LINE=$(( $(wc -l < "$LOG_FILE") + 1 ))
  PHASE="run"
  set +e
  if [[ "$EUID" -eq 0 ]]; then
    log "Starting rclone bisync as user 'nobody'."
    su -s /bin/bash nobody -c "HOME=/tmp USER=nobody LOGNAME=nobody umask 002; $(printf '%q ' "$RCLONE_BIN" bisync "$LOCAL_DIR" "$REMOTE_PATH" "${RCLONE_FLAGS[@]}" "${extra_flags[@]}" "${BWLIMIT_FLAG[@]}")"
    RC=$?
  else
    log "Starting rclone bisync as current user (EUID=$EUID)."
    "$RCLONE_BIN" bisync "$LOCAL_DIR" "$REMOTE_PATH" \
      "${RCLONE_FLAGS[@]}" "${extra_flags[@]}" "${BWLIMIT_FLAG[@]}"
    RC=$?
  fi
  set -e
  PHASE="post"
  log "rclone finished: exit code $RC"
}

run_bisync() {
  local extra_flags=("$@") decision_start
  IO_PERMISSION_ERROR=0; LOCAL_PERMISSION_ERROR=0; STRUCTURAL_ERROR=0

  run_bisync_once "${extra_flags[@]}"
  decision_start="$LAST_RUN_LOG_START_LINE"

  if [[ "$RC" -ne 0 ]] && [[ "$SELFHEAL_PERMISSION_RETRY_DONE" -eq 0 ]] && has_local_permission_error_since "$decision_start"; then
    LOCAL_PERMISSION_ERROR=1
    if repair_local_permission_targets_since "$decision_start"; then
      SELFHEAL_PERMISSION_RETRY_DONE=1; LOCAL_PERMISSION_ERROR=0
      warn "Local ownership repair successful. The same bisync run is restarted once."
      run_bisync_once "${extra_flags[@]}"
      decision_start="$LAST_RUN_LOG_START_LINE"
    else
      warn "Local ownership repair was not possible or incomplete. No further self-heal attempt."
    fi
  fi

  LAST_DECISION_LOG_START_LINE="$decision_start"

  if [[ "$RC" -ne 0 ]]; then
    has_local_permission_error_since "$decision_start" && LOCAL_PERMISSION_ERROR=1
    is_structural_non_resync_error_since "$decision_start" && STRUCTURAL_ERROR=1
    update_forbidden_list_from_log_since "$decision_start"
  fi
}

run_bisync_with_quota_backoff() {
  local attempt=1 max_attempts=3 backoff=120
  SELFHEAL_PERMISSION_RETRY_DONE=0

  while true; do
    run_bisync "$@"
    [[ "$RC" -eq 0 ]] && return 0

    if [[ "$LOCAL_PERMISSION_ERROR" -eq 1 ]]; then
      warn "Local permission error detected. Quota backoff is not applied."; return 0
    fi
    if [[ "$STRUCTURAL_ERROR" -eq 1 ]]; then
      warn "Structural conflict/duplicate error detected. Quota backoff is not applied."; return 0
    fi
    if [[ "$IO_PERMISSION_ERROR" -eq 1 ]]; then
      warn "Remote I/O / 403 error detected. Quota backoff is not applied."; return 0
    fi
    is_quota_error_since "$LAST_DECISION_LOG_START_LINE" || return 0

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      warn "Google Drive quota/rate limit still active after ${attempt}/${max_attempts} attempts. This run ends; the next master run retries."
      return 0
    fi

    local jitter sleep_for
    jitter=$(( RANDOM % 60 + 1 ))
    sleep_for=$(( backoff + jitter ))
    warn "Google Drive quota/rate limit detected. Waiting ${sleep_for}s before retrying (${attempt}/${max_attempts})."
    sleep "$sleep_for"

    attempt=$(( attempt + 1 ))
    backoff=$(( backoff * 2 ))
    [[ "$backoff" -gt 600 ]] && backoff=600
  done
}

auto_resync() {
  AUTORESYNC_DONE=1
  warn "Auto-resync starting: --resync --resync-mode newer. Newer files win."
  run_bisync_with_quota_backoff --resync --resync-mode newer
  case "$RC" in
    0)
      log "Auto-resync completed successfully."
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      if ! echo "ok $(date +'%F %T') AUTORESYNC newer" > "$STATE_FILE" 2>/dev/null; then
        warn "STATE_FILE could not be written after auto-resync: $STATE_FILE"
      else
        log "STATE_FILE updated after auto-resync: $STATE_FILE"
      fi
      ;;
    130|143) warn "Auto-resync aborted in a controlled manner (exit $RC)." ;;
    *)       warn "Auto-resync failed (exit $RC). Check the detail log: $LOG_FILE" ;;
  esac
}

# ------------------------------------------------------------------------------
# Setup phases
# ------------------------------------------------------------------------------
_prepare_logfile() {
  : > "$LOG_FILE" 2>/dev/null || { echo "FATAL: cannot write LOG_FILE: $LOG_FILE" >&2; exit 1; }
  chown nobody:users "$LOG_FILE" 2>/dev/null || true
  chmod 664 "$LOG_FILE" 2>/dev/null || true
  find "$LOG_DIR" -type f -name "bisync-${REMOTE_NAME}-*.log" -mtime +30 -delete 2>/dev/null || true
}

_log_startbanner() {
  log "================================================================"
  log "RCLONE BISYNC START: $JOB_NAME"
  log "================================================================"
  log "Script PID: $$"
  log "Configuration snapshot:"
  log "  JOB_NAME             : $JOB_NAME"
  log "  LOCAL_DIR            : $LOCAL_DIR"
  log "  REMOTE_PATH          : $REMOTE_PATH"
  log "  WORK_DIR             : $WORK_DIR"
  log "  LOG_FILE             : $LOG_FILE"
  log "  RCLONE_BIN           : $RCLONE_BIN"
  log "  RCLONE_CONFIG        : $RCLONE_CONFIG"
  log "  STATE_FILE           : $STATE_FILE"
  log "  FORBIDDEN_LIST       : $FORBIDDEN_DELETE_FILE"
  log "  MANUAL_EXCLUDES_FILE : $MANUAL_EXCLUDES_FILE"
  log "  MAX_DELETE           : $MAX_DELETE"
  log "  EUID                 : $EUID"
}

_check_pause() {
  [[ -f "$PAUSE_FILE" ]] && { log "PAUSE file found: $PAUSE_FILE. This run is skipped entirely."; exit 0; }
  return 0
}

_acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    if ! lsof "$LOCK_FILE" >/dev/null 2>&1; then
      warn "Stale lock detected: $LOCK_FILE. The orphaned lock file is being removed."
      rm -f "$LOCK_FILE" || fail "Stale lock could not be deleted: $LOCK_FILE"
    fi
  fi
  exec 9>"$LOCK_FILE" || fail "Lock file cannot be opened: $LOCK_FILE"
  flock -n 9 || fail "Sync aborted: another $JOB_NAME run is still active. Lock: $LOCK_FILE"
}

_ensure_config() {
  mkdir -p "$RCLONE_CONFIG_DIR" || fail "RCLONE_CONFIG_DIR cannot be created: $RCLONE_CONFIG_DIR"
  if [[ ! -f "$RCLONE_CONFIG" ]]; then
    [[ -r "$PLUGIN_RCLONE_CONFIG" ]] || fail "Plugin config is not readable: $PLUGIN_RCLONE_CONFIG"
    cp "$PLUGIN_RCLONE_CONFIG" "$RCLONE_CONFIG" || fail "Plugin config could not be copied to $RCLONE_CONFIG"
    chmod 644 "$RCLONE_CONFIG" || warn "Permissions on $RCLONE_CONFIG could not be set to 644"
    chown nobody:users "$RCLONE_CONFIG" 2>/dev/null || true
    log "Local rclone config created: $RCLONE_CONFIG (source: plugin config)."
  fi
}

_check_rclone() {
  [[ -x "$RCLONE_BIN" ]] || fail "rcloneorig not found or not executable: $RCLONE_BIN"
  "$RCLONE_BIN" --config "$RCLONE_CONFIG" version >/dev/null 2>&1 \
    || fail "rcloneorig cannot run with the given config: $RCLONE_CONFIG"
  "$RCLONE_BIN" --config "$RCLONE_CONFIG" bisync -h >/dev/null 2>&1 \
    || fail "The installed rclone version does not support 'bisync'. Check the rclone plugin/version."
}

_check_paths() {
  [[ -d "$LOCAL_DIR" ]] || fail "Local sync directory does not exist: $LOCAL_DIR"
  [[ -r "$LOCAL_DIR" && -w "$LOCAL_DIR" ]] || fail "Local sync directory is not readable and writable: $LOCAL_DIR"
  mkdir -p "$WORK_DIR"  || fail "WORK_DIR cannot be created: $WORK_DIR"
  mkdir -p "$STATE_DIR" || fail "STATE_DIR cannot be created: $STATE_DIR"
  "$RCLONE_BIN" --config "$RCLONE_CONFIG" lsf "$REMOTE_NAME:/" --max-depth 1 >/dev/null 2>&1 \
    || fail "Remote '$REMOTE_NAME' is not reachable. Check network, token, and rclone config."
}

_build_flags() {
  # Base filters (apply to all jobs), then job-specific EXTRA_EXCLUDES.
  local filter_flags=(
    --exclude "_QUARANTINE_CONFLICTS/**"
    --exclude "**/*.conflict*"
    --exclude "**/.fuse_hidden*"
    --exclude "**/__pycache__/**"
    --exclude "**/*.pyc"
    # macOS metadata
    --exclude "/.DS_Store*"        --exclude "**/.DS_Store*"
    --exclude "/._*"               --exclude "**/._*"
    --exclude "/.Spotlight-V100/**" --exclude "**/.Spotlight-V100/**"
    --exclude "/.Trashes/**"       --exclude "**/.Trashes/**"
    --exclude "/.fseventsd/**"     --exclude "**/.fseventsd/**"
    # transfer leftovers
    --exclude "*.partial"          --exclude "**/*.partial"
  )
  if [[ -n "${EXTRA_EXCLUDES+x}" ]] && [[ "${#EXTRA_EXCLUDES[@]}" -gt 0 ]]; then
    local pat
    for pat in "${EXTRA_EXCLUDES[@]}"; do filter_flags+=( --exclude "$pat" ); done
  fi

  RCLONE_FLAGS=(
    --config "$RCLONE_CONFIG"
    --fast-list
    --create-empty-src-dirs
    --conflict-resolve newer
    --conflict-loser delete
    --compare size,modtime
    --drive-chunk-size "$DRIVE_CHUNK_SIZE"
    --transfers "$TRANSFERS"
    --checkers "$CHECKERS"
    --tpslimit "$TPSLIMIT"
    --tpslimit-burst "$TPSLIMIT_BURST"
    --retries "$RETRIES"
    --low-level-retries "$LOW_LEVEL_RETRIES"
    --retries-sleep "$RETRIES_SLEEP"
    --log-file "$LOG_FILE"
    --log-level INFO
    --workdir "$WORK_DIR"
    --resilient
    --max-delete "$MAX_DELETE"
    --recover
    --drive-skip-gdocs
    --max-lock 2h
    --track-renames
    --track-renames-strategy hash
    --drive-acknowledge-abuse
    --drive-use-trash
    "${filter_flags[@]}"
  )

  if [[ -f "$FORBIDDEN_DELETE_FILE" ]]; then
    log "Loading exclude list for problematic remote/IO paths: $FORBIDDEN_DELETE_FILE"
    RCLONE_FLAGS+=( --exclude-from "$FORBIDDEN_DELETE_FILE" )
  fi
  if [[ -f "$MANUAL_EXCLUDES_FILE" ]]; then
    log "Loading manual exclude list: $MANUAL_EXCLUDES_FILE"
    RCLONE_FLAGS+=( --exclude-from "$MANUAL_EXCLUDES_FILE" )
  fi

  if [[ -n "$BWLIMIT_PROFILE" ]]; then
    BWLIMIT_FLAG=( --bwlimit "$BWLIMIT_PROFILE" )
    log "Bandwidth profile active: $BWLIMIT_PROFILE"
  else
    BWLIMIT_FLAG=()
    log "No bandwidth limit set."
  fi
}

# ------------------------------------------------------------------------------
# Main flow
# ------------------------------------------------------------------------------
bisync_main() {
  _prepare_logfile
  _log_startbanner
  _check_pause
  _acquire_lock
  _ensure_config
  _check_rclone
  _check_paths
  _build_flags

  # Auto-resync on missing state (first run / inconsistent)
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "No valid bisync state found: $STATE_FILE"
    warn "First run or inconsistent state: a one-time auto-resync with --resync --resync-mode newer."
    auto_resync
    [[ "$RC" -ne 0 ]] && fail "Auto-resync on missing STATE_FILE failed (exit $RC). Manual review required."
  fi

  log "Starting regular rclone bisync run: $JOB_NAME"
  log "  Local : $LOCAL_DIR"
  log "  Remote: $REMOTE_PATH"
  log "  Work  : $WORK_DIR"
  log "  Log   : $LOG_FILE"

  run_bisync_with_quota_backoff

  case "$RC" in
    0)
      log "STATUS OK: bisync completed successfully."
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      echo "ok $(date +'%F %T')" > "$STATE_FILE" 2>/dev/null \
        || warn "STATE_FILE could not be written: $STATE_FILE. Future runs may request another auto-resync."
      ;;
    7)
      warn "STATUS RESYNC: bisync exited with 7."
      if is_missing_prior_listings_since "$LAST_DECISION_LOG_START_LINE"; then
        warn "Bisync reports missing prior listings. A controlled auto-resync is permitted."
        [[ "$AUTORESYNC_DONE" -eq 0 ]] && auto_resync
        exit "$RC"
      fi
      if is_quota_error_since "$LAST_DECISION_LOG_START_LINE"; then
        warn "Google Drive quota/rate limit detected. Auto-resync is deliberately not run."; exit 7
      fi
      if is_retryable_without_resync_since "$LAST_DECISION_LOG_START_LINE"; then
        warn "rclone reports an error retryable without --resync. Auto-resync is deliberately not run."; exit 7
      fi
      if [[ "$STRUCTURAL_ERROR" -eq 1 ]]; then
        warn "Structural conflict/duplicate error detected. Auto-resync is deliberately not run."; exit 7
      fi
      if [[ "$LOCAL_PERMISSION_ERROR" -eq 1 ]]; then
        warn "Local permission error persists. Auto-resync is deliberately not run."; exit 7
      fi
      if [[ "$IO_PERMISSION_ERROR" -eq 1 ]]; then
        warn "Remote I/O / 403 error detected. Auto-resync is deliberately not run."; exit 7
      fi
      if [[ "$AUTORESYNC_DONE" -eq 0 ]]; then
        auto_resync
      else
        warn "Auto-resync was already attempted in this script run. No further auto-resync."
      fi
      ;;
    130|143) warn "STATUS ABORT: bisync aborted in a controlled manner (exit $RC). STATE_FILE remains unchanged." ;;
    *)
      warn "STATUS ERROR: bisync exited with ${RC}. STATE_FILE remains unchanged."
      warn "Check the detail log: $LOG_FILE"
      ;;
  esac

  { echo "----- LOG TAIL: last 80 lines – $JOB_NAME -----"; tail -n 80 "$LOG_FILE" || true; } | tee -a "$LOG_FILE"
  exit "$RC"
}
