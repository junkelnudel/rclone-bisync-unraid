# Architecture

## Components

```
                    ┌─────────────────────┐
   cron             │  bin/bisync-master  │  global flock /tmp/...master.lock
                    └──────────┬──────────┘
                               │ invokes serially (bash <script>)
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                       ▼
 jobs/bisync-<a>.sh    jobs/bisync-<b>.sh        jobs/bisync-<c>.sh
        │                      │                       │
        └──────────┬───────────┴───────────┬───────────┘
                   ▼  source                ▼
              lib/bisync-lib.sh  ── bisync_main() ──► rclone bisync (as nobody)
```

## Master runner (`bin/bisync-master.sh`)

Decides solely on **order, runtime measurement, and the status summary**. Contains
no rclone logic.

- Global **blocking** `flock` on FD 9 → only one master instance.
- **Jobs**: executed serially, with an inter-job pause (except after the last),
  to smooth out quota spikes across multiple remotes.
- Child exit codes are classified (OK / RESYNC 7 / ABORT 130|143 / ERROR). The
  master does not abort on individual failures.
- `run_job()` encapsulates execution and classification in one place.
- The jobs to run are listed in the `JOB_SCRIPTS` array.

## Library (`lib/bisync-lib.sh`)

All the actual sync logic. A job script sets variables and calls `bisync_main`.
Flow of `bisync_main`:

1. `_prepare_logfile` – create log file, set permissions, delete old logs (>30 days).
2. `_log_startbanner` – write a configuration snapshot to the log.
3. `_check_pause` – exit cleanly (exit 0) if a pause file exists.
4. `_acquire_lock` – stale-lock detection via `lsof`, then `flock -n`.
5. `_ensure_config` – copy the plugin config once to `BASE_DIR/config`.
6. `_check_rclone` – verify the binary, config, and `bisync` support.
7. `_check_paths` – local directory, work/state, remote reachability.
8. `_build_flags` – base filters + `EXTRA_EXCLUDES` + performance/bisync flags +
   optional forbidden/manual exclude lists + bandwidth profile.
9. State check → initial auto-resync if needed.
10. `run_bisync_with_quota_backoff` – the regular run.
11. Result analysis (`case "$RC"`).

## Error decision tree (exit 7)

```
exit 7?
├─ "cannot find prior listings"  → auto-resync ALLOWED
├─ quota/429/403 rate limit      → NO resync (exit 7, next run retries)
├─ "retryable without --resync"  → NO resync (exit 7)
├─ structural conflict           → NO resync (exit 7)
├─ local permission error        → NO resync (exit 7)
├─ remote I/O / insufficientFile…→ NO resync (exit 7), path → forbidden list
└─ otherwise                     → auto-resync (once)
```

Classification is based on `grep` over the rclone log lines **from the start line
of the respective run** (`LAST_DECISION_LOG_START_LINE`), so old log lines do not
distort earlier decisions.

> **Google-Drive-specific:** The quota, structural, and I/O detection patterns
> match Google Drive / Google API messages (`userRateLimitExceeded`,
> `file not in Google drive root`, `insufficientFilePermissions`, etc.). Together
> with the `--drive-*` flags in `_build_flags`, this binds the scripts to Drive as
> the backend. For other remotes the flags and regexes must be adapted – see the
> "Other remotes" section in the README.

## State files (`BASE_DIR/state/`)

| File | Meaning |
|---|---|
| `<remote>.resync.ok` | marker of a successful run. If absent → auto-resync. |
| `<remote>.forbidden-deletes.lst` | automatically maintained exclude list (remote I/O). |
| `<remote>.manual-excludes.lst` | optional, manual, permanent. |

## Known fragilities (deliberately accepted)

- **Log parsing**: error classification depends on English rclone messages. An
  rclone update that changes wording/locale can silently break classification.
  The regex patterns in `lib/bisync-lib.sh` then need to be updated.
- **`su` exit code**: in the root path, the exit code of `su` is treated as the
  rclone exit code. A `su`/PAM failure would be misinterpreted (rare in practice).
- **`--max-delete 9999999`**: effectively unlimited, see `SECURITY.md`.
