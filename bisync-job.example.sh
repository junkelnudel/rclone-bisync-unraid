#!/bin/bash
# ==============================================================================
# BISYNC JOB TEMPLATE
# ==============================================================================
# Copy this file and adapt it once per sync pair, e.g.:
#   cp jobs/bisync-job.example.sh jobs/bisync-myremote.sh
#
# All logic lives in lib/bisync-lib.sh. This file only sets the few
# job-specific variables and calls bisync_main at the end.
#
# Required fields are marked with >>> EDIT <<<.
# ==============================================================================

# >>> EDIT <<<  Short name of the job (shown in logs/summary).
JOB_NAME="<JOB-NAME>"

# >>> EDIT <<<  Local sync path on the server.
LOCAL_DIR="/mnt/user/<YOUR-SHARE>/<YOUR-FOLDER>"

# >>> EDIT <<<  Name of the rclone remote (without ":"), as in the rclone config.
REMOTE_NAME="<YOUR-REMOTE-NAME>"

# ------------------------------------------------------------------------------
# OPTIONAL: job-specific excludes (in addition to the library's base filters).
# Empty array = no extra excludes. rclone filter syntax.
# ------------------------------------------------------------------------------
EXTRA_EXCLUDES=(
  # "**/node_modules/**"
  # "**/Cache/**"
)

# ------------------------------------------------------------------------------
# OPTIONAL: bandwidth profile (rclone --bwlimit).
# Leave empty ("") = no limit, always full bandwidth.
#
# Format (schedule):  WEEKDAY-HH:MM,UPLOAD:DOWNLOAD ; WEEKDAY-HH:MM,UPLOAD:DOWNLOAD ; ...
#   - Weekdays: Mon Tue Wed Thu Fri Sat Sun
#   - An entry sets a limit that applies from that point until the next entry
#     changes it. The profile is cyclic over the week.
#   - "off" lifts the limit.
#   - Units: K, M, G per second. A single value limits upload only;
#     "UPLOAD:DOWNLOAD" limits both separately. "8M" = upload only 8M.
#     "2M:15M" = upload 2M, download 15M.
#
# How to build your own profile (example: throttle during office hours):
#   Goal: Mon–Fri from 08:00 to 18:00 throttle to upload 2M / download 15M,
#         no limit outside that window.
#   1) Add a "limit on" entry at 08:00 for each weekday.
#   2) Add an "off" entry at 18:00 for each weekday.
#   3) Adjust days/times to your needs.
#
# Example (leave commented out or adapt):
# BWLIMIT_PROFILE="Mon-08:00,2M:15M;Mon-18:00,off;Tue-08:00,2M:15M;Tue-18:00,off;Wed-08:00,2M:15M;Wed-18:00,off;Thu-08:00,2M:15M;Thu-18:00,off;Fri-08:00,2M:15M;Fri-18:00,off"
#
# For a fixed 24/7 limit (e.g. upload permanently 5M):
# BWLIMIT_PROFILE="5M"
# ------------------------------------------------------------------------------
BWLIMIT_PROFILE=""

# ------------------------------------------------------------------------------
# OPTIONAL: override further library defaults (otherwise the defaults from
# lib/bisync-lib.sh apply). Examples:
# BASE_DIR="/mnt/user/appdata/rclone-bisync"
# RCLONE_BIN="/usr/sbin/rcloneorig"
# PLUGIN_RCLONE_CONFIG="/boot/config/plugins/rclone/.rclone.conf"
# TRANSFERS="4"; CHECKERS="6"; DRIVE_CHUNK_SIZE="64M"
# TPSLIMIT="8"; TPSLIMIT_BURST="4"
# RETRIES="6"; LOW_LEVEL_RETRIES="30"; RETRIES_SLEEP="60s"
# MAX_DELETE="9999999"   # see docs/SECURITY.md – consider a more conservative value
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Load the library and run the job. Usually no need to change this.
# BISYNC_LIB can be set to force a different library path.
# ------------------------------------------------------------------------------
LIB_PATH="${BISYNC_LIB:-/boot/config/plugins/user.scripts/scripts/_lib/bisync-lib.sh}"
# Fallback for testing/running directly from the repo:
[[ -f "$LIB_PATH" ]] || LIB_PATH="$(dirname "$(readlink -f "$0")")/../lib/bisync-lib.sh"

# shellcheck source=../lib/bisync-lib.sh
source "$LIB_PATH"
bisync_main
