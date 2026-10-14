# rclone-backup.sh

Scheduled, versioned backups from an Unraid server to one or more rclone remotes, each on its own interval, with a 30-day "recycle bin" for deleted files, bandwidth schedules, safety checks for the things that go wrong on a home server, and Gotify notifications that only speak when there is something to say.

Three files:

| File | Purpose |
| --- | --- |
| `rclone-backup.sh` | The backup script. All settings are in one clearly marked block at the top. |
| `test-rclone-backup.sh` | A self-test (static checks, unit tests and sandbox integration tests) that runs safely on the production server. |
| `QA-TEST-PLAN.md` | 139 hand-run test cases, with inputs and expected outputs, for validating the script on your real server, remotes, mounts and notifications. Ends with a traceability map to the automated checks. |
| `TEST-RESULTS.md` | Report from the last automated run: every check, its expected outcome and its result. |

---

## The problem this solves

Backing up with `rclone copy` every hour is easy. Deciding what happens when you **delete** a file at home is not:

- For some folders, nothing should ever disappear from the backup. Delete a document by accident and the remote must still have it.
- For other folders, the deletion should carry over, otherwise the remote fills with junk. But "carry over" must not mean "gone": the file should be moved into an archive, in the same folder structure, kept for 30 days, then removed for good. And you should be told when that happens.

Around that core sit the practical hazards of a home server:

- The script runs hourly, so a slow run can still be going when the next one starts.
- The remote is also **mounted** on the server. When that mount drops, the mount folder is just an empty directory on a drive; anything copied there "looks" backed up but never reaches the remote.
- The Unraid **array** can be stopped, or a disk or pool can drop out, which makes files vanish from the server's view. A naive sync would treat them as deleted.
- A second, slower remote (over SFTP, with a connection limit) is a backup of the backup and should run on its own schedule without fighting the first one for the lock or the bandwidth.
- Notifications must be useful: one message per problem, a "recovered" message when it clears, and silence for routine uploads.

### The setup it was written for

- Unraid server; watch folders are user shares on the array (`/mnt/user/...`).
- Primary remote: an rclone **crypt** remote (`secret:`), mounted on a cache SSD at `/mnt/cache/remoteshare`. Backed up **hourly**.
- Second remote: a crypt remote over **SFTP** (`secret2:`), mounted at `/mnt/cache/remoteshare2`. Backed up **every 12 hours** as a backup of the backup.
- Gotify running in a Docker container on the same server for push notifications.

The script is not limited to that: one remote, two, or more all use the same configuration shape.

---

## What the script does

Every hour (you schedule it once), the script:

1. Refuses to run at all if the Unraid array isn't started. Takes a lock so two runs can never overlap.
2. Validates the whole configuration. A mistake in one remote's block skips only that remote, with an alert that says how to fix it.
3. For each remote **in order**, if that remote is due (its `RUN_EVERY_HOURS` has passed since its last successful backup):
   - checks a canary file on the remote (proves the remote is reachable and is the right one);
   - checks the remote's mount is live, down, hung or pointing somewhere wrong;
   - for every job, uploads new files and moves a modified file's previous version to `_archive/<timestamp>/...`;
   - for **sync** jobs, moves files deleted locally to `_archive/deleted/<destination>/<same folders>/name_DELETED_<date>_<time>.ext`;
   - once a day, permanently deletes archived files older than the retention period and sends a 3/2/1-day countdown for the ones due next;
   - sends one Gotify summary for that remote if anything went wrong, a "Files archived" message if anything was archived, and otherwise stays silent.
4. Reports server-wide problems (array, pools, log size, stuck run) once, without a remote name.

Deletions are **paused**, never skipped silently, while the mount is down, the array is degraded, or a pool is missing. They are caught up on the next run where things are healthy.

---

## Requirements

