# Security & risks

## Never commit the rclone config

`rclone.conf` / `.rclone.conf` contain OAuth tokens with full access to your
Google Drive. They are excluded in `.gitignore` – keep it that way. Check before
your first push:

```bash
git status --ignored | grep -i rclone   # should be listed as ignored
```

## Bidirectional sync deletes on both sides

These scripts use:

- `--conflict-resolve newer` + `--conflict-loser delete`: on conflict the newer
  file wins, the older one is **deleted**.
- `--resync-mode newer`: on resync the newer side wins.
- `--max-delete 9999999`: practically **no** ceiling on deletions.

Consequence: an accidental local mass deletion or **clock skew** (wrong system
time) can cause "newer" files to be determined incorrectly and correct data to be
overwritten/deleted – and replicated to the remote.

### Active safety nets

- `--drive-use-trash`: files deleted on the remote land in the Google Drive trash
  (recovery usually possible for 30 days).
- `--resilient` / `--recover`: bisync can recover more cleanly after an abort.
- State marker + controlled auto-resync instead of a blind resync.

### Recommendations

- Keep the **system time in sync via NTP** (clock skew is the main risk with
  `newer` strategies).
- For critical data, consider a **limit**: set `MAX_DELETE` in the job script to a
  plausible value (e.g. `MAX_DELETE=500`). If a run exceeds the limit, rclone
  aborts instead of carrying out a faulty mass deletion.
- For irreplaceable data, run a **separate, versioned backup** (bisync is sync,
  not backup).
- Test once with `--dry-run` before first production use (temporarily add the flag
  in `_build_flags` or run the job manually).

## Use your own Google client ID

The default rclone client ID shares a global quota and quickly leads to rate
limits (429/403). Creating your own OAuth client ID in the Google Cloud Console
and storing it in the rclone config significantly reduces quota errors. The
quota backoff built into the script mitigates the consequences but does not
remove the cause.

## Execution as `nobody`

If the script runs as root, rclone is executed as `nobody:users` – matching the
Unraid share permissions. On local permission errors, the self-heal selectively
sets ownership of individual folders to `nobody:users`. It is applied **only** to
paths beneath `LOCAL_DIR` (filtered via `grep -F "$LOCAL_DIR"`), not system-wide.
