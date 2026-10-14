# rclone-backup.sh - automated test results

- Run: 2026-10-12 09:50:43 on vm
- Script: `rclone-backup.sh` (md5 dbc12af6341d)
- rclone: rclone v1.75.1, bash 5.2.21
- Result: **168 passed, 0 failed, 1 skipped** of 169 checks

ID prefixes: S = static checks on the script file, U = unit tests of the script's functions, I = integration runs of the whole script with real rclone against throwaway remotes, M = multi-remote and interval integration runs. Each row's text is the expected outcome; PASS means it was observed.

## Static checks

| ID | Expected outcome | Result |
| --- | --- | --- |
| S01 | script found: /mnt/user-data/outputs/rclone-backup.sh | PASS |
| S02 | bash syntax (bash -n) | PASS |
| S03 | shellcheck clean | PASS |
| S04 | all global settings and defaults present | PASS |
| S05 | production default: DRY_RUN=false | PASS |
| S06 | production default: ARRAY_CHECK=true | PASS |
| S07 | config marker lines present exactly once each | PASS |
| S08 | deleted-stamp format _DELETED_YYYY-MM-DD_HHMMSS | PASS |
| S09 | run stamp has seconds | PASS |
| S10 | Gotify token still the placeholder (set GOTIFY_TOKEN before going live) | SKIP |
| S11 | required tools installed | PASS |
| S12 | your configured remotes pass --check-config | PASS |

## Unit tests (functions sourced from the script)

| ID | Expected outcome | Result |
| --- | --- | --- |
| U01 | norm_path '/a//b/' -> 'a/b' | PASS |
| U02 | norm_path '' -> '' | PASS |
| U03 | days: Daily -> all 7 | PASS |
| U04 | days: Mon-Fri | PASS |
| U05 | days: Fri-Mon wraps weekend | PASS |
| U06 | days: Mon,Wed,Fri list | PASS |
| U07 | days: unknown name rejected | PASS |
| U07b | days: Weekdays / Weekends aliases | PASS |
| U08 | timetable: 3 changes a day + weekend, Mbps converted | PASS |
| U09 | timetable: bad time rejected | PASS |
| U10 | timetable: speed 0 rejected | PASS |
| U11 | timetable: text speed rejected | PASS |
| U12 | timetable: same day+time twice rejected | PASS |
| U13 | timetable: missing field rejected | PASS |
| U14 | timetable: empty schedule rejected | PASS |
| U15 | rclone accepts the generated timetable | PASS |
| U16 | share_key: /mnt/cache/x -> @shares/x | PASS |
| U17 | share_key: /mnt/user/x and /mnt/disk3/x | PASS |
| U18 | share_key: /mnt/user alone = all shares | PASS |
| U19 | share_key: non-share path has no key | PASS |
| U20 | overlap: /mnt/user/remoteshare/a is inside /mnt/cache/remoteshare | PASS |
| U21 | overlap: /mnt/user contains /mnt/cache/remoteshare | PASS |
| U22 | overlap: unrelated share is fine | PASS |
| U23 | valid two-remote config accepted (same dest on different remotes is fine) | PASS |
| U24 | unknown mode flagged | PASS |
| U25 | nested destinations flagged | PASS |
| U26 | overlap across remotes sharing a REMOTE flagged on both | PASS |
| U27 | source inside ANOTHER remote's mount flagged | PASS |
| U28 | source via /mnt/user alias of a cache mount flagged | PASS |
| U29 | source /mnt/user (contains mounts) flagged | PASS |
| U30 | REMOTE without ':' or '/' flagged | PASS |
| U31 | RUN_EVERY_HOURS 0 flagged | PASS |
| U32 | empty MOUNT_POINT with MOUNT_CHECK=true flagged | PASS |
| U33 | empty MOUNT_POINT with MOUNT_CHECK=false accepted | PASS |
| U34 | bad bandwidth line flagged with its text | PASS |
| U35 | BANDWIDTH_LIMIT typo flagged | PASS |
| U36 | bad boolean flagged | PASS |
| U37 | missing remote block aborts | PASS |
| U38 | duplicate remote name aborts | PASS |
| U39 | invalid remote name aborts | PASS |
| U40 | empty REMOTES aborts | PASS |
| U40b | non-numeric global setting aborts | PASS |
| U40c | non-boolean global setting aborts | PASS |
| U40d | refused rclone flag flagged | PASS |
| U40e | harmless rclone flags accepted | PASS |
| U40f | ARCHIVE_DIR with a slash flagged | PASS |
| U41 | defaults apply, a block overrides them for itself only | PASS |
| U41b | MOUNT_CHECK: default true, one remote false, the other inherits true | PASS |
| U42 | settings don't leak between remotes | PASS |
| U43 | 1h remote due 59m50s after last success (grace) | PASS |
| U44 | 1h remote not due 40 min after | PASS |
| U45 | 12h remote not due after 6h | PASS |
| U46 | 12h remote due after 11h55m | PASS |
| U47 | never-run remote is due | PASS |
| U48 | ini_val reads quoted value | PASS |
| U49 | degraded array pauses deletions for all remotes | PASS |
| U50 | a pool that isn't mounted pauses deletions | PASS |
| U51 | healthy array, no pools: no pause | PASS |
| U52 | stopped array fails started-check | PASS |
| U53 | /mnt/user not mounted fails started-check | PASS |
| U54 | hung mount detected, counted per remote, deletions paused | PASS |
| U55 | 'transport endpoint not connected' treated as hung | PASS |
| U56 | healthy mount clears hung state | PASS |
| U57 | mounted but canary missing warns 'not visible' | PASS |
| U58 | purge selects only expired stamped files | PASS |
| U59 | countdown 3/2/1 days + purged count, titled with remote name | PASS |
| U60 | purge listing failure is an ERROR and retries | PASS |
| U61 | purge 'not found' (exit 3) is not an error | PASS |
| U62 | purge markers are per remote | PASS |
| U63 | repeat suppression: growing counts suppressed | PASS |
| U64 | repeat suppression: different paths are new alerts | PASS |
| U65 | suppression and recovery are per remote | PASS |

