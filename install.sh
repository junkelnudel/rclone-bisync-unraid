#!/bin/bash
# ==============================================================================
# install.sh - links repo files into the Unraid "User Scripts" layout
# ==============================================================================
# Unraid expects each user script at:
#   /boot/config/plugins/user.scripts/scripts/<name>/script
#
# This helper installs:
#   - the library to    .../scripts/_lib/bisync-lib.sh
#   - the master to      .../scripts/bisync-master/script
#   - every job in jobs/ (except the *.example.sh template) to
#     .../scripts/<jobname>/script, where <jobname> is derived from the file
#     name (bisync-<X>.sh -> rclone-bisync-<X>).
#
# Usage:
#   sudo ./install.sh            # copy (default)
#   sudo ./install.sh --symlink  # symlink instead (repo stays the source)
#
# IMPORTANT: before the first run
#   1) Derive and adapt your own job scripts from jobs/bisync-job.example.sh.
#   2) Fill in JOB_SCRIPTS in bin/bisync-master.sh (paths must match the folder
#      names created below).
#   3) Schedule 'bisync-master' via cron in the User Scripts web UI.
# ==============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
US_DIR="${BISYNC_JOBS_DIR:-/boot/config/plugins/user.scripts/scripts}"
LIB_DEST="${US_DIR}/_lib"

MODE="copy"
[[ "${1:-}" == "--symlink" ]] && MODE="symlink"

install_file() {  # <src> <dest>
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ "$MODE" == "symlink" ]]; then
    ln -sf "$src" "$dest"
  else
    cp "$src" "$dest"
  fi
  chmod +x "$dest" 2>/dev/null || true
  echo "  $MODE: $dest"
}

echo "Installing into $US_DIR (mode: $MODE)"

# Library
install_file "${REPO_DIR}/lib/bisync-lib.sh" "${LIB_DEST}/bisync-lib.sh"

# Master
install_file "${REPO_DIR}/bin/bisync-master.sh" "${US_DIR}/bisync-master/script"

# Jobs: all jobs/*.sh except the template *.example.sh
shopt -s nullglob
found_job=0
for job in "${REPO_DIR}"/jobs/*.sh; do
  base="$(basename "$job")"
  [[ "$base" == *.example.sh ]] && continue
  found_job=1
  # bisync-<X>.sh -> rclone-bisync-<X>
  name="${base%.sh}"
  name="${name#bisync-}"
  install_file "$job" "${US_DIR}/rclone-bisync-${name}/script"
done
shopt -u nullglob

if [[ "$found_job" -eq 0 ]]; then
  echo
  echo "NOTE: No custom jobs found in jobs/ (template only)."
  echo "Create your own jobs first:"
  echo "  cp jobs/bisync-job.example.sh jobs/bisync-<yourremote>.sh"
fi

echo
echo "Next steps:"
echo "  1) rclone remotes must exist in the plugin config:"
echo "     /boot/config/plugins/rclone/.rclone.conf"
echo "  2) Fill in JOB_SCRIPTS in bin/bisync-master.sh."
echo "  3) Schedule 'bisync-master' via cron in the User Scripts web UI."
echo "  4) Do NOT schedule jobs individually - the master invokes them."
