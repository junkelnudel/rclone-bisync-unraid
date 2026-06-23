# rclone-bisync-unraid

Robust, production-hardened `rclone bisync` orchestration for Unraid (the
"User Scripts" plugin), built for **Google Drive** as the remote. A master
runner invokes multiple bidirectional sync jobs serially; all sync logic lives
in a shared library that thin, per-sync-pair job definitions source.

Developed and iteratively hardened against real production incidents
(Google Drive quota/rate limits, local ownership problems under `nobody:users`,
remote I/O errors, missing bisync listings). The error handling deliberately
distinguishes between situations where an automatic resync is safe and those
where it would cause damage.

> **Backend note:** These scripts are Google-Drive-specific, not backend-generic.
> They use `--drive-*` flags and parse Drive-specific API messages (e.g.
> `userRateLimitExceeded`, `insufficientFilePermissions`,
> `file not in Google drive root`). For other remotes, see the
> [Other remotes](#other-remotes) section.

> The scripts are intended as a **template**. Paths, remote names, and schedules
> are placeholders and must be adapted before use. Read
> [`docs/SECURITY.md`](docs/SECURITY.md) before any production use.

## Features

- **Master orchestrator** with a global lock (only one instance at a time),
  serial execution, inter-job pauses to smooth out quota spikes, and a status
  summary at the end.
- **Differentiated exit-7 handling**: auto-resync only when listings are genuinely
  missing; for quota, "retryable-without-resync", structural, local-permission,
  or remote-I/O errors the resync is deliberately suppressed.
- **Quota backoff** with exponential growth + jitter (max. 3 attempts, capped at
  600 s).
- **Self-heal** for local permission errors: affected folders are selectively set
  to `nobody:users`, verified, and the run is retried exactly once.
- **Forbidden list**: remote paths with `insufficientFilePermissions` are
  collected and excluded in future runs; removed again after a successful
  self-heal.
- **Auto-resync** on missing/inconsistent state (first run).
- Runs as `root` and then executes rclone as `nobody`; stale-lock detection;
  per-job pause file; log rotation (30 days); optional bandwidth profile.

## Repository layout

```
rclone-bisync-unraid/
├── bin/
│   └── bisync-master.sh           # orchestrator (run via cron)
├── lib/
│   └── bisync-lib.sh              # all sync logic (sourced by jobs)
├── jobs/
│   └── bisync-job.example.sh      # template – copy & adapt per sync pair
├── docs/
│   ├── ARCHITECTURE.md
│   ├── SECURITY.md
│   └── manual-excludes.example.lst
├── install.sh
├── LICENSE
└── README.md
```

Design principle: all logic lives **once** in `lib/bisync-lib.sh`. A job script
only sets `JOB_NAME`, `LOCAL_DIR`, `REMOTE_NAME`, and optionally a bandwidth
profile/excludes. As a result there is no code duplication across multiple sync
jobs.

## Requirements

- Unraid with the **User Scripts** plugin.
- The **rclone plugin** (provides `rcloneorig` and the plugin config at
  `/boot/config/plugins/rclone/.rclone.conf`).
- At least one configured rclone remote. For Google Drive, your own OAuth client
  ID is strongly recommended due to quota – see `docs/SECURITY.md`.
- `lsof` (for stale-lock detection) and `flock` (present on Unraid).

> Runs outside Unraid too, provided the path defaults in `lib/bisync-lib.sh` or
> the job script are overridden (`BASE_DIR`, `RCLONE_BIN`,
> `PLUGIN_RCLONE_CONFIG`).

## Quick start

```bash
git clone https://github.com/<user>/rclone-bisync-unraid.git
cd rclone-bisync-unraid

# 1) Create one job per sync pair from the template and adapt it:
cp jobs/bisync-job.example.sh jobs/bisync-myremote.sh
$EDITOR jobs/bisync-myremote.sh           # JOB_NAME, LOCAL_DIR, REMOTE_NAME ...

# 2) Register the job(s) in bin/bisync-master.sh -> JOB_SCRIPTS.
$EDITOR bin/bisync-master.sh

# 3) Install into the User Scripts layout:
sudo ./install.sh            # copies
# or: sudo ./install.sh --symlink   (repo stays the source of truth)
```

Then schedule **only** `bisync-master` via cron in the User Scripts web UI. The
jobs are invoked by the master, not scheduled individually.

### Choosing a cron schedule

The master is designed for regular runs. Set the schedule in the User Scripts
web UI, e.g.:

- hourly: `0 * * * *`
- every 30 minutes: `*/30 * * * *`
- daily at 03:00: `0 3 * * *`

The global lock prevents overlapping runs from colliding: a new start blocks
until the previous one finishes.

## Job configuration

Each job (`jobs/bisync-<name>.sh`) sets at least:

| Variable | Required | Meaning |
|---|---|---|
| `JOB_NAME` | yes | short name for logs/summary |
| `LOCAL_DIR` | yes | local sync path |
| `REMOTE_NAME` | yes | rclone remote name (without `:`) |
| `EXTRA_EXCLUDES` | no | array of job-specific exclude patterns |
| `BWLIMIT_PROFILE` | no | `--bwlimit` string, empty = no limit |

The bandwidth profile is documented extensively in the template: format, how to
build your own schedule, plus examples. By default **no** limit is set.

### Overriding library defaults

All settable via environment variable or in the job script (defaults in
`lib/bisync-lib.sh`):

| Variable | Default | Purpose |
|---|---|---|
| `BASE_DIR` | `/mnt/user/appdata/rclone-bisync` | root for logs/state/work/config |
| `RCLONE_BIN` | `/usr/sbin/rcloneorig` | rclone binary |
| `PLUGIN_RCLONE_CONFIG` | `/boot/config/plugins/rclone/.rclone.conf` | source config |
| `TZ` | `UTC` | timezone for logs/schedules |
| `TRANSFERS` / `CHECKERS` | `4` / `6` | parallelism |
| `DRIVE_CHUNK_SIZE` | `64M` | Drive upload chunks |
| `TPSLIMIT` / `TPSLIMIT_BURST` | `8` / `4` | transaction rate |
| `RETRIES` / `LOW_LEVEL_RETRIES` / `RETRIES_SLEEP` | `6` / `30` / `60s` | rclone retries |
| `MAX_DELETE` | `9999999` | delete ceiling (see SECURITY.md) |

## Operation

- **Pause a sync** (one run is skipped): create a pause file at
  `<parent-of-LOCAL_DIR>/.pause-sync-<REMOTE_NAME>`, e.g.
  `touch /mnt/user/<share>/.pause-sync-<remote>`
- **Force a resync**: delete the matching state file, e.g.
  `rm /mnt/user/appdata/rclone-bisync/state/<remote>.resync.ok`
- **Permanent excludes**: create `<REMOTE_NAME>.manual-excludes.lst` in the state
  folder (template in `docs/`).
- **Logs**: `<BASE_DIR>/logs/` (master + per job).

## Important safety notes

These scripts sync **bidirectionally** and delete on both sides.
`--conflict-resolve newer` + `--conflict-loser delete` + a high `--max-delete`
mean: local mass deletions or clock skew can be replicated to the remote.
`--drive-use-trash` is the safety net (deleted remote files land in the Drive
trash). Read [`docs/SECURITY.md`](docs/SECURITY.md) before any production use.

## Other remotes

Out of the box this project works **with Google Drive only**. The Drive binding
sits in three places:

1. **rclone flags** in `lib/bisync-lib.sh`: `--drive-chunk-size`,
   `--drive-skip-gdocs`, `--drive-acknowledge-abuse`, `--drive-use-trash`. On a
   different backend (S3, Dropbox, OneDrive, …) rclone aborts on these flags.
2. **Quota/rate-limit detection** (`is_quota_error_since`): greps for Google API
   strings such as `googleapi: Error 403`, `userRateLimitExceeded`,
   `sharingRateLimitExceeded`, `downloadQuotaExceeded`.
3. **Structural/I/O error detection**: `file not in Google drive root` and
   `insufficientFilePermissions` are Drive-specific.

For a different backend you would remove or replace the `--drive-*` flags with
the backend's equivalents and rewrite the error-classification regexes to match
your backend's API messages. The scaffolding logic (lock, quota backoff,
self-heal, forbidden list, exit-7 decision tree) is independent of this and
reusable. PRs for additional backends are welcome.

## License

GNU General Public License v3.0 – see [LICENSE](LICENSE).
