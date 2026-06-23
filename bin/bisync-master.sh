#!/bin/bash
# ==============================================================================
# RCLONE BISYNC MASTER RUNNER FOR UNRAID
# ==============================================================================
#
# Central orchestrator for multiple rclone bisync jobs. Typically started via
# cron through the Unraid "User Scripts" plugin; it invokes the actual job
# scripts serially.
#
# Sync model
#   - Multiple jobs are executed one after another (serially).
#   - Between jobs there is a configurable pause to smooth out quota spikes
#     across multiple remotes.
#
# Parallelism protection
#   Global flock on $LOCK_FILE: only one master instance at a time.
#   A new start blocks until the running master finishes.
#
# Error and status model
#   Exit 0 = OK, 7 = RESYNC, 130/143 = controlled abort, otherwise error.
#   Missing job script = MISSING. The master does NOT abort on individual
#   failures; it runs the remaining jobs and writes a summary at the end.
# ==============================================================================

set -euo pipefail

#####################################
# === CONFIGURATION ===
#####################################
# >>> EDIT <<<
# Directory containing the job scripts. On Unraid, each user script lives at
# .../user.scripts/scripts/<name>/script.
JOBS_DIR="${BISYNC_JOBS_DIR:-/boot/config/plugins/user.scripts/scripts}"

# >>> EDIT <<<
# List of jobs to run. Order = execution order.
# One entry per job; the folder name should uniquely identify the remote/job.
# Examples (commented out) - replace with your own jobs:
JOB_SCRIPTS=(
  # "${JOBS_DIR}/rclone-bisync-<YOUR-REMOTE-1>/script"
  # "${JOBS_DIR}/rclone-bisync-<YOUR-REMOTE-2>/script"
)

# Pause between jobs (seconds) to smooth out quota spikes.
INTER_JOB_SLEEP="${BISYNC_INTER_JOB_SLEEP:-120}"

# Root for runtime data (logs/state/work/config). Should match the library.
BASE_DIR="${BISYNC_BASE_DIR:-/mnt/user/appdata/rclone-bisync}"
LOG_DIR="${BASE_DIR}/logs"
LOCK_FILE="/tmp/rclone-bisync-master.lock"

mkdir -p "$LOG_DIR"

#####################################
# === GLOBAL LOCK: exactly one master instance ===
#####################################
exec 9>"$LOCK_FILE" || exit 1
flock 9   # blocking: a new run waits for the active run to finish

#####################################
# === Logging ===
#####################################
MASTER_LOG="${LOG_DIR}/master-$(date +'%F_%H-%M-%S').log"

log()   { echo -e "[$(date +'%F %T')] $*" | tee -a "$MASTER_LOG"; }
ok()    { echo -e "\e[32m$*\e[0m" | tee -a "$MASTER_LOG"; }
warn()  { echo -e "\e[33m$*\e[0m" | tee -a "$MASTER_LOG"; }
error() { echo -e "\e[31m$*\e[0m" | tee -a "$MASTER_LOG"; }

#####################################
# === Job execution ===
#####################################
declare -A RESULT
declare -A RUNTIME

# run_job <path> <name>  ->  sets RESULT[name], RUNTIME[name]; returns child exit
run_job() {
  local script="$1" name="$2" begin end code

  if [[ ! -f "$script" ]]; then
    error "Job script not found: $script"
    RESULT["$name"]="MISSING"
    RUNTIME["$name"]=0
    return 1
  fi

  begin=$(date +%s)
  if bash "$script"; then
    ok "STATUS OK: $name completed successfully."
    RESULT["$name"]="OK"
    code=0
  else
    code=$?
    case "$code" in
      7)        warn "STATUS RESYNC: $name exited with 7; master continues with remaining jobs."
                RESULT["$name"]="RESYNC (7)" ;;
      130|143)  warn "STATUS ABORT: $name controlled exit (exit $code)."
                RESULT["$name"]="ABORT ($code)" ;;
      *)        warn "STATUS ERROR: $name exited with $code; master continues with remaining jobs."
                RESULT["$name"]="ERROR ($code)" ;;
    esac
  fi
  end=$(date +%s)
  RUNTIME["$name"]=$((end - begin))
  return "$code"
}

#####################################
# === Start ===
#####################################
log "==========================================="
log "   RCLONE BISYNC MASTER: START"
log "==========================================="
log "Global lock active: $LOCK_FILE"
log "Master log: $MASTER_LOG"

START_MASTER=$(date +%s)

if [[ "${#JOB_SCRIPTS[@]}" -eq 0 ]]; then
  warn "No jobs configured. Please fill in JOB_SCRIPTS in this script."
  exit 0
fi

#####################################
# === Jobs: always serial ===
#####################################
SCRIPT_COUNT=${#JOB_SCRIPTS[@]}
INDEX=0

for script in "${JOB_SCRIPTS[@]}"; do
  INDEX=$((INDEX + 1))
  NAME=$(basename "$(dirname "$script")")
  log ""
  log "-------------------------------------------"
  log "Job ${INDEX}/${SCRIPT_COUNT} starting: $NAME"
  log "Script path: $script"
  log "-------------------------------------------"

  run_job "$script" "$NAME" || true

  if [[ "$INDEX" -lt "$SCRIPT_COUNT" ]]; then
    log "Inter-job pause: ${INTER_JOB_SLEEP}s until the next job."
    sleep "$INTER_JOB_SLEEP"
  fi
done

END_MASTER=$(date +%s)
MASTER_TIME=$((END_MASTER - START_MASTER))

#####################################
# === Summary ===
#####################################
log ""
log "==========================================="
log "   MASTER RUN SUMMARY"
log "==========================================="
log "Format: job | status | runtime"

print_summary_line() {
  local name="$1"
  printf "%-35s | %-12s | %4ss\n" \
    "$name" "${RESULT[$name]:-UNKNOWN}" "${RUNTIME[$name]:-0}" | tee -a "$MASTER_LOG"
}

for script in "${JOB_SCRIPTS[@]}"; do
  print_summary_line "$(basename "$(dirname "$script")")"
done

log "-------------------------------------------"
log "Total runtime: ${MASTER_TIME}s (~$((MASTER_TIME / 60)) min)"
log "Master log: $MASTER_LOG"
log "==========================================="
log "   RCLONE BISYNC MASTER: END"
log "==========================================="

exit 0
