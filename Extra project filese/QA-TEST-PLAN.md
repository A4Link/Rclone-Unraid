# rclone-backup.sh – Real-Environment QA Test Plan

139 hand-run test cases for validating `rclone-backup.sh` on a real Unraid server, real remotes, real mounts and real Gotify. Every case has an ID, the exact input or steps, the expected output, and a Result column to fill in.

The automated self-test (`test-rclone-backup.sh`) proves the script's logic against throwaway remotes. This plan proves it on *your* hardware: your rclone config, your mounts, your array, your notification server.

Contents: [Setup](#scope-and-qa-setup) · [Config check and preflight](#config-check-and-preflight-safety) · [Configuration validation](#configuration-validation) · [Copy mode](#copy-mode) · [Sync mode](#sync-mode) · [Purge](#30-day-purge-and-countdown) · [Multiple remotes](#multiple-remotes-and-intervals) · [Bandwidth](#bandwidth-schedule) · [Locking](#locking-stuck-runs-and-crash-recovery) · [Gotify](#gotify-notifications-and-log-size) · [Dry run, soak, teardown](#dry-run-soak-tests-and-teardown)

## Scope and QA setup

These 139 cases validate the profile-based `rclone-backup.sh` by hand on your real Unraid server, real remotes (`secret:` and the SFTP-backed `secret2:`), real mounts and real Gotify. They run a QA copy of the script with two QA remotes that only touch dedicated test folders, so production shares are never involved.

**1. Pause production.** In User Scripts, set the production backup's schedule to *Schedule Disabled* until teardown (TD-03); it shares the lock with the QA copy.

**2. Create the QA copy** on the flash drive, so it still runs when the array is stopped:

```
mkdir -p /boot/config/rclone-qa
cp rclone-backup.sh /boot/config/rclone-qa/rclone-backup-qa.sh
```

In the copy, change only these parts of the config (keep RCLONE_CONF, LOCK_FILE, the Gotify settings and your real mount paths):

```
REMOTES=("qa_primary" "qa_offsite")
LOG_FILE="/mnt/user/appdata/rclone/qa-logs/backup.log"   # separate log and state

remote_qa_primary() {
    REMOTE="secret:"
    RUN_EVERY_HOURS=1
    MOUNT_POINT="/mnt/cache/remoteshare"
    JOBS=(
        "/mnt/user/qa/src-copy|qa-copy|copy"
        "/mnt/user/qa/src-sync|qa-sync|sync"
    )
    BANDWIDTH_LIMIT="off"
}

remote_qa_offsite() {
    REMOTE="secret2:"
    RUN_EVERY_HOURS=12
    MOUNT_POINT="/mnt/cache/remoteshare2"
    JOBS=( "/mnt/user/qa/src-sync|qa-sync|sync" )
    BANDWIDTH_LIMIT="off"
}
```

Delete the copied `remote_primary` and `remote_offsite` blocks from the QA copy so only the QA blocks remain.

**3. Create the test folders and canaries:**

```
mkdir -p /mnt/user/qa/src-copy /mnt/user/qa/src-sync
rclone --config /boot/config/plugins/rclone/.rclone.conf touch secret:.backup-canary
rclone --config /boot/config/plugins/rclone/.rclone.conf touch secret2:.backup-canary
```

**4. Terminal shortcuts** (paste once per terminal session):

```
R='rclone --config /boot/config/plugins/rclone/.rclone.conf'
QA='bash /boot/config/rclone-qa/rclone-backup-qa.sh'
QALOG=/mnt/user/appdata/rclone/qa-logs
QS=$QALOG/state
stamp() { date -d "-$1 days -$2 minutes" +%Y-%m-%d_%H%M%S; }
qareset() { rm -f $QS/*.last-gotify-alert $QS/*.last-deleted-cleanup $QS/*.mount-hung-since $QS/last-stuck-alert; }
```

**Conventions**

- "Run P" = `$QA --only qa_primary; echo "exit=$?"`. "Run O" = the same with `qa_offsite`. "Run all" = `$QA --force; echo "exit=$?"`. "Run scheduled" = `$QA; echo "exit=$?"` (only remotes that are due).
- Run `qareset` before each case unless the case builds on the previous one.
- "Remote shows" = `$R lsf -R secret:qa-sync` (or `qa-copy`, `_archive`, or `secret2:`). STAMP = `YYYY-MM-DD_HHMMSS` of that run.
- "Log" = `tail -n 40 $QALOG/backup.log`; each line is tagged `[qa_primary]` or `[qa_offsite]`. "Gotify" = the message in your Gotify app; per-remote titles end `(qa_primary)` or `(qa_offsite)`.
- Unless a case says otherwise: mounts up, array started and healthy, canaries present, QA config as above.
- Fill the Result column with Pass/Fail and a note.

## Config check and preflight safety

`--check-config` changes nothing. A missing canary skips only that remote; the array-started check stops everything; mount, array-health and pool problems only warn and pause archiving. Before each preflight case put one new file in each source (`date > /mnt/user/qa/src-copy/pf.txt`, same for `src-sync`) so you can see whether uploads happened.

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| CC-01 | Valid config | `ls -la $QS`; `$QA --check-config; echo $?`; `ls -la $QS` again | `Checked 2 remote(s). Nothing was changed.`; a `== qa_primary ==` and `== qa_offsite ==` section each ending `OK`; exit 0; state folder unchanged; nothing added to the log |  |
| CC-02 | One remote misconfigured | In `remote_qa_offsite` set `BANDWIDTH_LIMIT="yes"`; run `--check-config`; revert | exit 1; qa_offsite shows `PROBLEMS (this remote would be skipped)` with `BANDWIDTH_LIMIT 'yes' must be "on" or "off"`; qa_primary still `OK` |  |
| CC-03 | Broken bash in the config | Delete one closing `)` of a JOBS list; run `--check-config`; revert | bash reports a syntax error with a line number and nothing runs; the same error would stop scheduled runs, so always run `--check-config` after editing |  |
| PF-01 | Healthy baseline | Run all | exit=0; log has `[qa_primary] Backing up to secret:` then `[qa_offsite] Backing up to secret2:`; `pf.txt` on both remotes; no Gotify |  |
| PF-02 | Primary canary missing | `$R moveto secret:.backup-canary secret:.backup-canary.qa`; Run all; move it back | exit=1; `[qa_primary] ERROR: Canary secret:.backup-canary not found ... This remote was skipped`; nothing uploaded to `secret:`; qa_offsite runs normally; one Gotify `Backup FAILED on <host> (qa_primary)` |  |
| PF-03 | Offsite canary missing | As PF-02 on `secret2:` | Mirror image: qa_primary unaffected; Gotify `Backup FAILED on <host> (qa_offsite)` |  |
| PF-04 | Internet down | Disconnect the server's internet at the router; Run all; reconnect | exit=1 after about 2 minutes (each canary check times out); two Gotify alerts, `(qa_primary)` and `(qa_offsite)`; nothing changed |  |
| PF-05 | Primary mount down | `fusermount -uz /mnt/cache/remoteshare`; delete a file in `src-sync` that is on both remotes; Run all | exit=0; `[qa_primary] WARNING: /mnt/cache/remoteshare is not mounted.`; qa_primary uploads `pf.txt` and logs `Deletion step paused (mount not available)`, file still on `secret:qa-sync`; qa_offsite archives it on `secret2:`; Gotify `Backup warnings ... (qa_primary)` and `Files archived ... (qa_offsite)` |  |
| PF-06 | Stranded files | Still unmounted: `date > /mnt/cache/remoteshare/stranded.txt`; Run P; then `mv /mnt/cache/remoteshare/stranded.txt /mnt/user/qa/` | PF-05 warning plus `Files exist in /mnt/cache/remoteshare on the LOCAL drive`; `stranded.txt` appears on no remote |  |
| PF-07 | Mount back | Remount; Run P | No mount warning; the file deleted in PF-05 now archived on `secret:`; Gotify `Backup recovered on <host> (qa_primary)` |  |
| PF-08 | Hung offsite (SFTP) mount | `kill -STOP <pid of the rclone mount for remoteshare2>` (`pgrep -af 'rclone mount'` to find it); Run O twice; `kill -CONT` the same PID; Run O | Frozen runs take about 65 s longer and log `Mount /mnt/cache/remoteshare2 is hung/frozen since <time> (1 consecutive run(s))`, then `(2 ...)`; uploads still run; archiving paused; one Gotify for both (count ignored); after CONT: no warning, `$QS/qa_offsite.mount-hung-since` gone, `Backup recovered ... (qa_offsite)`. Anything else opening that mount also hangs while frozen, so keep it short |  |
| PF-09 | Wrong/stale mount | qa_primary `MOUNT_POINT="/boot"`; Run P; revert | WARNING `/boot is mounted but .backup-canary is not visible`; archiving paused; uploads run |  |
| PF-10 | Mount check off | qa_primary `MOUNT_CHECK="false"`, primary mount down, delete a synced file; Run P; revert and remount | No mount warning; the deletion is archived |  |
| PF-11 | Array stopped (real) | Stop the array; `bash /boot/config/rclone-qa/rclone-backup-qa.sh; echo $?`; start the array | exit=1; console `The Unraid array is not started (state: STOPPED)`; same line in `/var/log/syslog` tagged `rclone-backup`; no `qa-logs` created; console `Gotify: failed to send notification` because Gotify stops with the array |  |
| PF-12 | Array stopped (simulated) | `cp /var/local/emhttp/var.ini /boot/config/rclone-qa/var-test.ini`, set `mdState="STOPPED"` in it, point `UNRAID_VAR_INI` at it; Run all twice | exit=1 both times; nothing uploaded; one Gotify `Backup NOT run on <host> - array not available` (no remote name), first run only |  |
| PF-13 | Array degraded (simulated) | In `var-test.ini` set `mdState="STARTED"`, `mdNumDisabled="1"`; delete a synced file; Run all | exit=0; one global Gotify `Backup warnings on <host>` (no remote name) with `The Unraid array is degraded (mdNumDisabled=1)`; both remotes upload; both log `Deletion step paused (array degraded)` |  |
| PF-14 | Pool not mounted (simulated) | Restore the real `UNRAID_VAR_INI`; `mkdir /boot/config/rclone-qa/pools; touch /boot/config/rclone-qa/pools/nosuchpool.cfg`; set `UNRAID_POOLS_DIR` to that folder; delete a synced file; Run all; revert | Global warning `pool 'nosuchpool' not mounted`; archiving paused on both remotes; uploads run |  |
| PF-15 | Array check off | STOPPED `var-test.ini` with `ARRAY_CHECK="false"`; Run all; revert both | Runs normally, exit=0 |  |

## Configuration validation

Problems with the REMOTES list stop the whole run before anything happens. Problems inside one remote's block skip only that remote, with a Gotify alert naming it and the fix, while the other remotes still run. Try each case with `--check-config` first (it should list the same problem), then Run all; revert after each. Job fields are written SRC / DEST / MODE.

| ID | Scenario | Change to the QA config | Expected output | Result |
| --- | --- | --- | --- | --- |
| CV-01 | Remote with no block | `REMOTES=("qa_primary" "qa_x")` | Whole run stops: exit=1, `ERROR: Config: REMOTES lists 'qa_x' but there is no remote_qa_x block`, `Backup aborted`; nothing uploaded anywhere; Gotify `Backup FAILED on <host>` (no remote name) |  |
| CV-02 | Name listed twice | `REMOTES=("qa_primary" "qa_primary")` | Whole run stops with `listed twice` |  |
| CV-03 | Invalid name | Rename to `qa-offsite` in REMOTES and the block | Whole run stops with `is not allowed` (letters, digits, underscores) |  |
| CV-04 | Bad interval | qa_offsite `RUN_EVERY_HOURS=0` (then try `six`) | qa_offsite skipped: `Config: RUN_EVERY_HOURS '0' must be a whole number of hours, 1 or more.` and `Skipped - fix the settings in the remote_qa_offsite block`; qa_primary runs; exit=1; Gotify `Backup FAILED ... (qa_offsite)` |  |
| CV-05 | REMOTE missing its colon | qa_offsite `REMOTE="secret2"` | qa_offsite skipped: `REMOTE 'secret2' must end in ':' or '/'` |  |
| CV-06 | Nested destinations | qa_primary: add SRC `/mnt/user/qa/src-copy` / DEST `qa-sync/sub` / MODE copy | qa_primary skipped with `Destinations overlap on secret:` and `Fix: use side-by-side folders` |  |
| CV-07 | Overlap across remotes sharing a REMOTE | qa_offsite `REMOTE="secret:"` (both now use `secret:qa-sync`) | Both remotes skipped, each with `both use secret:qa-sync` |  |
| CV-08 | Same destination on different remotes | The default QA config (`qa-sync` on `secret:` and `secret2:`) | Accepted; covered by PF-01 |  |
| CV-09 | Unknown mode | MODE `mirror`, then `copy ` with a trailing space | Remote skipped: `unknown mode 'mirror'` |  |
| CV-10 | Source inside another remote's mount, by its /mnt/user name | qa_offsite: add SRC `/mnt/user/remoteshare/x` / DEST `qa-x` / MODE copy | qa_offsite skipped: `the source is inside the mount /mnt/cache/remoteshare (remote 'qa_primary')` |  |
| CV-11 | Source containing every mount | qa_primary: add SRC `/mnt/user` / DEST `qa-all` / MODE copy | qa_primary skipped: `the source contains the mount` (both mounts listed) |  |
| CV-12 | Mount check with no mount point | qa_offsite `MOUNT_POINT=""` | Skipped: `MOUNT_CHECK is true but MOUNT_POINT is empty`; adding `MOUNT_CHECK="false"` makes it valid |  |
| CV-13 | Missing source folder | qa_primary: add SRC `/mnt/user/qa/does-not-exist` / DEST `qa-missing` / MODE copy | Config accepted; on the run that job alone logs `does not exist`, the other jobs and qa_offsite run; exit=1 |  |
| CV-14 | Single-remote setup | `REMOTES=("qa_primary")` (leave the offsite block in place, even broken) | Only qa_primary appears in `--check-config` and the log; the unlisted block is ignored |  |
| CV-15 | Defaults and overrides | In `defaults()` set `MAX_DELETES_PER_JOB=100`; in qa_offsite set `MAX_DELETES_PER_JOB=2`; delete 4 synced files; Run all | qa_primary archives all 4; qa_offsite stops at 2 with `hit MAX_DELETES_PER_JOB (2)` |  |

## Copy mode

A copy job never removes anything from the remote; a modified file's old version goes to `_archive/STAMP/qa-copy/...`. These cases use qa_primary (source `/mnt/user/qa/src-copy`, destination `secret:qa-copy`) via Run P.

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| CP-01 | New file | `mkdir -p .../src-copy/docs; echo v1 > .../src-copy/docs/a.txt`; Run P | exit=0; `$R cat secret:qa-copy/docs/a.txt` prints `v1`; nothing new under `_archive`; no Gotify |  |
| CP-02 | Nothing changed | Run P again | No file transfers for qa-copy in the log; no new `_archive/STAMP` folder |  |
| CP-03 | Modified file | `echo v2 > .../docs/a.txt`; Run P | Remote prints `v2`; `$R cat secret:_archive/STAMP/qa-copy/docs/a.txt` prints `v1`; no Gotify |  |
| CP-04 | Modified twice | `v3` then `v4`, one Run P each | Two more version folders holding `v2` and `v3`; current prints `v4` |  |
| CP-05 | Deleted file | `rm .../docs/a.txt`; Run P | Still on remote, unchanged; nothing under `_archive/deleted/qa-copy`; no Gotify |  |
| CP-06 | Deleted folder | Create `old/1.txt`, `old/2.txt`; Run P; `rm -r .../src-copy/old`; Run P | Both files remain on remote |  |
| CP-07 | Visible through the mount | After CP-01: `ls /mnt/cache/remoteshare/qa-copy/docs` | File listed with a readable name (allow up to the mount's dir-cache time, default 5 min) |  |
| CP-08 | Spaces and accents | `mkdir -p ".../src-copy/My Files"; echo u > ".../src-copy/My Files/naïve résumé.pdf"`; Run P | Same name on remote and through the mount |  |
| CP-09 | Large file | Copy a 5-10 GB file into `src-copy`; Run P | exit=0; `$R size secret:qa-copy` includes it; note the run time against the hourly schedule |  |
| CP-10 | File changing during upload | Start Run P with a large new file, and append to it while it uploads (`head -c 100M /dev/urandom >> file`) | rclone ERROR (source changed); `Upload failed for ...`; exit=1; Gotify `Backup FAILED ... (qa_primary)` with the rclone error line; the next run uploads it cleanly |  |
| CP-11 | Versioning off | qa_primary `VERSIONING="false"`, `SKIP_EXISTING="false"`; modify a file; Run P; revert | Remote overwritten; no new `_archive/STAMP` folder |  |
| CP-12 | Skip existing | qa_primary `VERSIONING="false"`, `SKIP_EXISTING="true"`; modify one file and add one; Run P; revert | Modified file not updated on remote; new file uploaded |  |

## Sync mode

A sync job moves each locally deleted file to `_archive/deleted/qa-sync/<same folders>/name_DELETED_STAMP.ext`; nothing is truly deleted until the purge. Cases use qa_primary (`secret:qa-sync`) via Run P unless stated. Each case first uploads its files with one run, then makes the change and runs again.

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| SY-01 | Deleted file | `mkdir -p .../src-sync/photos/2024; echo img1 > .../photos/2024/img.jpg`; Run P; `rm` it; Run P | Gone from `qa-sync/photos/2024/`; present as `_archive/deleted/qa-sync/photos/2024/img_DELETED_STAMP.jpg`; `$R cat` of it prints `img1`; Gotify `Files archived on <host> (qa_primary)` (priority 4) listing `qa-sync/photos/2024/img.jpg` |  |
| SY-02 | No extension | Create then delete `Makefile` | `Makefile_DELETED_STAMP` |  |
| SY-03 | Compound extension and dotfile | Create then delete `backup.tar.gz` and `.env` | `backup_DELETED_STAMP.tar.gz` and `_DELETED_STAMP.env` |  |
| SY-04 | Same file deleted twice | Delete `a.txt`, recreate, run, delete again, run | Two archived copies with different STAMPs |  |
| SY-05 | Deleted folder | Create `trip/1.jpg`, `trip/2.jpg`, `trip/3.jpg`; then `rm -r trip` | All three under `_archive/deleted/qa-sync/trip/`, each stamped; one Gotify listing 3 files |  |
| SY-06 | Modified file | Change `keep.txt` | Old version at `_archive/STAMP/qa-sync/keep.txt` (no `_DELETED_`); nothing new in `_archive/deleted`; no Gotify |  |
| SY-07 | Renamed file | `mv x.txt y.txt` | `y.txt` uploaded; `x_DELETED_STAMP.txt` archived |  |
| SY-08 | Spaces and accents | Create then delete `My Files/naïve résumé.pdf` | `My Files/naïve résumé_DELETED_STAMP.pdf` |  |
| SY-09 | Empty source guard | Move every file out of `src-sync` (keep the folder); Run P; move them back | exit=1; ERROR `Deletion step skipped for ... folder has no files`; nothing archived |  |
| SY-10 | Max-delete limit | qa_primary `MAX_DELETES_PER_JOB=2`; delete 4 synced files; Run P; revert; Run P | First run: exit=1, `hit MAX_DELETES_PER_JOB (2)`, at most 2 archived, `Files archived` names exactly those. Second run: the rest archived |  |
| SY-11 | Upload failure blocks archiving | Delete one synced file and, in the same run, grow a large new file during upload (as CP-10) | `Upload failed`; no `Deletion step`/`Archived` line for qa-sync; the deleted file still in `qa-sync`; archived on the next clean run |  |
| SY-12 | Restore a deleted file | `$R copyto "secret:_archive/deleted/qa-sync/photos/2024/img_DELETED_STAMP.jpg" /mnt/user/qa/src-sync/photos/2024/img.jpg`; Run P | `img.jpg` back in `qa-sync/photos/2024/`; the archived copy stays until its purge date |  |
| SY-13 | File added on the remote side (accepted rule) | `echo r > /mnt/cache/remoteshare/qa-sync/remote-only.txt`; Run P | Archived as `remote-only_DELETED_STAMP.txt` |  |
| SY-14 | Archive browsable | `ls -R /mnt/cache/remoteshare/_archive/deleted/qa-sync` | Archived files listed with readable names |  |
| SY-15 | Old leftover partial upload | `$R touch -t 2020-01-01T00:00:00 "secret:qa-sync/old.bin.a1b2c3d4.partial"`; Run P | Log `Removing 1 leftover partial upload(s) from interrupted transfers`; file gone; not in `_archive`; not in any Gotify |  |
| SY-16 | Real interrupted upload | Put a 2 GB file in `src-sync`; start Run P and after a few seconds `pkill -f 'copy /mnt/user/qa/src-sync'`; `rm` the local 2 GB file; wait over an hour; Run P | The `.partial` left by the killed upload is removed as in SY-15, not archived |  |
| SY-17 | Young partial left alone | `$R touch "secret:qa-sync/young.bin.0badcafe.partial"`; Run P | Still there, not archived (under an hour old) |  |
| SY-18 | Your own file that looks like a partial | `echo k > .../src-sync/keep.1234abcd.partial`; Run P twice | Uploaded and never removed |  |
| SY-19 | Same deletion on both remotes | Delete a file synced to both remotes; Run all | Archived on `secret:` and on `secret2:`; two Gotify messages, `Files archived ... (qa_primary)` and `... (qa_offsite)` |  |

## 30-day purge and countdown

Each remote purges only files under its own `_archive/deleted` whose name stamp is more than 30 days old, at most once every 24 hours, and the same pass sends that remote's 3/2/1-day countdown. Seed empty files with back-dated stamps using `$R touch`, and run `qareset` before each case so the 24-hour gate is open.

```
P=secret:_archive/deleted/qa-sync/pu     # qa_primary
O=secret2:_archive/deleted/qa-sync/pu    # qa_offsite
```

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| PU-01 | Expired file purged | `$R touch "$P/expired_DELETED_$(stamp 31 0).txt"`; Run P | Gone; log `Cleanup: purging 1 file(s) deleted more than 30 days ago`; Gotify `Archived files due for deletion on <host> (qa_primary)` (priority 5) with `Permanently deleted this run: 1 file(s)` |  |
| PU-02 | Countdown | Touch `$P/day1_DELETED_$(stamp 29 720).txt`, `day2_..._$(stamp 28 720)`, `day3_..._$(stamp 27 720)`; Run P | All three kept; Gotify lines `3 day(s) until 1 archived file(s) will be deleted`, then 2, then 1; `Due soonest` lists `pu/day1_...` first |  |
| PU-03 | Recent file ignored | Touch `$P/fresh_DELETED_$(stamp 2 0).txt`; Run P | Kept; not in Gotify |  |
| PU-04 | 30-day boundary | Touch `$P/edge-in_DELETED_$(stamp 29 1435).txt` and `$P/edge-out_DELETED_$(stamp 30 5).txt`; Run P | `edge-out` purged; `edge-in` kept and counted under 1 day |  |
| PU-05 | Odd names | Touch expired `$P/arc_DELETED_$(stamp 35 0).tar.gz` and `$P/Makefile_DELETED_$(stamp 35 0)`; Run P | Both purged |  |
| PU-06 | Never purged | Touch `$P/plain.txt`, `$P/old_DELETED_$(stamp 40 0)/keep.txt`, `$P/legacy_DELETED_2020-01-01_0000.txt`, `secret:_archive/2020-01-01_000000/qa-copy/v.txt`; Run P | All four kept |  |
| PU-07 | Once per 24 hours | Without `qareset`, touch another expired file; Run P | Not purged; no countdown; no `Cleanup:` line. After `qareset` and Run P it is purged |  |
| PU-08 | Empty folders tidied | After the purges above: `$R lsf -R secret:_archive/deleted/qa-sync` | No leftover empty folders; `_archive/deleted` still exists |  |
| PU-09 | Retention off | qa_primary `DELETED_RETENTION_DAYS=0`; touch an expired file; Run P; revert | Nothing purged; no countdown |  |
| PU-10 | Countdown off | qa_primary `PURGE_WARNING_DAYS=0`; seed PU-01 and PU-02 files; Run P; revert | Expired file purged; Gotify only says `Permanently deleted this run: 1` |  |
| PU-11 | Each remote purges its own archive | Touch an expired file under both `$P` and `$O`; Run all | Both purged; two Gotify messages, `(qa_primary)` and `(qa_offsite)`; `ls $QS` shows `qa_primary.last-deleted-cleanup` and `qa_offsite.last-deleted-cleanup` |  |
| PU-12 | One remote's gate doesn't block the other | `qareset`; Run P; touch an expired file under `$O`; Run O | qa_offsite still purges (its own 24-hour marker), even though qa_primary just ran its purge |  |

## Multiple remotes and intervals

Remotes run one after another in REMOTES order. A remote is due when its `RUN_EVERY_HOURS` has passed since its last successful backup (10 minutes early is allowed); a failed remote is retried on the next run. To avoid waiting hours, these cases set the "last success" time by hand in `$QS/<name>.last-success` (seconds since 1970). Put a new file in `src-sync` before each run so you can see who uploaded it.

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| MR-01 | First scheduled run | `rm -f $QS/*.last-success`; Run scheduled | Both run, qa_primary first (its `Backing up` line comes before qa_offsite's); exit=0; `$QS/qa_primary.last-success` and `qa_offsite.last-success` written |  |
| MR-02 | Immediate rerun | Run scheduled again | `[qa_primary] Not due yet (every 1h; last success ...)` and the same for qa_offsite; the new file is not uploaded |  |
| MR-03 | Hourly slot with grace | `echo $(( $(date +%s) - 3590 )) > $QS/qa_primary.last-success`; Run scheduled | qa_primary runs (59 min 50 s counts as due); qa_offsite `Not due yet` |  |
| MR-04 | Offsite due | Set qa_primary as MR-03 and `echo $(( $(date +%s) - 42900 )) > $QS/qa_offsite.last-success` (11 h 55 min); Run scheduled | Both run |  |
| MR-05 | Offsite not due | Offsite last success 6 h ago (`- 21600`); Run scheduled | qa_offsite `Not due yet` |  |
| MR-06 | Changing the interval | Keep MR-05's state; set qa_offsite `RUN_EVERY_HOURS=6`; Run scheduled; set it back to 12 | qa_offsite now runs: the new interval applies immediately |  |
| MR-07 | Offsite failure doesn't block primary | Move `secret2:.backup-canary` away; Run all; put it back; Run scheduled | First run: qa_primary uploads normally; qa_offsite FAILED; exit=1; `qa_offsite.last-success` unchanged. Second run: qa_offsite is still due and runs (retry), Gotify `Backup recovered ... (qa_offsite)` |  |
| MR-08 | Run one remote by hand | `$QA --only qa_offsite` while it is not due | Only qa_offsite runs; no `[qa_primary]` lines |  |
| MR-09 | Unknown name | `$QA --only qa_offiste` (typo) | exit=1; `ERROR: --only 'qa_offiste' is not in REMOTES (qa_primary qa_offsite).`; nothing uploaded |  |
| MR-10 | Force everything | Both not due; Run all | Both run |  |
| MR-11 | Manual run moves the clock (known behaviour) | At about :50, Run P; let the next scheduled run fire at :00 | At :00 qa_primary is `Not due yet`; it runs at the following hour. Document this for the team |  |
| MR-12 | Long primary delays offsite, never skips it | Make offsite due (MR-04), put 5-10 GB in `src-copy`; Run scheduled | qa_offsite starts right after qa_primary's `Done` line, however long that takes; it is not skipped |  |
| MR-13 | Two remotes never run at once | During MR-12, `pgrep -af 'rclone (copy\|sync)'` a few times | Only one remote's rclone is ever running |  |
| MR-14 | Unknown option | `$QA --now` | exit=2; `Unknown option '--now'. Use --force, --only NAME or --check-config.` |  |

## Bandwidth schedule

Each remote has `BANDWIDTH_LIMIT` (on/off) and `BANDWIDTH_SCHEDULE` lines of `days  HH:MM  Mbps-or-unlimited` (days: Daily, Weekdays, Weekends, Mon-Fri, Mon,Wed,Fri or Fri-Mon). The script turns them into rclone's `--bwlimit` timetable (KiB/s = Mbps x 122.07), and rclone switches speed mid-transfer when a change time arrives. Each limit applies per remote while it uploads. rclone logs the active limit as `Starting bandwidth limiter at ...` (10 Mbps = 1.192Mi, 20 Mbps = 2.384Mi, 50 Mbps = 5.961Mi Byte/s).

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| BW-01 | Translation shown | qa_primary `BANDWIDTH_LIMIT="on"`, schedule `"Mon-Fri 06:00 20"`, `"Mon-Fri 18:00 2.5"`, `"Mon-Fri 23:00 unlimited"`, `"Sat-Sun 00:00 unlimited"`; `$QA --check-config` | Lines shown as entered, plus `rclone: --bwlimit "Mon-06:00,2441k ... Fri-06:00,2441k Mon-18:00,305k ... Fri-23:00,off Sat-00:00,off Sun-00:00,off"` (17 entries); `OK` |  |
| BW-02 | Fixed limit enforced | Schedule `"Daily 00:00 20"`; put a 500 MB file in `src-copy`; `time` Run P | Log `Starting bandwidth limiter at 2.384Mi Byte/s`; rclone's progress shows about 2.4 MiB/s; upload takes roughly 3.5 minutes |  |
| BW-03 | Limit off | `BANDWIDTH_LIMIT="off"`; another 500 MB file; `time` Run P | No `bandwidth limiter` line; noticeably faster (your line speed) |  |
| BW-04 | Speed changes mid-upload | Schedule `"Daily 00:00 10"` and `"Daily <HH:MM two minutes from now> unlimited"`; 2 GB file; Run P | Starts at `1.192Mi Byte/s`; at the change time the log shows `NOTICE: Scheduled bandwidth change. Bandwidth limits disabled` and the transfer speeds up |  |
| BW-05 | Three changes in one day | Schedule `"Daily <now-2h> 10"`, `"Daily <now-1h> 20"`, `"Daily <now+1h> 50"`; Run P with a 200 MB file | Limiter at `2.384Mi` (the 20 Mbps window you are in); repeat with the times shifted so you sit in each window in turn |  |
| BW-06 | Limit carries past midnight | Schedule only `"Daily 22:00 10"` and `"Daily 06:00 unlimited"`; Run P between 22:00 and 06:00 (or shift both times so "now" falls after the earlier-day entry) | Limiter at `1.192Mi`: the 22:00 setting is still in force after midnight |  |
| BW-07 | Weekend-wrapping range | Schedule `"Fri-Mon 00:00 10"` and `"Tue-Thu 00:00 unlimited"`; `--check-config` | Entries for Fri, Sat, Sun and Mon at 10 Mbps (`1221k`); Tue-Thu `off` |  |
| BW-08 | Per remote | qa_primary off; qa_offsite on with `"Daily 00:00 10"`; Run all with a new file | Only the `[qa_offsite]` part of the log has a `bandwidth limiter` line |  |
| BW-09 | Mistakes caught | One at a time: `"Workdays 06:00 20"`, `"Daily 6pm 20"`, `"Daily 06:00 0"`, `"Daily 06:00 fast"`, `"Daily 06:00"`, `"Mon-Fri 06:00 20"` plus `"Fri 06:00 50"`; `--check-config`, then Run all | Each is listed under PROBLEMS with the offending line quoted (unknown days / 24-hour HH:MM / above 0 / must be: days HH:MM speed / sets Fri-06:00 twice); on the run that remote is skipped with an alert and the other still runs |  |
| BW-10 | Limit on, schedule empty | `BANDWIDTH_LIMIT="on"`, `BANDWIDTH_SCHEDULE=()` | PROBLEMS: `BANDWIDTH_LIMIT is on but BANDWIDTH_SCHEDULE is empty` |  |
| BW-11 | Mounts unaffected | During BW-02, copy a large file through `/mnt/cache/remoteshare` from another session | The mount's speed is not limited by the script (mounts need their own `--bwlimit` in your mount command) |  |

## Locking, stuck runs and crash recovery

Only one run (QA or production) works at a time; later runs skip quietly unless the active one has passed `STUCK_RUN_HOURS` (3), which covers all remotes in that run together. These cases need a run lasting a few minutes: put a 5-10 GB file in `src-copy` and use two terminal windows, both with the shortcuts pasted.

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| LK-01 | Overlapping run | Terminal 1: Run all (large upload). Terminal 2, meanwhile: Run all | Terminal 2 returns within seconds, exit=0, `Previous run still in progress - skipping this run.`; no Gotify; terminal 1 finishes normally |  |
| LK-02 | QA and production share the lock | While terminal 1 uploads: `bash /path/to/rclone-backup.sh; echo $?` | Production skips the same way, exit=0 |  |
| LK-03 | Stuck-run alert | While terminal 1 uploads: `read s p k < $QS/run-in-progress; echo "$(( $(date +%s) - 14400 )) $p $k" > $QS/run-in-progress`; terminal 2: Run all | Gotify `Backup stuck on <host>` (priority 8, no remote name) with the start time 4 h ago, the PID, `1 scheduled run(s) have been skipped` and the tail/pgrep/kill instructions; third field of `run-in-progress` is now 1 |  |
| LK-04 | Stuck alert not repeated | Terminal 2: Run all again | No second Gotify within 6 h; counter now 2 |  |
| LK-05 | Stuck run ends | Let terminal 1 finish | `$QS/run-in-progress` removed; no "took N minutes" warning because it didn't really run 3 h (see SK-02) |  |
| LK-06 | Crash mid-upload | Terminal 2: `pkill -9 -f rclone-backup-qa.sh; pkill -9 -f 'copy /mnt/user/qa'` (never a bare `pkill rclone`, which would kill the mounts); then Run all | New run gets the lock at once and finishes the upload, exit=0. One leftover `/tmp/rclone-backup.XXXXXX` folder is expected (a hard kill skips cleanup); `rm -rf` it |  |
| LK-07 | Orphaned rclone keeps the lock | Kill only the script: `pkill -9 -f rclone-backup-qa.sh`; terminal 2: Run all until the orphaned rclone finishes | Runs skip while the orphan runs (it inherited the lock); the first run after it exits proceeds |  |
| LK-08 | Normal cleanup | After a normal run: `ls -d /tmp/rclone-backup.* 2>/dev/null` | Nothing listed (apart from LK-06's leftover if not yet removed) |  |

## Gotify notifications and log size

Each remote sends at most one summary per run, titled with its name (errors priority 8, warnings 5, recovery 4, success 2), plus its own "Files archived" (4) and purge-countdown (5) messages. Server-wide problems (array, pools, log size, stuck run, REMOTES list) come as one message with no remote name. New uploads and versioned changes never send anything. Identical alerts (ignoring growing counts such as consecutive runs, log size or run length) are not repeated within `GOTIFY_REPEAT_HOURS` (6), tracked separately per remote.

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| GO-01 | Token and URL work | `curl -s -H "X-Gotify-Key: <token>" -F title=QA -F message=test http://127.0.0.1:8070/message` | Message `QA` arrives |  |
| GO-02 | Clean runs are silent | `qareset`; Run all with only new/modified files | No Gotify |  |
| GO-03 | Success messages on | `GOTIFY_NOTIFY_SUCCESS="true"`; Run all; revert | Two messages: `Backup OK on <host> (qa_primary)` and `... (qa_offsite)`, priority 2 |  |
| GO-04 | Error content | Run PF-02 | Title `Backup FAILED on <host> (qa_primary)`; body starts `Run STAMP`, has the `ERROR:` line, ends `Full log: /mnt/user/appdata/rclone/qa-logs/backup.log` |  |
| GO-05 | rclone errors attributed to the right remote | Run CP-10 | qa_primary's alert has `rclone reported N error(s)` with up to 10 rclone `ERROR :` lines; qa_offsite gets no message |  |
| GO-06 | Repeat suppressed | Run PF-05 twice | One Gotify; second run logs `Gotify: same alert already sent within 6h - not resending` |  |
| GO-07 | New problem not suppressed | PF-05, then PF-06 | Two messages |  |
| GO-08 | Recovery once, per remote | After GO-06, remount and Run all twice | First run: `Backup recovered on <host> (qa_primary)` only; second: nothing |  |
| GO-09 | Dry-run label | `DRY_RUN="true"` plus a warning (PF-05) | Titles start `[DRY RUN]` |  |
| GO-10 | Gotify down | Stop the Gotify container; run PF-05; start Gotify; run PF-05 again | First run: `Gotify: failed to send notification (HTTP 000)`, backup unaffected. Second run: alert delivered |  |
| GO-11 | Wrong token | Wrong `GOTIFY_TOKEN`; run PF-05; revert | `Gotify: failed to send notification (HTTP 401)`; backup unaffected |  |
| GO-12 | Different jobs are separate alerts | Two runs, each with a different missing source (`.../missing1` then `.../missing2`, CV-13 style) | Two `Backup FAILED ... (qa_primary)` messages |  |
| GO-13 | Uploads are silent | Add 3 files to each source and modify one; Run all | Uploads and version moves happen; no Gotify |  |
| GO-14 | Archiving message | Delete 2 synced files (one in a subfolder); Run P | One `Files archived on <host> (qa_primary)` (priority 4): `2 file(s) deleted locally were moved to secret:_archive/deleted in run STAMP`, both original paths, `permanently deleted after <date 30 days ahead>`; log `Archived 2 deleted file(s)` |  |
| GO-15 | Archive message variants | (a) delete 12 synced files; (b) max-delete 2 with 4 deletions; (c) dry run with 1 deletion; (d) primary mount down with 1 deletion | (a) count 12, 10 listed, `... and 2 more`. (b) count equals files actually archived, plus a FAILED alert. (c) `[DRY RUN] Files would be archived ... (qa_primary)`, nothing moved. (d) no archive message for qa_primary |  |
| GO-16 | Server-wide and per-remote together | Degraded `var-test.ini` (PF-13) and move `secret2:.backup-canary` away; Run all; revert | Two messages: `Backup warnings on <host>` (no name, array degraded) and `Backup FAILED on <host> (qa_offsite)` |  |
| LS-01 | Log size warning | `truncate -s 1025M $QALOG/backup.log`; Run all | Server-wide `Backup warnings on <host>` with `The log file ... is 1025 MB (warning level 1024 MB)` and the `truncate -s 0` command |  |
| LS-02 | Log cleared | `truncate -s 0 $QALOG/backup.log`; Run all | No size warning; `Backup recovered on <host>` |  |
| LS-03 | Size check off | `LOG_WARN_SIZE_MB=0` with the 1025 MB file; Run all; revert | No size warning |  |

## Dry run, soak tests and teardown

A dry run must change nothing on any remote or in the state folder; the soak tests confirm behaviour that only shows over hours or days; teardown removes every QA trace and returns production to its schedule.

| ID | Scenario | Input / steps | Expected output | Result |
| --- | --- | --- | --- | --- |
| DR-01 | Dry run changes nothing | Save `$R lsf -R secret:` and `$R lsf -R secret2:` to files and `cp -a $QS /tmp/qs-before`. Set `DRY_RUN="true"`; add a file, modify one, delete a synced one, touch an expired stamp under `$P`; `qareset`; Run all; list again, `diff` the listings and `diff -r /tmp/qs-before $QS` | Remote listings identical; `last-success` files unchanged; no `last-deleted-cleanup` created; log `Backup started (DRY RUN)` with rclone "Skipped ... as --dry-run" lines; Gotify titles start `[DRY RUN]` |  |
| DR-02 | Real run after dry run | `DRY_RUN="false"`; Run all | Exactly the actions DR-01 listed now happen |  |
| SK-01 | 24-hour scheduled soak | Add the QA copy to User Scripts with custom schedule `0 * * * *`; make small changes during the day; check after 24 h with `grep -c '\[qa_primary\] Backing up' $QALOG/backup.log` and the same for qa_offsite | qa_primary about 24 runs, qa_offsite 2 (every 12 h); every `Backup started` has a `Backup finished`; no unexpected ERROR; no leftover `/tmp/rclone-backup.*`; Gotify only for real events |  |
| SK-02 | Genuinely long run | First production run (or a 3 h+ upload) on the hourly schedule | Stuck alert after 3 hours; when it ends, server-wide WARNING `This run took N minutes to finish; M scheduled run(s) were skipped` |  |
| SK-03 | Natural 30-day lifecycle | Note SY-01's deletion date and keep the QA schedule running | Countdown messages on days 27, 28 and 29; purged at the first daily purge check after day 30 |  |
| SK-04 | Bandwidth over a real day | Run SK-01 with BW-05's three-window schedule on qa_primary | `grep 'bandwidth limiter' $QALOG/backup.log` shows the speed matching each window's runs |  |
| SK-05 | Reboot | Reboot between scheduled runs | After array start and remount, the next hourly run works; no stale lock (it lives in RAM); intervals continue from the saved `last-success` times |  |
| TD-01 | Remove QA data from the remotes | `$R purge secret:qa-copy`, `$R purge secret:qa-sync`, `$R purge secret:_archive/deleted/qa-sync`, and the same `qa-sync` folders on `secret2:`; list `$R lsf --dirs-only secret:_archive` (and `secret2:`) and purge the STAMP folders created during QA plus `_archive/2020-01-01_000000` | `$R lsf -R secret:` and `secret2:` show no `qa-` paths |  |
| TD-02 | Remove local QA files | `rm -r /mnt/user/qa /mnt/user/appdata/rclone/qa-logs /boot/config/rclone-qa`; remove the QA User Script and any `/tmp/rclone-backup.*` leftovers | Nothing QA-related left on the server |  |
| TD-03 | Production restored | Confirm both canaries exist (`$R lsf secret:.backup-canary`, `secret2:`); production config has the real REMOTES, JOBS, `DRY_RUN="false"` and the real token; `bash /path/to/rclone-backup.sh --check-config`; re-enable the hourly schedule; run it once by hand | `--check-config` all `OK`; manual run exit=0 with `Backup started` / `Backup finished` |  |
| TD-04 | Sign-off | Review every Result cell | All Pass, or each Fail has a note and a decision (fix, accept, or retest) |  |

## Traceability to the automated suite

`test-rclone-backup.sh` runs 169 automated checks (168 pass, S10 is skipped until a Gotify token is set) against throwaway remotes; `REPORT=TEST-RESULTS.md bash test-rclone-backup.sh` writes every check with its expected outcome and result. The table below maps each manual case in this plan to the automated checks that cover the same behaviour. "Manual only" marks behaviour that needs real hardware, real timing or a real service and is proven only by running the case here.

| Manual case(s) | Automated checks | Notes |
| --- | --- | --- |
| CC-01 | S12, M12 | S12 runs `--check-config` against your real configuration |
| CC-02 | U34, U35, M10, M11 | |
| CC-03 | S02 | Syntax of the shipped script only; a deliberately broken config is manual |
| PF-01 | I01, I05, M01 | |
| PF-02, PF-03 | I16, M05 | |
| PF-04 | Manual only | Needs the internet disconnected |
| PF-05 | I13 | |
| PF-06 | I14 | |
| PF-07 | I33 | |
| PF-08 | U54, U55, U56 | Hang simulated with a stubbed `stat`; a real frozen FUSE mount is manual |
| PF-09 | U57 | |
| PF-10 | I15 | |
| PF-11 | I18, I19 | Simulated via `var.ini`; a real array stop is manual |
| PF-12 | I18, U52 | |
| PF-13 | I20, U49 | |
| PF-14 | U50 | |
| PF-15 | I42 | |
| CV-01 | U37, M12 | |
| CV-02 | U38 | |
| CV-03 | U39 | |
| CV-04 | U31 | |
| CV-05 | U30 | |
| CV-06 | U25, I17 | |
| CV-07 | U26 | |
| CV-08 | U23 | |
| CV-09 | U24 | |
| CV-10 | U20, U27, U28 | |
| CV-11 | U21, U29 | |
| CV-12 | U32, U33 | |
| CV-13 | I41 | |
| CV-14 | M13 | |
| CV-15 | U41, U41b, U42, I21 | |
| CP-01 | I01 | |
| CP-02 | Manual only | |
| CP-03, CP-04 | I02 | One version checked automatically; two successive versions are manual |
| CP-05, CP-06 | I03 | |
| CP-07 | Manual only | Needs the real mount |
| CP-08 | I08 | Automated for a sync job; the copy job is manual |
| CP-09, CP-10 | Manual only | Large files and files changing mid-upload |
| CP-11 | I39 | |
| CP-12 | I40 | |
| SY-01 | I06, I09 | |
| SY-02, SY-03 | I07 | |
| SY-04 | I11 | |
| SY-05 | I35 | |
| SY-06 | I10 | |
| SY-07 | Manual only | |
| SY-08 | I08 | |
| SY-09 | I22 | |
| SY-10 | I21 | |
| SY-11 | Manual only | Needs an upload failing mid-run |
| SY-12, SY-13, SY-14 | Manual only | Restore, remote-side additions and the mount view |
| SY-15, SY-17, SY-18 | I12 | |
| SY-16 | Manual only | A real interrupted upload; I12 seeds the leftover instead |
| SY-19 | M09 | |
| PU-01 | I23, I24, U58 | |
| PU-02 | I24, U59 | |
| PU-03 | I23 | |
| PU-04 | U58 | Exact 30-day boundary is manual |
| PU-05, PU-06 | I23, U58 | |
| PU-07 | I25 | |
| PU-08 | Manual only | |
| PU-09 | I43 | |
| PU-10 | Manual only | |
| PU-11, PU-12 | U62 | |
| MR-01 | M01 | |
| MR-02 | M02 | |
| MR-03 | M03, U43, U44 | |
| MR-04 | M04, U46 | |
| MR-05 | U45 | |
| MR-06 | Manual only | |
| MR-07 | M05, M06 | |
| MR-08 | M07 | |
| MR-09 | M08 | |
| MR-10 | Every I-case runs with `--force` | |
| MR-11, MR-12, MR-13 | Manual only | Timing behaviour on the real schedule |
| MR-14 | I37 | |
| BW-01 | U08, U15 | |
| BW-02 | I27 | |
| BW-03 | I28 | |
| BW-04, BW-05, BW-06 | Manual only | Mid-transfer and time-of-day behaviour; rclone's timetable semantics were confirmed by experiment during development |
| BW-07 | U05 | |
| BW-08 | Manual only | |
| BW-09 | U07, U09, U10, U11, U12, U13, U34, M10, M11 | |
| BW-10 | U14 | |
| BW-11 | Manual only | |
| LK-01 | I29 | |
| LK-02 | Manual only | Needs the production script |
| LK-03 | I30 | |
| LK-04 | Manual only | |
| LK-05 | I31 | |
| LK-06, LK-07 | Manual only | Hard kills of a live run |
| LK-08 | I36 | |
| GO-01 | Manual only | Real Gotify token |
| GO-02 | I04, I05 | |
| GO-03 | I44 | |
| GO-04 | I16 | |
| GO-05 | Manual only | |
| GO-06 | I32, U63 | |
| GO-07 | U64 | |
| GO-08 | I33, U65 | |
| GO-09 | I26 | |
| GO-10, GO-11 | Manual only | Real Gotify down / wrong token |
| GO-12 | U64 | |
| GO-13 | I04, I05 | |
| GO-14 | I09 | |
| GO-15 | I35 (a), I21 (b), I26 (c), I13 (d) | |
| GO-16 | I20, M05 | Each alert separately; the combined run is manual |
| LS-01 | I34 | |
| LS-02, LS-03 | Manual only | |
| DR-01 | I26 | |
| DR-02 | Manual only | |
| SK-01 to SK-05 | Manual only | Soak tests over hours and days |
| TD-01 to TD-04 | Manual only | Teardown and sign-off |

Automated checks with no manual counterpart: S01 to S11 (file-level checks), U01, U02, U16 to U19 (path helpers), U40 to U40f (global-setting and refused-flag validation), U47, U48, U51, U53, U60, U61 (purge listing failures), I18 (test isolation) and I38 (production files untouched by the suite).