## Sandbox integration tests (real rclone, throwaway crypt remotes)

| ID | Expected outcome | Result |
| --- | --- | --- |
| I01 | copy: new file uploaded, exit 0 | PASS |
| I01 | copy: content correct | PASS |
| I02 | copy: modified file updated | PASS |
| I02 | copy: old version in _archive/<stamp>/... | PASS |
| I02 | copy: archived version holds old content | PASS |
| I03 | copy: locally deleted file stays on remote | PASS |
| I03 | copy: nothing in _archive/deleted | PASS |
| I04 | copy: uploads/versions send no Gotify | PASS |
| I05 | sync: new uploads only -> no Gotify | PASS |
| I06 | sync: archived with folders kept + stamp before extension | PASS |
| I06 | sync: archived content intact | PASS |
| I06 | sync: removed from destination | PASS |
| I07 | sync: no-extension and compound-extension names | PASS |
| I08 | sync: spaces/Unicode names archived | PASS |
| I09 | archive message: one 'Files archived ... (t1)', priority 4 | PASS |
| I09 | archive message: count, paths and purge date | PASS |
| I10 | sync: modified file versioned, not archived as deleted | PASS |
| I11 | sync: same file deleted twice -> two stamped copies | PASS |
| I12 | partial: old leftover partial deleted | PASS |
| I12 | partial: not archived, not in any message | PASS |
| I12 | partial: young partial (<1h) left alone | PASS |
| I12 | partial: same-named LOCAL file never removed | PASS |
| I12 | partial: removal logged | PASS |
| I13 | mount down: exit 0, uploads still run | PASS |
| I13 | mount down: deletion paused (file kept) | PASS |
| I13 | mount down: no 'Files archived' message | PASS |
| I14 | stranded files warned, never uploaded | PASS |
| I15 | mount down + pause off: deletion archived | PASS |
| I16 | canary missing: remote skipped, exit 1, nothing uploaded | PASS |
| I16 | canary missing: 'Backup FAILED on <host> (t1)' | PASS |
| I17 | overlapping destinations: remote skipped, nothing uploaded | PASS |
| I17 | overlapping destinations: alert explains the fix | PASS |
| I18 | array stopped: exit 1, no state folder, nothing uploaded | PASS |
| I18 | array stopped: Gotify alert | PASS |
| I18 | array alert marker kept next to the TEST lock, not production's | PASS |
| I19 | /mnt/user not mounted: exit 1, nothing uploaded | PASS |
| I20 | degraded array: uploads continue, deletion paused | PASS |
| I20 | degraded array: one global warning (no remote suffix) | PASS |
| I21 | max-delete: exit 1, no more than 2 archived | PASS |
| I21 | max-delete: message matches files archived (2) + error alert | PASS |
| I22 | empty sync source: exit 1, nothing archived | PASS |
| I23 | purge: expired files deleted | PASS |
| I23 | purge: due/fresh/unstamped/old-format kept | PASS |
| I23 | purge: version folders untouched | PASS |
| I24 | purge: countdown + purged count in one message | PASS |
| I25 | purge: only once per CLEANUP_INTERVAL_HOURS | PASS |
| I26 | dry run: remote unchanged | PASS |
| I26 | dry run: purge marker and last-success unchanged | PASS |
| I26 | dry run: '[DRY RUN] Files would be archived (t1)' | PASS |
| I27 | bandwidth on: rclone limiter started at 80 Mbps (9.537 MiB/s) | PASS |
| I28 | bandwidth off: no limiter | PASS |
| M01 | first run: both remotes run, t1 first then t2 | PASS |
| M01 | both remotes received the file | PASS |
| M02 | immediate rerun: neither remote due, nothing uploaded | PASS |
| M03 | 59m50s later: hourly t1 runs (grace), 12h t2 does not | PASS |
| M04 | 11h55m later: t2 runs too | PASS |
| M05 | t2 failing does not stop t1 | PASS |
| M05 | failure alert names t2 only | PASS |
| M06 | failed remote keeps its previous last-success (so it is retried next run) | PASS |
| M07 | --only t2: runs t2 now, t1 untouched | PASS |
| M07 | recovery message names t2 | PASS |
| M08 | --only with an unknown name: error, exit 1 | PASS |
| M09 | same deletion archived on BOTH remotes, one message each | PASS |
| M10 | bad t2 bandwidth line: t2 skipped, t1 still runs | PASS |
| M10 | config alert names t2 and quotes the bad line | PASS |
| M11 | --check-config: exit 1 and lists the problem | PASS |
| M12 | --check-config: valid config exits 0, shows both remotes | PASS |
| M12 | --check-config with a broken REMOTES list: exit 1, explains, writes nothing to the log | PASS |
| M13 | removing t1 from REMOTES pauses it | PASS |
| I29 | overlapping run: exits 0, skips, uploads nothing | PASS |
| I30 | stuck run: 'Backup stuck' alert, counter incremented | PASS |
| I31 | lock released: next run proceeds, run-state removed | PASS |
| I32 | repeat suppression: one alert for two identical runs | PASS |
| I33 | recovery message after problem clears | PASS |
| I34 | log size warning (global) with truncate instructions | PASS |
| I35 | archive message: 12 files, 10 listed + '... and 2 more'; copy deletions never listed | PASS |
| I39 | VERSIONING=false: modified file overwritten, no version folder | PASS |
| I40 | SKIP_EXISTING=true: existing file kept, new file uploaded | PASS |
| I41 | missing source folder: that job skipped, other jobs still run, exit 1, alert names it | PASS |
| I42 | ARRAY_CHECK=false: stopped-array ini ignored, run proceeds | PASS |
| I43 | DELETED_RETENTION_DAYS=0: nothing purged, no countdown message | PASS |
| I44 | GOTIFY_NOTIFY_SUCCESS=true: 'Backup OK on <host> (t1)' priority 2 | PASS |
| I36 | temp work folder removed after run | PASS |
| I37 | unknown option: exit 2 with usage hint | PASS |
| I38 | production lock and alert marker untouched by the whole suite | PASS |