- Unraid (6.9 or newer for pool detection) with the rclone plugin. For other Linux systems see [Adapting it](#adapting-it-to-your-setup).
- rclone, tested with 1.75. Any reasonably recent version works; 1.63 or newer is recommended so partial-upload file names match what the cleanup expects.
- Standard tools present on Unraid: `bash` 4+, `flock`, `timeout`, `mountpoint`, `curl`, `awk`, `sed`, `realpath`, `logger`.
- Each remote must support server-side **move** (crypt over SFTP, local, S3, B2, Drive, etc. all do). Server-side copy is not needed.
- Optional: a Gotify server for notifications. ShellCheck for the self-test's lint step.

---

## Quick start

1. Copy `rclone-backup.sh` somewhere on the array, e.g. `/mnt/user/appdata/rclone/scripts/`, or add it as a User Script.
2. Create the canary file on **every** remote:
   ```
   rclone --config /boot/config/plugins/rclone/.rclone.conf touch secret:.backup-canary
   ```
3. Edit the block between `CONFIG START` and `CONFIG END` (see [Configuration](#configuration)).
4. Check it:
   ```
   bash rclone-backup.sh --check-config
   ```
   This prints every remote, its jobs, when it is next due, the bandwidth timetable rclone will receive, and any problem. It changes nothing.
5. Try it with `DRY_RUN="true"` first. Nothing is uploaded, moved or deleted; the log and Gotify show what would happen.
6. Set `DRY_RUN="false"` and schedule it **hourly** in the User Scripts plugin (custom schedule `0 * * * *`). Each remote then runs on its own interval from those hourly runs.

Manual runs:

```
bash rclone-backup.sh                 # what the schedule runs: every remote that is due
bash rclone-backup.sh --force         # every remote now, ignoring intervals
bash rclone-backup.sh --only offsite  # one remote now
bash rclone-backup.sh --check-config  # validate and show the plan; changes nothing
```

Exit codes: 0 = all good (or run skipped because another was in progress), 1 = at least one problem, 2 = bad command-line option.

---

## Configuration

Everything you edit is between `CONFIG START` and `CONFIG END`, in four numbered sections. The config is bash, so quotes and brackets matter. After every edit, run `--check-config`.

### 1. REMOTES — which remotes exist, in the order they run

```bash
REMOTES=("primary" "offsite")
```

Each name needs a matching `remote_<name>` block in section 4. Names use letters, digits and underscores and start with a letter. Remotes run one after another, never at the same time. To pause a remote, remove its name from the list; its block can stay.

### 2. Global settings — shared by every remote

| Setting | Default | Meaning |
| --- | --- | --- |
| `RCLONE_CONF` | `/boot/config/plugins/rclone/.rclone.conf` | rclone config file. |
| `LOG_FILE` | `/mnt/user/appdata/rclone/logs/backup.log` | One log for all remotes. State files live in a `state` folder next to it. |
| `LOCK_FILE` | `/var/run/rclone-backup.lock` | Stops two runs overlapping. Released automatically, even if a run is killed. |
| `DRY_RUN` | `"false"` | `"true"` shows what would happen without changing anything. |
| `ARRAY_CHECK` | `"true"` | Unraid array checks (below). Set `"false"` on non-Unraid systems. |
| `UNRAID_VAR_INI` | `/var/local/emhttp/var.ini` | Where Unraid reports array state. |
| `UNRAID_POOLS_DIR` | `/boot/config/pools` | Pool names (e.g. `cache`) are read from `<name>.cfg` here. |
| `CHECK_TIMEOUT` | `60` | Seconds before a hung remote or mount check counts as failed. |
| `STUCK_RUN_HOURS` | `3` | Alert when a single run has been going this long. |
| `LOG_WARN_SIZE_MB` | `1024` | Alert when the log reaches this size (0 = off). |
| `CLEANUP_INTERVAL_HOURS` | `24` | How often each remote's purge check runs. |
| `DUE_GRACE_MINUTES` | `10` | A remote counts as due this many minutes early, so hourly runs that start a few seconds apart never miss a slot. |
| `GOTIFY_ENABLED` | `"true"` | Turn notifications on or off. |
| `GOTIFY_URL` | `http://127.0.0.1:8070` | Gotify address. |
| `GOTIFY_TOKEN` | placeholder | Gotify → Apps → Create Application → copy the token. |
| `GOTIFY_NOTIFY_SUCCESS` | `"false"` | `"true"` also sends a message when a remote has no problems. |
| `GOTIFY_REPEAT_HOURS` | `6` | Don't resend the same alert within this many hours (0 = always). Growing counts such as "hung for 3 runs" are ignored when comparing. |
| `GOTIFY_MAX_RCLONE_LINES` | `10` | rclone ERROR lines included in a message. |
| `GOTIFY_MAX_ARCHIVED_LINES` | `10` | File names listed in a "Files archived" message. |

### 3. Defaults — apply to every remote unless a remote's block sets them again

```bash
defaults() {
    VERSIONING="true"           # keep a modified file's old version in _archive/<timestamp>/
    SKIP_EXISTING="false"       # only if VERSIONING="false": never overwrite remote files
    ARCHIVE_DIR="_archive"      # archive folder at the root of each remote
    DELETED_SUBDIR="deleted"    # sync jobs: deleted files go to _archive/deleted/...
    DELETED_RETENTION_DAYS=30   # purge archived deleted files after this many days (0 = never)
    PURGE_WARNING_DAYS=3        # countdown message for files due within this many days (0 = off)
    MAX_DELETES_PER_JOB=500     # safety: stop after archiving this many deletions in one job (0 = no limit)
    CANARY_FILE=".backup-canary"
    MOUNT_CHECK="true"          # check each remote's mount; a block can set "false" for itself
    PAUSE_SYNC_DELETES_IF_UNMOUNTED="true"
    BANDWIDTH_LIMIT="off"       # a block can set "on" to limit just that remote
    BANDWIDTH_SCHEDULE=()       # a schedule set here is shared by every remote that turns the limit on
    RCLONE_EXTRA_FLAGS=()       # e.g. ("--transfers" "3" "--checkers" "6")
}
```

Any of these can be repeated inside a remote's block to change it for that remote only. Everything not repeated uses the default.

### 4. One block per remote

```bash
remote_primary() {
    REMOTE="secret:"                    # rclone remote, ending in ":" (or a folder ending in "/")
    RUN_EVERY_HOURS=1                   # 1 = every hourly run, 6, 12, 24 ...
    MOUNT_POINT="/mnt/cache/remoteshare" # exactly the path your rclone mount command uses
    MOUNT_CHECK="true"                  # this remote only; overrides the default
    JOBS=(
        "/mnt/user/documents|documents|copy"
        "/mnt/user/photos|photos|sync"
        "/mnt/user/projects|work/projects|copy"
    )
    BANDWIDTH_LIMIT="on"
    BANDWIDTH_SCHEDULE=(
        "Weekdays  06:00  20"           # 20 Mbps during the working day
        "Weekdays  20:00  unlimited"
        "Weekends  00:00  unlimited"
    )
}
```

| Setting | Meaning |
| --- | --- |
| `REMOTE` | Where to back up to. Must end in `:` or `/`, e.g. `secret:` or `secret:backups/`. |
| `RUN_EVERY_HOURS` | Whole hours between backups, counted from the last **successful** backup. A failed backup is retried on the next hourly run. |
| `MOUNT_POINT` | Where this remote is mounted on this server. Use the real mount path (`/mnt/cache/...`), not its `/mnt/user/...` alias. Use `""` if it isn't mounted anywhere. |
| `MOUNT_CHECK` | `"true"` or `"false"` for this remote. With `"false"` there are no mount warnings and deletions are never paused for the mount. Keep `MOUNT_POINT` filled in anyway so no job can be pointed at the mount. If `MOUNT_POINT` is empty, `MOUNT_CHECK` must be `"false"`. |
| `JOBS` | One line per folder: `"local folder\|destination\|mode"`. Destination is the folder on the remote. |
| `BANDWIDTH_LIMIT` / `BANDWIDTH_SCHEDULE` | See below. |
| `RCLONE_EXTRA_FLAGS` | Extra options for the upload and deletion steps, e.g. `("--transfers" "3" "--checkers" "6" "--fast-list")`. Options that change what is archived or deleted (`--max-delete`, `--delete-*`, `--backup-dir`, `--suffix*`, `--inplace`, `--dry-run`, `--files-from*`, `--ignore-existing`, `--immutable`, `--partial-suffix`) are refused. |

**Job modes**

| Mode | New file | Modified file | Deleted locally |
| --- | --- | --- | --- |
| `copy` | uploaded | old version moved to `_archive/<timestamp>/<destination>/...`, new one uploaded | nothing happens; the remote copy stays forever |
| `sync` | uploaded | same as copy | remote copy moved to `_archive/deleted/<destination>/<same folders>/name_DELETED_<date>_<time>.ext`, purged after `DELETED_RETENTION_DAYS` |

**Rules checked before every run** (a remote that breaks one is skipped, with an alert saying how to fix it):

- Each destination is its own folder. No two jobs on the same remote may share a destination, and none may sit inside another (`photos` and `photos/2024` would make a sync job archive the other job's files every run).
- No source folder may be inside, or contain, **any** remote's `MOUNT_POINT`. The check understands Unraid's path aliases, so `/mnt/user/remoteshare/x` is recognised as being inside a mount at `/mnt/cache/remoteshare`.

### Bandwidth schedule

```bash
BANDWIDTH_LIMIT="on"
BANDWIDTH_SCHEDULE=(
    "Mon-Fri  06:00  20"          # days   start  speed in Mbps
    "Mon-Fri  18:00  2.5"
    "Mon-Fri  23:00  unlimited"
    "Sat-Sun  00:00  unlimited"
)
```

- **days**: `Daily`, `Weekdays`, `Weekends`, a single day (`Mon`), a range (`Mon-Fri`, or `Fri-Mon` wrapping the weekend), or a list (`Mon,Wed,Fri`).
- **time**: 24-hour `HH:MM` when the speed starts.
- **speed**: megabits per second (`20`, `2.5`) or `unlimited`.
- A speed stays in force until the next change, overnight and into the next day if needed. You can have as many changes per day as you like.
- `--check-config` shows the exact `--bwlimit` timetable rclone receives (Mbps converted to KiB/s). rclone switches speed partway through a transfer when a change time arrives.

A fixed limit all the time is one line: `BANDWIDTH_SCHEDULE=( "Daily  00:00  40" )`.

### Example configurations

One remote, no mount, nightly:

```bash
REMOTES=("nas")
defaults() { ...; MOUNT_CHECK="false"; ... }
remote_nas() {
    REMOTE="nascrypt:"
    RUN_EVERY_HOURS=24
    MOUNT_POINT=""
    JOBS=( "/mnt/user/photos|photos|sync" "/mnt/user/documents|documents|copy" )
}
```

Two remotes, hourly and twice a day, the second rate-limited (the shipped example):

```bash
REMOTES=("primary" "offsite")
remote_primary() { REMOTE="secret:";  RUN_EVERY_HOURS=1;  MOUNT_POINT="/mnt/cache/remoteshare";  MOUNT_CHECK="true";  JOBS=( ... ); }
remote_offsite() { REMOTE="secret2:"; RUN_EVERY_HOURS=12; MOUNT_POINT="/mnt/cache/remoteshare2"; MOUNT_CHECK="false"; JOBS=( ... ); BANDWIDTH_LIMIT="on"; BANDWIDTH_SCHEDULE=( "Daily 06:00 10" "Daily 20:00 50" ); }
```

Three remotes sharing one schedule from `defaults()`, the third with its own:

```bash
REMOTES=("primary" "offsite" "archive")
defaults() { ...; BANDWIDTH_SCHEDULE=( "Weekdays 06:00 20" "Weekdays 22:00 unlimited" "Weekends 00:00 unlimited" ); }
remote_primary() { REMOTE="secret:";  RUN_EVERY_HOURS=1;  ... }                                   # unlimited (default off)
remote_offsite() { REMOTE="secret2:"; RUN_EVERY_HOURS=6;  ...; BANDWIDTH_LIMIT="on"; }            # uses the shared schedule
remote_archive() { REMOTE="secret3:"; RUN_EVERY_HOURS=24; ...; BANDWIDTH_LIMIT="on"; BANDWIDTH_SCHEDULE=( "Daily 02:00 5" "Daily 05:00 unlimited" ); }
```

---

## How it behaves

### Archive layout on each remote

```
secret:
├── .backup-canary
├── documents/                         ← copy job destination
├── photos/                            ← sync job destination
└── _archive/
    ├── 2026-10-07_140512/             ← one folder per run that replaced files (versions)
    │   └── photos/2024/img.jpg        ← the previous version
    └── deleted/
        └── photos/2024/img_DELETED_2026-10-09_091500.jpg   ← deleted locally, purged after 30 days
```

Version folders are never purged. Only files under `_archive/deleted` whose name carries a `_DELETED_` stamp older than `DELETED_RETENTION_DAYS` are removed, at most once every `CLEANUP_INTERVAL_HOURS`, per remote.

### Restoring a file

Copy it back into its local watch folder under its original name; the next run uploads it again:

```
rclone copyto "secret:_archive/deleted/photos/2024/img_DELETED_2026-10-09_091500.jpg" /mnt/user/photos/2024/img.jpg
```

Don't copy it back into the remote's destination folder directly: a sync job would see it as a file that doesn't exist locally and archive it again.

### Safety checks and what they do

| Check | When it fails |
| --- | --- |
| Array started (`mdState` in `var.ini`) and `/mnt/user` mounted | Nothing runs. One alert, repeated at most every `GOTIFY_REPEAT_HOURS`. |
| Array degraded (missing / disabled / invalid / unmountable disks) or a pool not mounted | Uploads continue; **no remote archives deletions** until it is fixed. One server-wide warning. |
| Configuration | A broken `REMOTES` list stops the run. A problem in one remote's block skips that remote only. |
| Canary readable through rclone | That remote is skipped; nothing on it is touched. |
| Mount listed in the mount table and canary visible through it | Warnings; that remote's deletions are paused if `PAUSE_SYNC_DELETES_IF_UNMOUNTED` is true. A hung (frozen) mount is detected without the script hanging, and counted across runs. Files found in the unmounted folder are reported as stranded. |
| Empty watch folder on a sync job | Deletion step skipped (an unmounted share would otherwise look like a mass deletion). |
| `MAX_DELETES_PER_JOB` | rclone stops archiving at the limit and the job is reported as failed; the rest is archived on later runs once you have confirmed it is intended. |
| Upload errors | That job's deletion step is skipped; rclone itself refuses to delete anything after errors. |
| Interrupted uploads | rclone never writes a partial upload over the real file name. Leftover `name.<8 hex>.partial` files older than an hour are deleted (not archived) in sync jobs. |
| Previous run still going | New run exits quietly. After `STUCK_RUN_HOURS` an alert names the PID and how to check it. |

### Notifications

| Message | Priority | When |
| --- | --- | --- |
| `Backup FAILED on <host> (<remote>)` | 8 | Any error on that remote, with rclone's own error lines. |
| `Backup warnings on <host> (<remote>)` | 5 | Mount down/hung, stranded files, etc. |
| `Backup recovered on <host> (<remote>)` | 4 | First clean run after an alert. |
| `Files archived on <host> (<remote>)` | 4 | Deleted files were moved to the archive: count, paths, purge date. |
| `Archived files due for deletion on <host> (<remote>)` | 5 | Daily 3/2/1-day countdown and what was purged. |
| `Backup OK on <host> (<remote>)` | 2 | Only if `GOTIFY_NOTIFY_SUCCESS="true"`. |
| `Backup NOT run on <host> - array not available` | 8 | Array stopped (see caveats). |
| `Backup stuck on <host>` | 8 | A run has exceeded `STUCK_RUN_HOURS`. |
| `Backup warnings on <host>` (no remote name) | 5 | Server-wide: array degraded, pool missing, log size. |

New uploads and version moves never send anything.

### State files

Kept in `<log folder>/state/`. Deleting the folder is safe: every remote becomes due and alert history starts fresh.

| File | Purpose |
| --- | --- |
| `<remote>.last-success` | When the remote last completed; drives `RUN_EVERY_HOURS`. |
| `<remote>.last-deleted-cleanup` | 24-hour purge gate. |
| `<remote>.last-gotify-alert`, `global.last-gotify-alert` | Repeat suppression and "recovered". |
| `<remote>.mount-hung-since` | Hung-mount tracking. |
| `run-in-progress`, `last-stuck-alert` | Stuck-run detection. |

The lock and the array-down alert marker live in `/var/run` (RAM), so a reboot clears them.

---

## Testing

`test-rclone-backup.sh` runs 169 checks in a couple of minutes and is safe on the production server: it builds its own throwaway crypt remotes under `/tmp`, its own config block, log, lock and state, a fake Unraid `var.ini`, and a stub Gotify. It never touches your real remotes, log or lock. It also runs `--check-config` against your real configuration, read-only.

```
bash test-rclone-backup.sh ./rclone-backup.sh
KEEP=1 bash test-rclone-backup.sh ./rclone-backup.sh          # keep the temp folder to inspect
REPORT=TEST-RESULTS.md bash test-rclone-backup.sh ./rclone-backup.sh   # also write a results report
```

`TEST-RESULTS.md` in this repo is the report from the last run: every check with its ID, expected outcome and PASS/FAIL/SKIP. The last section of `QA-TEST-PLAN.md` maps each manual case to the automated checks that cover it, and lists what can only be proven on real hardware.

Static checks (syntax, ShellCheck, settings present, safe defaults), unit tests of the script's functions (bandwidth parsing, path aliases, validation, due logic, purge selection, repeat suppression), and integration runs with real rclone (copy/sync behaviour, mount down, hard stops, purge, dry run, locking, multiple remotes and intervals, bandwidth, notifications).

The self-test proves the logic. `QA-TEST-PLAN.md` is for proving it on your own hardware before you trust it: it sets up a QA copy of the script against dedicated test folders on your real remotes, then walks through 139 cases covering the preflight checks (including a dropped, frozen and wrong mount, a stopped and a degraded array), every configuration rule, both job modes, the purge, multiple remotes and intervals, bandwidth schedules, locking and crash recovery, every notification, a dry run, soak tests over a day and a month, and teardown.

---

## Adapting it to your setup

- **Not Unraid?** Set `ARRAY_CHECK="false"`. Everything else is plain Linux. The mount-path alias logic only activates for `/mnt/user`, `/mnt/diskN` and pool paths, so it is inert elsewhere.
- **No mount?** `MOUNT_POINT=""` and `MOUNT_CHECK="false"` in that remote's block (or in defaults).
- **No Gotify?** `GOTIFY_ENABLED="false"`. Errors still go to the log and the exit code.
- **Different retention per remote?** Put `DELETED_RETENTION_DAYS=90` inside that remote's block.
- **Excluding files** (temp files, `.DS_Store`): add rclone filters to `RCLONE_EXTRA_FLAGS`, e.g. `("--exclude" "*.tmp")`. Excluded files are neither uploaded nor archived.
- **SFTP connection limits:** set `connections = N` on the SFTP remote in your rclone config and keep `--transfers` and `--checkers` small (`RCLONE_EXTRA_FLAGS=("--transfers" "3" "--checkers" "3")`). Remember the mount and any other client count against the same limit.
- **`--fast-list`:** only helps backends that can list a whole tree in one call (S3, B2, Google Drive...). Check with `rclone backend features remote: | grep ListR`. Add it via `RCLONE_EXTRA_FLAGS` if `true`.
- **Running one remote first**: start with `REMOTES=("main")` and one block; add blocks later.

---

## Assumptions and caveats

- **Sync destinations are write-only from this script.** Anything added to a sync job's folder on the remote by another route (through the mount, another machine) is not in the local watch folder, so the next run archives it as deleted and purges it 30 days later.
- **Unraid internals.** Array state is read from `/var/local/emhttp/var.ini` (`mdState`, `mdNumMissing`, `mdNumDisabled`, `mdNumInvalid`, `fsNumUnmountable`) and pool names from `/boot/config/pools/*.cfg`. Check with `grep -E 'mdState|mdNum|fsNumUnmountable' /var/local/emhttp/var.ini` and `ls /boot/config/pools`. A missing key is skipped, not treated as an error. A pool defined there but never mounted keeps deletions paused.
- **The array-down alert may not reach you.** If Gotify runs in Docker on the same server, it stops with the array. The message still goes to the syslog (`logger -t rclone-backup`).
- **Mount path must be the real mount path**, e.g. `/mnt/cache/remoteshare`, not `/mnt/user/remoteshare`. The alias is handled for job checks, but the mount table lists only the real path. Set the mount folder's share to cache-only with no mover, or mover may carry stranded files onto the array.
- **Backend needs server-side move.** Archiving relies on it. rclone reports it as `Move: true` in `rclone backend features remote:`.
- **No resume.** rclone restarts an interrupted upload from zero on the next run. Very large files on a flaky link may take several attempts.
- **Partial cleanup depends on rclone's naming** (`name.<8 hex>.partial`). A future rclone change would make leftovers archived and reported again, which is harmless noise. Copy jobs don't clean partials; a leftover there is replaced when that file uploads again.
- **`MAX_DELETES_PER_JOB` is a ceiling, not a pre-check.** rclone archives up to the limit and then stops, so up to that many files are archived before the guard fires. They stay restorable for the retention period.
- **Intervals count from the start of the run** that last succeeded. A manual `--force` or `--only` run resets that remote's clock. A long first upload to one remote delays the remotes after it in that run; they are never skipped.
- **The stuck-run threshold covers the whole run**, all remotes together.
- **Repeat suppression** ignores growing counts (consecutive hung runs, log size, run length, skipped runs) but nothing else, so two different problems always produce two alerts.
- **Times are the server's local time**, including bandwidth changes and archive stamps. On daylight-saving change days a change happens an hour early or late.
- **Bandwidth is per rclone process.** Mounts need their own `--bwlimit` in the mount command. Speeds are given in Mbps and converted to KiB/s (rclone's unit).
- **Two differently named rclone remotes that point at the same storage** can't be detected as overlapping. Use one remote name per storage location.
- **The config is bash.** An unclosed quote stops the whole script, including scheduled runs. Run `--check-config` after every edit; it reports bash syntax errors with a line number.
- **Folder names containing `|` or a newline** can't be used in `JOBS`.
- **The log grows forever.** A warning fires at `LOG_WARN_SIZE_MB`; clear it with `truncate -s 0` while no run is active.
- **A hard kill (`kill -9`) leaves one temp folder** under `/tmp/rclone-backup.*`. It is harmless and gone after a reboot.
- **crypt remotes don't expose checksums.** Verify archived content with `rclone cat`, not `rclone md5sum`.

---

## Licence and credit

Use it, change it, share it. The script was written and tested with an AI assistant as a pair, with every design decision, edge case and test scenario directed and verified by me; the self-test harness and the real-environment QA plan were part of that process rather than an afterthought.
