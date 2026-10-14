#!/bin/bash
#
# rclone-backup.sh - back up local watch folders to one or more rclone remotes, each on its own interval.
#
# Schedule this script to run EVERY HOUR (Unraid: User Scripts plugin, custom schedule "0 * * * *").
# Each remote then backs up on its own interval (RUN_EVERY_HOURS) from those hourly runs.
#
# Usage:
#   bash rclone-backup.sh                 back up every remote that is due (what the schedule runs)
#   bash rclone-backup.sh --force         back up every remote now, ignoring RUN_EVERY_HOURS
#   bash rclone-backup.sh --only NAME     back up just one remote now (e.g. --only offsite)
#   bash rclone-backup.sh --check-config  check the settings and show what would run; changes nothing
#
# Everything you need to edit is between CONFIG START and CONFIG END.
# After editing, run:  bash rclone-backup.sh --check-config

######################################## CONFIG START ########################################
# shellcheck disable=SC2329   # remote_<name> blocks are called by name from REMOTES

# =============================================================================================
# 1. REMOTES - the remote backups, in the order they run
# =============================================================================================
# Each name needs a matching "remote_<name>" block in section 4. Names: letters, digits and
# underscores, starting with a letter. Remotes run one after another, never at the same time.
#
#   One remote:      REMOTES=("main")
#   Two remotes:     REMOTES=("primary" "offsite")    # primary first, then offsite when it is due
#   Pause a remote:  take its name out of this list (its block can stay below).
REMOTES=("primary" "offsite")

# =============================================================================================
# 2. GLOBAL SETTINGS - shared by every remote
# =============================================================================================
RCLONE_CONF="/boot/config/plugins/rclone/.rclone.conf"
LOG_FILE="/mnt/user/appdata/rclone/logs/backup.log"   # one log for all remotes; state files are
                                                      # kept in a "state" folder next to it
LOCK_FILE="/var/run/rclone-backup.lock"               # stops two runs overlapping
DRY_RUN="false"            # true = show what would happen without changing anything

# Unraid array: if the array isn't started, nothing runs at all. If it's started but degraded
# (missing/disabled/unmountable disks, or a pool not mounted), uploads still run but no remote
# archives deletions, because files on an affected disk can vanish from user shares.
ARRAY_CHECK="true"
UNRAID_VAR_INI="/var/local/emhttp/var.ini"
UNRAID_POOLS_DIR="/boot/config/pools"   # pool names (e.g. "cache") are read from <name>.cfg here

CHECK_TIMEOUT=60           # seconds before a hung remote/mount check counts as failed
STUCK_RUN_HOURS=3          # alert if one run has been going this long (later runs are being skipped)
LOG_WARN_SIZE_MB=1024      # alert when the log file reaches this size (0 = off)
CLEANUP_INTERVAL_HOURS=24  # how often each remote's 30-day purge check runs
DUE_GRACE_MINUTES=10       # a remote counts as due this many minutes early, so hourly runs that
                           # start a few seconds apart never miss a slot

# Gotify notifications
GOTIFY_ENABLED="true"
GOTIFY_URL="http://127.0.0.1:8070"       # Gotify on this server (container port mapped to 8070)
GOTIFY_TOKEN="PASTE_APP_TOKEN_HERE"      # Gotify web UI -> Apps -> Create Application -> copy the token
GOTIFY_NOTIFY_SUCCESS="false"            # true = also send a message when a remote has no problems
GOTIFY_REPEAT_HOURS=6                    # don't resend the same alert within this many hours (0 = always).
                                         #   Growing counts (hung runs, log size, run length) are ignored
                                         #   when comparing, so "hung for 3 runs" and "4 runs" are the same.
GOTIFY_MAX_RCLONE_LINES=10               # rclone ERROR lines to include in a message
GOTIFY_MAX_ARCHIVED_LINES=10             # archived file names to list in a "Files archived" message

# =============================================================================================
# 3. DEFAULTS - apply to every remote unless that remote's block sets them again
# =============================================================================================
defaults() {
    VERSIONING="true"           # true = a modified file's old version is kept in _archive/<timestamp>/
    SKIP_EXISTING="false"       # only if VERSIONING="false": true = never overwrite files on the remote
    ARCHIVE_DIR="_archive"      # archive folder at the root of each remote

    DELETED_SUBDIR="deleted"    # sync jobs: deleted files go to _archive/deleted/...
    DELETED_RETENTION_DAYS=30   # purge archived deleted files this many days after deletion (0 = never)
    PURGE_WARNING_DAYS=3        # Gotify countdown for files due to be purged within this many days (0 = off)
    MAX_DELETES_PER_JOB=500     # safety: stop after archiving this many deletions in one job (0 = no limit)

    CANARY_FILE=".backup-canary"            # empty file at the remote root; create once per remote with:
                                            #   rclone touch <remote>:.backup-canary
    MOUNT_CHECK="true"                      # true = check each remote's mount (MOUNT_POINT) is live.
                                            #   Set MOUNT_CHECK="false" inside a remote's block to skip it there.
    PAUSE_SYNC_DELETES_IF_UNMOUNTED="true"  # true = sync jobs don't archive deletions while it's down

    BANDWIDTH_LIMIT="off"       # "on" / "off" for every remote (see section 4). A remote's block can
                                #   set BANDWIDTH_LIMIT="on" to limit just that remote.
    BANDWIDTH_SCHEDULE=()       # tip: a schedule set here is shared by every remote that switches
                                #      BANDWIDTH_LIMIT="on" in its own block
    RCLONE_EXTRA_FLAGS=()       # extra rclone options for uploads, e.g. ("--transfers" "3" "--checkers" "6").
                                # Options that change what gets archived or deleted are refused.
}

# =============================================================================================
# 4. ONE BLOCK PER REMOTE - copy a block to add a remote; "remote_<name>" must match REMOTES
# =============================================================================================
#
# REMOTE            the rclone remote to back up to, ending in ":" (or a folder ending in "/"),
#                   e.g. "secret:" or "secret:backups/"
# RUN_EVERY_HOURS   1 = every hourly run, 6 = every 6 hours, 12 = twice a day, 24 = daily.
#                   Counted from the last SUCCESSFUL backup; a failed backup is retried next run.
# MOUNT_POINT       where this remote is mounted on this server - exactly the path used in your
#                   rclone mount command (e.g. "/mnt/cache/remoteshare"). If it isn't mounted
#                   anywhere, use MOUNT_POINT="" and MOUNT_CHECK="false".
# MOUNT_CHECK       "true" / "false" for this remote only; overrides the default from section 3.
#                   false = no mount warnings and deletions are never paused for the mount. Keep
#                   MOUNT_POINT filled in even then, so no job can be pointed at the mount.
#
# JOBS              what to back up, one line each: "local folder|destination|mode"
#   destination     folder on the remote (the path after the mount point)
#   mode = copy     new files uploaded; a modified file's old version moved to _archive/<timestamp>/;
#                   deleted files: NOTHING happens on the remote - the remote copy stays forever.
#   mode = sync     as copy, but a deleted file's remote copy is MOVED to
#                   _archive/deleted/<destination>/<same folders>/name_DELETED_<date>_<time>.ext
#                   and purged DELETED_RETENTION_DAYS later.
#   Rules (checked before every run; a remote that breaks one is skipped, with an alert saying
#   how to fix it): each destination is its own folder - no two jobs on the same remote may
#   share a destination or nest one inside another; no source folder may be inside, or contain,
#   any remote's MOUNT_POINT (including its /mnt/user/... name for folders on a pool or disk).
#
# BANDWIDTH_LIMIT   "on" to apply BANDWIDTH_SCHEDULE, "off" for unlimited.
# BANDWIDTH_SCHEDULE  one line per speed change: "days  start-time  speed"
#   days    Daily | Weekdays | Weekends | Mon | Mon-Fri | Mon,Wed,Fri | Fri-Mon (ranges can wrap)
#   time    24-hour HH:MM at which this speed starts
#   speed   megabits per second (e.g. 20 or 2.5), or "unlimited"
#   A speed stays in force until the next change - overnight and into the next day if needed.
#   Example: 20 Mbps office hours, 50 Mbps evenings, unlimited overnight and at weekends:
#       BANDWIDTH_SCHEDULE=(
#           "Mon-Fri  06:00  20"
#           "Mon-Fri  18:00  50"
#           "Mon-Fri  23:00  unlimited"
#           "Sat-Sun  00:00  unlimited"
#       )
#   Example: one fixed limit all the time:   BANDWIDTH_SCHEDULE=( "Daily  00:00  40" )
#
# Any setting from section 3 can be set inside a block, for that remote only - e.g. MOUNT_CHECK,
# BANDWIDTH_LIMIT, DELETED_RETENTION_DAYS or MAX_DELETES_PER_JOB. Everything else uses the default.

remote_primary() {
    REMOTE="secret:"
    RUN_EVERY_HOURS=1
    MOUNT_POINT="/mnt/cache/remoteshare"
    MOUNT_CHECK="true"              # same as the default; shown here so it is easy to change
    JOBS=(
        "/mnt/user/sharepath1|sharepath1|copy"
        "/mnt/user/sharepath2|sharepath2|sync"
        "/mnt/user/sharepath3|nestedpath/sharepath3|copy"
    )
    BANDWIDTH_LIMIT="off"           # schedule below is kept ready; set "on" to use it
    BANDWIDTH_SCHEDULE=(
        "Weekdays  06:00  20"
        "Weekdays  20:00  unlimited"
        "Weekends  00:00  unlimited"
    )
}

remote_offsite() {
    REMOTE="secret2:"
    RUN_EVERY_HOURS=12
    MOUNT_POINT="/mnt/cache/remoteshare2"
    MOUNT_CHECK="false"             # overrides the default for this remote only
    JOBS=(
        "/mnt/user/sharepath1|sharepath1|copy"
        "/mnt/user/sharepath2|sharepath2|sync"
    )
    BANDWIDTH_LIMIT="on"
    BANDWIDTH_SCHEDULE=(
        "Daily  06:00  10"
        "Daily  20:00  50"
    )
}

######################################## CONFIG END ##########################################
# Nothing below needs editing.

STATE_DIR="$(dirname "$LOG_FILE")/state"
RUN_STATE="${STATE_DIR}/run-in-progress"
STUCK_ALERT="${STATE_DIR}/last-stuck-alert"
GLOBAL_GOTIFY_STATE="${STATE_DIR}/global.last-gotify-alert"
ARRAY_ALERT="${LOCK_FILE%.lock}.array-alert"     # next to the lock, in RAM: the array (and STATE_DIR) may be down
PARTIAL_GLOB='*.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].partial'   # rclone's leftover partial uploads
DAY_NAMES=(Mon Tue Wed Thu Fri Sat Sun)

HOST="$(hostname)"
PREFIX=""
[[ "$DRY_RUN" == "true" ]] && PREFIX="[DRY RUN] "
CURRENT_REMOTE=""
ERRORS=(); WARNINGS=(); G_ERRORS=(); G_WARNINGS=()
PAUSE_REASONS=(); GLOBAL_PAUSE_REASONS=()

# ======================================= Helpers =======================================
CHECK_ONLY=0        # set by --check-config: print only, never write to the log
log() {
    local line tag=""
    [[ -n "$CURRENT_REMOTE" ]] && tag="[${CURRENT_REMOTE}] "
    line="[$(date '+%F %T')] ${tag}$*"
    if (( CHECK_ONLY )); then
        echo "$line"
    elif [ -d "$STATE_DIR" ]; then
        echo "$line" | tee -a "$LOG_FILE"
    else
        echo "$line"
        logger -t rclone-backup -- "${tag}$*" 2>/dev/null
    fi
}
warn() { log "WARNING: $*"; if [[ -n "$CURRENT_REMOTE" ]]; then WARNINGS+=("$*"); else G_WARNINGS+=("$*"); fi; }
err()  { log "ERROR: $*";   if [[ -n "$CURRENT_REMOTE" ]]; then ERRORS+=("$*");   else G_ERRORS+=("$*");   fi; }
rc()   { rclone --config "$RCLONE_CONF" "$@"; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_bool() { [[ "$1" == "true" || "$1" == "false" ]]; }

# "/a//b/" -> "a/b"
norm_path() {
    local p="$1"
    while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
    p="${p#/}"
    printf '%s' "${p%/}"
}

log_size() { stat -c %s "$LOG_FILE" 2>/dev/null || echo 0; }

# ================================= Bandwidth schedule ==================================
# Turn "Mon-Fri" / "Daily" / "Mon,Wed,Fri" / "Fri-Mon" into day numbers 0-6 (Mon=0)
expand_days() {
    local spec="${1,,}" part a b i idx_a idx_b
    local -a day_nums=() parts=()
    local -A num=([mon]=0 [tue]=1 [wed]=2 [thu]=3 [fri]=4 [sat]=5 [sun]=6)
    case "$spec" in
        daily|everyday) echo "0 1 2 3 4 5 6"; return 0 ;;
        weekdays)       echo "0 1 2 3 4";     return 0 ;;
        weekends)       echo "5 6";           return 0 ;;
    esac
    IFS=',' read -ra parts <<< "$spec"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            a="${part%-*}"; b="${part#*-}"
            [[ -n "${num[$a]+x}" && -n "${num[$b]+x}" ]] || return 1
            idx_a=${num[$a]}; idx_b=${num[$b]}
            i=$idx_a
            while :; do day_nums+=("$i"); (( i == idx_b )) && break; i=$(( (i + 1) % 7 )); done
        else
            [[ -n "${num[$part]+x}" ]] || return 1
            day_nums+=("${num[$part]}")
        fi
    done
    (( ${#day_nums[@]} )) || return 1
    echo "${day_nums[*]}"
}

# Build rclone's --bwlimit timetable from BANDWIDTH_SCHEDULE into BW_RESULT; on a bad line
# sets BW_ERROR and returns 1. Mbps -> KiB/s: Mbps * 1,000,000 / 8 / 1024.
bw_timetable() {
    local line days time speed rest d val hh mm out="" key
    local -A seen=()
    BW_ERROR=""; BW_RESULT=""
    for line in "${BANDWIDTH_SCHEDULE[@]}"; do
        read -r days time speed rest <<< "$line"
        [[ -z "$days" ]] && continue
        if [[ -z "$speed" || -n "$rest" ]]; then
            BW_ERROR="bandwidth line '$line' must be: days  HH:MM  speed"; return 1
        fi
        local day_list
        if ! day_list="$(expand_days "$days")"; then
            BW_ERROR="bandwidth line '$line': unknown days '$days' (use Daily, Weekdays, Weekends, Mon, Mon-Fri or Mon,Wed,Fri)"; return 1
        fi
        if [[ ! "$time" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
            BW_ERROR="bandwidth line '$line': time '$time' must be 24-hour HH:MM"; return 1
        fi
        hh=$(printf '%02d' "$((10#${BASH_REMATCH[1]}))"); mm="${BASH_REMATCH[2]}"
        case "${speed,,}" in
            unlimited|off) val="off" ;;
            *)
                if [[ ! "$speed" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v s="$speed" 'BEGIN { exit !(s > 0) }'; then
                    BW_ERROR="bandwidth line '$line': speed '$speed' must be Mbps above 0 (e.g. 20 or 2.5) or 'unlimited'"; return 1
                fi
                val="$(awk -v s="$speed" 'BEGIN { k = int(s * 1000000 / 8 / 1024 + 0.5); if (k < 1) k = 1; print k "k" }')"
                ;;
        esac
        for d in $day_list; do
            key="${DAY_NAMES[$d]}-${hh}:${mm}"
            if [[ -n "${seen[$key]+x}" ]]; then
                BW_ERROR="bandwidth schedule sets ${key} twice"; return 1
            fi
            seen[$key]=1
            out+="${key},${val} "
        done
    done
    if [[ -z "$out" ]]; then BW_ERROR="BANDWIDTH_LIMIT is on but BANDWIDTH_SCHEDULE is empty"; return 1; fi
    BW_RESULT="${out% }"
}

# ===================================== Profiles ========================================
reset_profile() {
    REMOTE=""; RUN_EVERY_HOURS=""; MOUNT_POINT=""; JOBS=()
    VERSIONING="true"; SKIP_EXISTING="false"; ARCHIVE_DIR="_archive"; DELETED_SUBDIR="deleted"
    DELETED_RETENTION_DAYS=30; PURGE_WARNING_DAYS=3; MAX_DELETES_PER_JOB=500; CANARY_FILE=".backup-canary"
    MOUNT_CHECK="true"; PAUSE_SYNC_DELETES_IF_UNMOUNTED="true"
    BANDWIDTH_LIMIT="off"; BANDWIDTH_SCHEDULE=(); RCLONE_EXTRA_FLAGS=()
}

load_profile() {
    reset_profile
    declare -F defaults >/dev/null && defaults
    "remote_$1"
}

# ============================ Path checks (mounts / aliases) ===========================
pool_names() {
    local f
    for f in "$UNRAID_POOLS_DIR"/*.cfg; do [ -e "$f" ] && basename "$f" .cfg; done
}

# The same Unraid folder has several names: /mnt/cache/X, /mnt/disk1/X and /mnt/user/X.
# Map any of them to "@shares/X" so they can be compared ("@shares" alone = all shares).
share_key() {
    local p first rest
    p="/$(norm_path "$1")"
    [[ "$p" =~ ^/mnt/([^/]+)(/(.*))?$ ]] || return 0
    first="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[3]}"
    if [[ "$first" == "user" || "$first" == "user0" || "$first" =~ ^disk[0-9]+$ || " $ALIAS_POOLS " == *" $first "* ]]; then
        [[ -n "$rest" ]] && printf '@shares/%s' "$rest" || printf '@shares'
    fi
}

within() { [[ "$1" == "$2" || "$1" == "$2/"* ]]; }   # is $1 equal to, or inside, $2 ?

# Prints "inside" or "contains" if the source and a mount point overlap (by path or Unraid alias)
mount_overlap() {
    local src="$1" mnt="$2" ks km
    within "$src" "$mnt" && { echo inside; return; }
    within "$mnt" "$src" && { echo contains; return; }
    ks="$(share_key "$src")"; km="$(share_key "$mnt")"
    if [[ -n "$ks" && -n "$km" ]]; then
        within "$ks" "$km" && { echo inside; return; }
        within "$km" "$ks" && { echo contains; return; }
    fi
}

# =================================== Config checks =====================================
# Pre-pass over every remote: collects all mount points and destinations, then checks each
# remote. Sets PROFILE_PROBLEMS[name] (empty = valid). Problems with the list itself abort.
declare -A PROFILE_PROBLEMS=()
declare -A PROFILE_TIMETABLE=()
validate_all() {
    local name n i j job src dest mode s m kind p
    local -a all_mounts=() all_mount_owner=() d_remote=() d_dest=() d_owner=() d_job=()
    local -A seen_names=()
    POOLS="$(pool_names | tr '\n' ' ')"            # real pools, checked for health
    ALIAS_POOLS="$POOLS"                            # pools used when comparing paths
    [[ -z "${POOLS// }" ]] && ALIAS_POOLS="cache"   # no pool files found: assume the usual "cache"

    local g bad=0
    for g in CHECK_TIMEOUT STUCK_RUN_HOURS LOG_WARN_SIZE_MB CLEANUP_INTERVAL_HOURS DUE_GRACE_MINUTES \
             GOTIFY_REPEAT_HOURS GOTIFY_MAX_RCLONE_LINES GOTIFY_MAX_ARCHIVED_LINES; do
        is_uint "${!g}" || { err "Config: $g '${!g}' must be a whole number (0 or more)."; bad=1; }
    done
    for g in DRY_RUN ARRAY_CHECK GOTIFY_ENABLED GOTIFY_NOTIFY_SUCCESS; do
        is_bool "${!g}" || { err "Config: $g '${!g}' must be \"true\" or \"false\"."; bad=1; }
    done
    (( bad )) && return 1
    if (( ${#REMOTES[@]} == 0 )); then
        err "Config: REMOTES is empty. Fix: list at least one remote, e.g. REMOTES=(\"main\")."
        return 1
    fi
    for name in "${REMOTES[@]}"; do
        if [[ ! "$name" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
            err "Config: remote name '$name' is not allowed. Fix: letters, digits and underscores only, starting with a letter."
            return 1
        fi
        if [[ -n "${seen_names[$name]+x}" ]]; then
            err "Config: remote '$name' is listed twice in REMOTES. Fix: list each remote once."
            return 1
        fi
        seen_names[$name]=1
        if ! declare -F "remote_$name" >/dev/null; then
            err "Config: REMOTES lists '$name' but there is no remote_$name block. Fix: add the block in section 4, or remove '$name' from REMOTES."
            return 1
        fi
    done

    # Gather mounts and destinations from every remote
    for name in "${REMOTES[@]}"; do
        load_profile "$name"
        if [[ -n "$MOUNT_POINT" ]]; then
            all_mounts+=("/$(norm_path "$MOUNT_POINT")"); all_mount_owner+=("$name")
        fi
        for job in "${JOBS[@]}"; do
            IFS='|' read -r src dest mode <<< "$job"
            d_remote+=("$REMOTE"); d_dest+=("$(norm_path "$dest")"); d_owner+=("$name"); d_job+=("$job")
        done
    done

    for name in "${REMOTES[@]}"; do
        load_profile "$name"
        local -a probs=()

        if [[ -z "$REMOTE" ]]; then
            probs+=("REMOTE is empty. Fix: set the rclone remote, e.g. REMOTE=\"secret:\".")
        elif [[ "$REMOTE" != *: && "$REMOTE" != */ ]]; then
            probs+=("REMOTE '$REMOTE' must end in ':' or '/'. Fix: e.g. \"secret:\" or \"secret:backups/\".")
        fi
        if ! is_uint "$RUN_EVERY_HOURS" || (( RUN_EVERY_HOURS < 1 )); then
            probs+=("RUN_EVERY_HOURS '$RUN_EVERY_HOURS' must be a whole number of hours, 1 or more.")
        fi
        for p in DELETED_RETENTION_DAYS PURGE_WARNING_DAYS MAX_DELETES_PER_JOB; do
            is_uint "${!p}" || probs+=("$p '${!p}' must be a whole number (0 or more).")
        done
        for p in VERSIONING SKIP_EXISTING MOUNT_CHECK PAUSE_SYNC_DELETES_IF_UNMOUNTED; do
            is_bool "${!p}" || probs+=("$p '${!p}' must be \"true\" or \"false\".")
        done
        for p in ARCHIVE_DIR DELETED_SUBDIR CANARY_FILE; do
            if [[ -z "${!p}" || "${!p}" == */* ]]; then
                probs+=("$p '${!p}' must be a single folder or file name (not empty, no slashes).")
            fi
        done
        for p in "${RCLONE_EXTRA_FLAGS[@]}"; do
            case "$p" in
                --backup-dir|--backup-dir=*|--suffix|--suffix=*|--suffix-keep-extension|--max-delete|--max-delete=*|\
                --delete-*|--dry-run|--inplace|--partial-suffix|--partial-suffix=*|--files-from*|--ignore-existing|--immutable)
                    probs+=("RCLONE_EXTRA_FLAGS contains '$p', which would change how files are archived or deleted. Fix: remove it; the script sets these itself.") ;;
            esac
        done
        if [[ "$MOUNT_CHECK" == "true" && -z "$MOUNT_POINT" ]]; then
            probs+=("MOUNT_CHECK is true but MOUNT_POINT is empty. Fix: set MOUNT_POINT, or MOUNT_CHECK=\"false\" if this remote isn't mounted.")
        fi
        case "$BANDWIDTH_LIMIT" in
            on)  if bw_timetable; then PROFILE_TIMETABLE[$name]="$BW_RESULT"; else probs+=("$BW_ERROR."); fi ;;
            off) PROFILE_TIMETABLE[$name]="" ;;
            *)   probs+=("BANDWIDTH_LIMIT '$BANDWIDTH_LIMIT' must be \"on\" or \"off\".") ;;
        esac
        (( ${#JOBS[@]} )) || probs+=("JOBS is empty. Fix: add at least one \"local folder|destination|mode\" line.")

        for job in "${JOBS[@]}"; do
            IFS='|' read -r src dest mode <<< "$job"
            mode="${mode:-copy}"; dest="$(norm_path "$dest")"
            [[ "$mode" == "copy" || "$mode" == "sync" ]] || probs+=("Job '$job' has an unknown mode '$mode'. Fix: use copy or sync, with no spaces.")
            if [[ -z "$dest" ]]; then
                probs+=("Job '$job' has no destination. Fix: add the remote folder, e.g. \"$src|foldername|$mode\".")
            elif within "$dest" "$ARCHIVE_DIR"; then
                probs+=("Job '$job' points inside $ARCHIVE_DIR. Fix: choose a destination outside $ARCHIVE_DIR.")
            fi
            s="$(timeout -k 5 10 realpath -m "$src" 2>/dev/null || echo "/$(norm_path "$src")")"
            for (( i = 0; i < ${#all_mounts[@]}; i++ )); do
                m="${all_mounts[i]}"
                kind="$(mount_overlap "$s" "$m")"
                if [[ "$kind" == "inside" ]]; then
                    probs+=("Job '$job': the source is inside the mount $m (remote '${all_mount_owner[i]}'). Fix: point the job at the local folder that holds the original files.")
                elif [[ "$kind" == "contains" ]]; then
                    probs+=("Job '$job': the source contains the mount $m (remote '${all_mount_owner[i]}'), so a remote would be backed up into itself. Fix: use a narrower source folder.")
                fi
            done
        done

        # Destination overlaps: within this remote, and with other remotes using the same REMOTE
        n=${#d_dest[@]}
        for (( i = 0; i < n; i++ )); do
            [[ "${d_owner[i]}" == "$name" ]] || continue
            for (( j = 0; j < n; j++ )); do
                (( i == j )) && continue
                [[ "${d_remote[j]}" == "${d_remote[i]}" ]] || continue
                [[ -z "${d_dest[i]}" || -z "${d_dest[j]}" ]] && continue
                [[ "${d_owner[j]}" == "$name" ]] && (( j < i )) && continue   # report each pair once
                if [[ "${d_dest[i]}" == "${d_dest[j]}" ]]; then
                    probs+=("Jobs '${d_job[i]}' and '${d_job[j]}' (remote '${d_owner[j]}') both use ${d_remote[i]}${d_dest[i]}. Fix: give each job its own destination folder, or combine them.")
                elif within "${d_dest[j]}" "${d_dest[i]}" || within "${d_dest[i]}" "${d_dest[j]}"; then
                    probs+=("Destinations overlap on ${d_remote[i]}: '${d_dest[i]}' (job '${d_job[i]}') and '${d_dest[j]}' (job '${d_job[j]}', remote '${d_owner[j]}'). A sync job would archive the other job's files every run. Fix: use side-by-side folders (e.g. 'photos' and 'photos-2024').")
                fi
            done
        done

        local joined=""
        for p in "${probs[@]}"; do joined+="$p"$'\n'; done
        PROFILE_PROBLEMS[$name]="${joined%$'\n'}"
    done
    return 0
}

# ===================================== Gotify ==========================================
send_gotify() {
    [[ "$GOTIFY_ENABLED" == "true" ]] || return 0
    local title="$1" msg="$2" prio="$3" code
    code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
        -H "X-Gotify-Key: ${GOTIFY_TOKEN}" \
        --form-string "title=${title}" \
        --form-string "message=${msg}" \
        --form-string "priority=${prio}" \
        "${GOTIFY_URL%/}/message" 2>/dev/null)
    if [[ "$code" != "200" ]]; then
        log "Gotify: failed to send notification (HTTP ${code:-no response})"
        return 1
    fi
    return 0
}

alert_once() {   # send at most once per GOTIFY_REPEAT_HOURS, using a marker file's age
    local marker="$1" title="$2" msg="$3" prio="$4"
    if (( GOTIFY_REPEAT_HOURS > 0 )) && \
       [ -n "$(find "$marker" -mmin -$(( GOTIFY_REPEAT_HOURS * 60 )) 2>/dev/null)" ]; then
        return 0
    fi
    send_gotify "$title" "$msg" "$prio" && touch "$marker"
}

# One summary per scope (the whole run, or one remote): errors 8, warnings 5, recovery 4, success 2.
#   report <title suffix> <state file> <log offset for rclone errors, or "">
report() {
    [[ "$GOTIFY_ENABLED" == "true" ]] || return 0
    local suffix="$1" state="$2" start="$3"
    local title prio msg rclone_errs="" rclone_count=0 line hash now last_time last_hash

    if [[ -n "$start" ]]; then
        rclone_errs=$(tail -c +$(( start + 1 )) "$LOG_FILE" 2>/dev/null | grep ' ERROR : ')
        [ -n "$rclone_errs" ] && rclone_count=$(printf '%s\n' "$rclone_errs" | wc -l)
    fi

    if (( ${#ERRORS[@]} )); then
        title="${PREFIX}Backup FAILED on ${HOST}${suffix}"; prio=8
    elif (( ${#WARNINGS[@]} || rclone_count )); then
        title="${PREFIX}Backup warnings on ${HOST}${suffix}"; prio=5
    else
        if [ -f "$state" ]; then
            send_gotify "${PREFIX}Backup recovered on ${HOST}${suffix}" "Run ${RUN_STAMP} completed with no errors or warnings." 4 \
                && rm -f "$state"
        elif [[ "$GOTIFY_NOTIFY_SUCCESS" == "true" && -n "$suffix" ]]; then
            send_gotify "${PREFIX}Backup OK on ${HOST}${suffix}" "Run ${RUN_STAMP} completed with no errors or warnings." 2
        fi
        return 0
    fi

    msg="Run ${RUN_STAMP}"$'\n'
    for line in "${ERRORS[@]}";   do msg+=$'\n'"ERROR: ${line}"$'\n'; done
    for line in "${WARNINGS[@]}"; do msg+=$'\n'"WARNING: ${line}"$'\n'; done
    if (( rclone_count )); then
        msg+=$'\n'"rclone reported ${rclone_count} error(s)"
        (( rclone_count > GOTIFY_MAX_RCLONE_LINES )) && msg+=" (first ${GOTIFY_MAX_RCLONE_LINES} shown)"
        msg+=":"$'\n'"$(printf '%s\n' "$rclone_errs" | head -n "$GOTIFY_MAX_RCLONE_LINES")"$'\n'
    fi
    msg+=$'\n'"Full log: ${LOG_FILE}"

    # Only numbers that grow while a problem persists are ignored when comparing alerts.
    hash=$(printf '%s\n' "$title" "${ERRORS[@]}" "${WARNINGS[@]}" \
        | sed -E 's/\([0-9]+ consecutive run\(s\)\)/(N consecutive run(s))/g;
                  s/ is [0-9]+ MB / is N MB /g;
                  s/took [0-9]+ minutes/took N minutes/g;
                  s/[0-9]+ scheduled run\(s\)/N scheduled run(s)/g' \
        | md5sum | cut -d' ' -f1)
    now=$(date +%s)
    if (( GOTIFY_REPEAT_HOURS > 0 )) && [ -f "$state" ]; then
        read -r last_time last_hash < "$state"
        if [[ "$hash" == "$last_hash" ]] && (( now - ${last_time:-0} < GOTIFY_REPEAT_HOURS * 3600 )); then
            log "Gotify: same alert already sent within ${GOTIFY_REPEAT_HOURS}h - not resending"
            return 0
        fi
    fi
    send_gotify "$title" "$msg" "$prio" && echo "$now $hash" > "$state"
}

# "Files archived" message for one remote. Uploads and version moves never send anything.
archive_notice() {
    [[ "$GOTIFY_ENABLED" == "true" ]] || return 0
    [ -s "$ARCHIVED_LIST" ] || return 0
    local n title msg until
    n=$(wc -l < "$ARCHIVED_LIST")
    if [[ "$DRY_RUN" == "true" ]]; then
        title="${PREFIX}Files would be archived on ${HOST} (${CURRENT_REMOTE})"
        msg="${n} file(s) deleted locally would be moved to ${REMOTE}${ARCHIVE_DIR}/${DELETED_SUBDIR} (dry run, nothing changed):"
    else
        title="Files archived on ${HOST} (${CURRENT_REMOTE})"
        msg="${n} file(s) deleted locally were moved to ${REMOTE}${ARCHIVE_DIR}/${DELETED_SUBDIR} in run ${RUN_STAMP}:"
    fi
    msg+=$'\n'"$(head -n "$GOTIFY_MAX_ARCHIVED_LINES" "$ARCHIVED_LIST" | sed 's/^/  /')"
    (( n > GOTIFY_MAX_ARCHIVED_LINES )) && msg+=$'\n'"  ... and $(( n - GOTIFY_MAX_ARCHIVED_LINES )) more (see ${LOG_FILE})"
    msg+=$'\n\n'"Each is stored under ${ARCHIVE_DIR}/${DELETED_SUBDIR}/<same folder> as name_DELETED_${RUN_STAMP}.ext."
    if (( DELETED_RETENTION_DAYS > 0 )); then
        until=$(date -d "@$(( RUN_START + DELETED_RETENTION_DAYS * 86400 ))" '+%F')
        msg+=" They will be permanently deleted after ${until} (${DELETED_RETENTION_DAYS} days) unless copied back into the watch folder."
    fi
    send_gotify "$title" "$msg" 4
}

# =================================== Global checks =====================================
ini_val() { sed -nE "s/^$1=\"?([^\"]*)\"?\$/\1/p" "$UNRAID_VAR_INI" 2>/dev/null | head -n 1; }

check_array_started() {
    [[ "$ARRAY_CHECK" == "true" ]] || return 0
    local state
    if [ ! -r "$UNRAID_VAR_INI" ]; then
        ARRAY_PROBLEM="Can't read ${UNRAID_VAR_INI} to check the Unraid array, so nothing was run. If this isn't an Unraid server, set ARRAY_CHECK=\"false\"."
        return 1
    fi
    state="$(ini_val mdState)"
    if [[ "$state" != "STARTED" ]]; then
        ARRAY_PROBLEM="The Unraid array is not started (state: ${state:-unknown}). Nothing was uploaded, moved or purged. Start the array from the Main tab; the next scheduled run will continue normally."
        return 1
    fi
    if ! timeout -k 5 "$CHECK_TIMEOUT" mountpoint -q /mnt/user; then
        ARRAY_PROBLEM="The array is started but /mnt/user (user shares) is not mounted, so nothing was run. Check the Main tab and Settings > Global Share Settings."
        return 1
    fi
    return 0
}

check_array_health() {
    [[ "$ARRAY_CHECK" == "true" ]] || return 0
    local key val pool problems=()
    for key in mdNumMissing mdNumDisabled mdNumInvalid fsNumUnmountable; do
        val="$(ini_val "$key")"
        [[ "$val" =~ ^[0-9]+$ ]] && (( val > 0 )) && problems+=("${key}=${val}")
    done
    for pool in $POOLS; do
        timeout -k 5 "$CHECK_TIMEOUT" mountpoint -q "/mnt/${pool}" || problems+=("pool '${pool}' not mounted")
    done
    if (( ${#problems[@]} )); then
        GLOBAL_PAUSE_REASONS+=("array degraded")
        warn "The Unraid array is degraded (${problems[*]}). Files on an affected disk or pool may be missing from user shares, so no remote will archive deletions until this is fixed. Uploads continue. Check the Main tab."
    fi
}

check_log_size() {
    (( LOG_WARN_SIZE_MB > 0 )) || return 0
    local mb=$(( $(log_size) / 1048576 ))
    if (( mb >= LOG_WARN_SIZE_MB )); then
        warn "The log file ${LOG_FILE} is ${mb} MB (warning level ${LOG_WARN_SIZE_MB} MB). Clear it while no backup is running with: truncate -s 0 \"${LOG_FILE}\""
    fi
}

check_stuck_run() {
    local started pid skipped age
    [ -r "$RUN_STATE" ] || return 0
    read -r started pid skipped < "$RUN_STATE"
    [[ "$started" =~ ^[0-9]+$ ]] || return 0
    skipped=$(( ${skipped:-0} + 1 ))
    echo "$started $pid $skipped" > "$RUN_STATE"
    age=$(( $(date +%s) - started ))
    (( age >= STUCK_RUN_HOURS * 3600 )) || return 0
    log "WARNING: run started $(date -d "@$started" '+%F %T') (PID $pid) still going after $(( age / 3600 ))h"
    alert_once "$STUCK_ALERT" "${PREFIX}Backup stuck on ${HOST}" \
"The backup run that started $(date -d "@$started" '+%F %T') (PID ${pid}) is still running after $(( age / 3600 )) hours. ${skipped} scheduled run(s) have been skipped.

It may just be a very large upload. To check:
  tail -n 50 ${LOG_FILE}
  pgrep -a rclone

If nothing is moving, stop it with: kill ${pid}  (and any rclone processes it started).
The next scheduled run will carry on where it left off." 8
}

# ================================ Per-remote checks ====================================
check_remote() {
    local out
    out=$(timeout -k 5 "$CHECK_TIMEOUT" rclone --config "$RCLONE_CONF" lsf "${REMOTE}${CANARY_FILE}" 2>>"$LOG_FILE")
    if [[ "$out" != "$CANARY_FILE" ]]; then
        err "Canary ${REMOTE}${CANARY_FILE} not found - remote unreachable, wrong remote, or canary not created (rclone touch ${REMOTE}${CANARY_FILE}). This remote was skipped, no changes made."
        return 1
    fi
    return 0
}

mount_listed() {   # reads /proc only, so it can't hang
    local m
    m="/$(norm_path "$MOUNT_POINT")"
    M="${m// /\\040}" awk '$2 == ENVIRON["M"] { f = 1 } END { exit !f }' /proc/self/mounts
}

check_mount() {
    [[ "$MOUNT_CHECK" == "true" && -n "$MOUNT_POINT" ]] || return 0
    local mount_ok=1 out code since count hung_state="${STATE_DIR}/${CURRENT_REMOTE}.mount-hung-since"

    if ! mount_listed; then
        mount_ok=0
        rm -f "$hung_state"
        warn "$MOUNT_POINT is not mounted."
        if [ -d "$MOUNT_POINT" ] && [ -n "$(timeout -k 5 30 find "$MOUNT_POINT" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            warn "Files exist in $MOUNT_POINT on the LOCAL drive. They are NOT on the remote and are not backed up. Move them somewhere safe before remounting, or the mount will hide them."
        fi
    else
        out=$(timeout -k 5 "$CHECK_TIMEOUT" stat "${MOUNT_POINT}/${CANARY_FILE}" 2>&1 >/dev/null)
        code=$?
        if (( code == 0 )); then
            rm -f "$hung_state"
        elif (( code == 124 || code == 137 )) || [[ "$out" == *"not connected"* ]]; then
            mount_ok=0
            since=""; count=0
            [ -r "$hung_state" ] && read -r since count < "$hung_state"
            [[ "$since" =~ ^[0-9]+$ ]] || { since=$(date +%s); count=0; }
            count=$(( count + 1 ))
            echo "$since $count" > "$hung_state"
            warn "Mount $MOUNT_POINT is hung/frozen since $(date -d "@$since" '+%F %T') (${count} consecutive run(s)). Fix: run 'fusermount -uz $MOUNT_POINT', then start your rclone mount again."
        else
            mount_ok=0
            rm -f "$hung_state"
            warn "$MOUNT_POINT is mounted but ${CANARY_FILE} is not visible (wrong or stale mount)."
        fi
    fi

    if (( ! mount_ok )) && [[ "$PAUSE_SYNC_DELETES_IF_UNMOUNTED" == "true" ]]; then
        PAUSE_REASONS+=("mount not available")
        log "         Uploads continue; sync jobs will not archive deletions this run."
    fi
}

# =================================== Job actions =======================================
upload_job() {   # step 1 for every job: upload new files, version modified ones
    local src="$1" dest="$2" flags=()
    if [[ "$VERSIONING" == "true" ]]; then
        flags+=(--backup-dir "${REMOTE}${ARCHIVE_DIR}/${RUN_STAMP}/${dest}")
    elif [[ "$SKIP_EXISTING" == "true" ]]; then
        flags+=(--ignore-existing)
    fi
    rc copy "$src" "${REMOTE}${dest}" "${BW_FLAGS[@]}" "${RCLONE_EXTRA_FLAGS[@]}" "${flags[@]}" \
        --log-file "$LOG_FILE" --log-level INFO "${DRY_FLAG[@]}"
}

# Leftover "name.<8 hex>.partial" files from interrupted uploads are deleted, not archived.
# A file only counts as a leftover if it is over an hour old and has no local file of the same name.
clean_partials() {
    local src="$1" dest="$2" list="$WORK/partials.lst" keep="$WORK/partials.del" path
    rc lsf -R --files-only --include "$PARTIAL_GLOB" --min-age 1h "${REMOTE}${dest}" > "$list" 2>/dev/null || return 0
    : > "$keep"
    while IFS= read -r path; do
        [ -e "${src}/${path}" ] || printf '%s\n' "$path" >> "$keep"
    done < "$list"
    [ -s "$keep" ] || return 0
    log "  Removing $(wc -l < "$keep") leftover partial upload(s) from interrupted transfers in ${REMOTE}${dest}"
    rc delete "${REMOTE}${dest}" --files-from-raw "$keep" --log-file "$LOG_FILE" --log-level INFO "${DRY_FLAG[@]}"
}

# Step 2 for sync jobs: remote files that no longer exist locally are moved to
# _archive/deleted/<dest>/<same path>, renamed name_DELETED_<RUN_STAMP>.ext
sync_deletions() {
    local src="$1" dest="$2" code n job_log="$WORK/sync-job.log"
    : > "$job_log"

    # Guard against an empty/unmounted local watch folder making everything look deleted
    if [ -z "$(find "$src" -mindepth 1 -type f -print -quit 2>/dev/null)" ]; then
        err "Deletion step skipped for $src - folder has no files (share not mounted?)"
        return 1
    fi

    clean_partials "$src" "$dest"

    local args=(
        --ignore-existing                           # step 1 already handled changes; only deletions here
        --exclude "$PARTIAL_GLOB"                   # partial uploads are never archived
        --backup-dir "${DELETED_ROOT}/${dest}"      # "deleted" files are moved here, never truly deleted
        --suffix "_DELETED_${RUN_STAMP}"
        --suffix-keep-extension                     # report.pdf -> report_DELETED_2026-10-07_140512.pdf
        --log-file "$job_log" --log-level INFO      # own log first, so archived files can be counted
        "${DRY_FLAG[@]}"
    )
    (( MAX_DELETES_PER_JOB > 0 )) && args+=(--max-delete "$MAX_DELETES_PER_JOB")

    # rclone sync skips all deletions if anything went wrong during the run.
    rc sync "$src" "${REMOTE}${dest}" "${BW_FLAGS[@]}" "${RCLONE_EXTRA_FLAGS[@]}" "${args[@]}"
    code=$?
    cat "$job_log" >> "$LOG_FILE"

    # Record what was actually archived (also when the max-delete limit stopped it part-way)
    sed -nE 's/^.* (INFO|NOTICE) *: (.*): (Moved into backup dir|Skipped move into backup dir as --dry-run is set).*$/\2/p' "$job_log" \
        | awk -v d="$dest" '{ print d "/" $0 }' >> "$ARCHIVED_LIST"
    n=$(grep -cE ': (Moved into backup dir|Skipped move into backup dir)' "$job_log")
    (( n > 0 )) && log "  Archived ${n} deleted file(s) to ${DELETED_ROOT}/${dest}"

    if (( code == 0 )); then
        return 0
    fi
    err "Deletion step for $src failed or hit MAX_DELETES_PER_JOB ($MAX_DELETES_PER_JOB)"
    return 1
}

# Countdown message: "3 day(s) until 12 archived file(s) will be deleted", plus what was purged
purge_notice() {
    local soon="$1" purged="$2" d n msg=""
    [[ "$GOTIFY_ENABLED" == "true" ]] || return 0
    [ -s "$soon" ] || (( purged > 0 )) || return 0
    if [ -s "$soon" ]; then
        msg="Deleted files in ${REMOTE}${ARCHIVE_DIR}/${DELETED_SUBDIR} that will be permanently removed:"$'\n'
        for (( d = PURGE_WARNING_DAYS; d >= 1; d-- )); do
            n=$(awk -F'\t' -v d="$d" '$1 == d' "$soon" | wc -l)
            (( n > 0 )) && msg+=$'\n'"  ${d} day(s) until ${n} archived file(s) will be deleted"
        done
        msg+=$'\n\n'"Due soonest (up to 10):"$'\n'"$(sort -n "$soon" | head -n 10 | cut -f2- | sed 's/^/  /')"
        msg+=$'\n\n'"To keep a file, copy it back into its local watch folder (removing the _DELETED_ stamp from the name) before then."
    fi
    if (( purged > 0 )); then
        [ -n "$msg" ] && msg+=$'\n\n'
        msg+="Permanently deleted this run: ${purged} file(s) older than ${DELETED_RETENTION_DAYS} days."
    fi
    send_gotify "${PREFIX}Archived files due for deletion on ${HOST} (${CURRENT_REMOTE})" "$msg" 5
}

# Purge ONLY files under _archive/deleted whose _DELETED_ stamp is older than the retention.
cleanup_deleted() {
    (( DELETED_RETENTION_DAYS > 0 )) || return 0
    local marker="${STATE_DIR}/${CURRENT_REMOTE}.last-deleted-cleanup"
    if [ -n "$(find "$marker" -mmin -$(( CLEANUP_INTERVAL_HOURS * 60 )) 2>/dev/null)" ]; then
        return 0
    fi
    local list="$WORK/deleted.lst" expired="$WORK/expired.lst" soon="$WORK/soon.lst"
    local code cuts="" d k purged=0

    # "directory not found" is normal before the first deletion and must not reach the log as an ERROR
    rc lsf -R --files-only --fast-list "$DELETED_ROOT" > "$list" 2> "$WORK/lsf.err"
    code=$?
    if (( code == 3 )); then
        log "Cleanup: ${DELETED_ROOT} not found yet - nothing to purge"
        [[ "$DRY_RUN" != "true" ]] && touch "$marker"
        return 0
    elif (( code != 0 )); then
        cat "$WORK/lsf.err" >> "$LOG_FILE"
        err "Could not list ${DELETED_ROOT} (rclone exit code ${code}). Purge skipped; it will be retried on the next run."
        return 1
    fi

    for (( d = 0; d <= PURGE_WARNING_DAYS; d++ )); do   # [1] = purge now, [d+1] = purge within d days
        k=$(( DELETED_RETENTION_DAYS - d )); (( k < 0 )) && k=0
        cuts+="$(date -d "-${k} days" '+%Y-%m-%d_%H%M%S') "
    done
    : > "$expired"; : > "$soon"
    sed -nE 's#^(.*_DELETED_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})[^/]*)$#\2\t\1#p' "$list" \
        | awk -F'\t' -v cuts="$cuts" -v ef="$expired" -v sf="$soon" '
            BEGIN { n = split(cuts, c, " ") }
            {
                s = $1; p = substr($0, index($0, "\t") + 1)
                if (s < c[1]) { print p > ef; next }
                for (i = 2; i <= n; i++) if (s < c[i]) { print (i - 1) "\t" p > sf; break }
            }'

    if [ -s "$expired" ]; then
        purged=$(wc -l < "$expired")
        log "Cleanup: purging ${purged} file(s) deleted more than ${DELETED_RETENTION_DAYS} days ago"
        if rc delete "$DELETED_ROOT" --files-from-raw "$expired" --log-file "$LOG_FILE" --log-level INFO "${DRY_FLAG[@]}"; then
            [[ "$DRY_RUN" != "true" ]] && rc rmdirs "$DELETED_ROOT" --leave-root --log-file "$LOG_FILE" --log-level INFO
        else
            err "Purge of expired deleted files failed - will retry next run"
            return 1
        fi
    fi
    [[ "$DRY_RUN" != "true" ]] && touch "$marker"
    (( PURGE_WARNING_DAYS > 0 )) || : > "$soon"
    purge_notice "$soon" "$purged"
}

# ================================== One remote, start to finish ==================================
last_success() { cat "${STATE_DIR}/$1.last-success" 2>/dev/null; }

is_due() {
    local last; last="$(last_success "$1")"
    [[ "$last" =~ ^[0-9]+$ ]] || return 0
    (( RUN_START - last >= RUN_EVERY_HOURS * 3600 - DUE_GRACE_MINUTES * 60 ))
}

run_remote() {
    local name="$1" job src dest mode any_sync=0 reasons p
    CURRENT_REMOTE="$name"
    ERRORS=(); WARNINGS=(); PAUSE_REASONS=("${GLOBAL_PAUSE_REASONS[@]}")
    local start; start=$(log_size)
    load_profile "$name"
    DELETED_ROOT="${REMOTE}${ARCHIVE_DIR}/${DELETED_SUBDIR}"
    ARCHIVED_LIST="$WORK/${name}.archived"; : > "$ARCHIVED_LIST"
    BW_FLAGS=()
    [[ -n "${PROFILE_TIMETABLE[$name]}" ]] && BW_FLAGS=(--bwlimit "${PROFILE_TIMETABLE[$name]}")

    if [[ -n "${PROFILE_PROBLEMS[$name]}" ]]; then
        while IFS= read -r p; do err "Config: $p"; done <<< "${PROFILE_PROBLEMS[$name]}"
        log "Skipped - fix the settings in the remote_${name} block. No changes made."
    elif check_remote; then
        log "Backing up to ${REMOTE} (every ${RUN_EVERY_HOURS}h$( [[ ${#BW_FLAGS[@]} -gt 0 ]] && echo ", bandwidth schedule on"))"
        check_mount
        for job in "${JOBS[@]}"; do
            IFS='|' read -r src dest mode <<< "$job"
            mode="${mode:-copy}"; dest="$(norm_path "$dest")"
            if [ ! -d "$src" ]; then
                err "Job '$job' skipped - $src does not exist"
                continue
            fi
            log "Uploading $src -> ${REMOTE}${dest} [$mode]"
            if ! upload_job "$src" "$dest"; then
                err "Upload failed for $src -> ${REMOTE}${dest}"
                continue    # never process deletions for a job whose upload failed
            fi
            if [[ "$mode" == "sync" ]]; then
                any_sync=1
                if (( ${#PAUSE_REASONS[@]} )); then
                    reasons="$(printf '%s, ' "${PAUSE_REASONS[@]}")"
                    log "  Deletion step paused (${reasons%, }) - will catch up on a later run"
                else
                    sync_deletions "$src" "$dest"
                fi
            fi
        done
        (( any_sync )) && cleanup_deleted
    fi

    archive_notice
    report " (${name})" "${STATE_DIR}/${name}.last-gotify-alert" "$start"
    if (( ${#ERRORS[@]} )); then
        RUN_FAILED=1
    elif [[ "$DRY_RUN" != "true" ]]; then
        echo "$RUN_START" > "${STATE_DIR}/${name}.last-success"
    fi
    log "Done"
    CURRENT_REMOTE=""
}

finish() {
    local started pid skipped
    CURRENT_REMOTE=""
    [ -r "$RUN_STATE" ] && read -r started pid skipped < "$RUN_STATE"
    if (( ${skipped:-0} > 0 && $(date +%s) - RUN_START >= STUCK_RUN_HOURS * 3600 )); then
        warn "This run took $(( ($(date +%s) - RUN_START) / 60 )) minutes to finish; ${skipped} scheduled run(s) were skipped while it ran."
    fi
    rm -f "$RUN_STATE" "$STUCK_ALERT"
    ERRORS=("${G_ERRORS[@]}"); WARNINGS=("${G_WARNINGS[@]}")
    report "" "$GLOBAL_GOTIFY_STATE" ""
    (( ${#G_ERRORS[@]} )) && RUN_FAILED=1
    log "Backup finished"
    exit "$RUN_FAILED"
}

# ================================= --check-config ======================================
show_config() {
    local name job last ok=0 tt
    CHECK_ONLY=1
    RUN_START=$(date +%s)
    if ! validate_all; then return 1; fi
    echo "Checked $(( ${#REMOTES[@]} )) remote(s). Nothing was changed."
    for name in "${REMOTES[@]}"; do
        load_profile "$name"
        echo
        echo "== ${name} =="
        echo "  Remote:      ${REMOTE}   every ${RUN_EVERY_HOURS}h"
        last="$(last_success "$name")"
        if [[ -n "${PROFILE_PROBLEMS[$name]}" ]] || ! is_uint "$RUN_EVERY_HOURS"; then
            echo "  Last success: $( [[ "$last" =~ ^[0-9]+$ ]] && date -d "@$last" '+%F %T' || echo never )"
        elif [[ "$last" =~ ^[0-9]+$ ]]; then
            local due="now"
            is_due "$name" || due="$(date -d "@$(( last + RUN_EVERY_HOURS * 3600 - DUE_GRACE_MINUTES * 60 ))" '+from %F %H:%M')"
            echo "  Last success: $(date -d "@$last" '+%F %T');  due ${due}"
        else
            echo "  Last success: never;  due now"
        fi
        echo "  Mount:       ${MOUNT_POINT:-none} (check ${MOUNT_CHECK})"
        for job in "${JOBS[@]}"; do echo "  Job:         ${job}"; done
        if [[ "$BANDWIDTH_LIMIT" == "on" ]]; then
            echo "  Bandwidth:   on"
            for job in "${BANDWIDTH_SCHEDULE[@]}"; do echo "               ${job}"; done
            tt="${PROFILE_TIMETABLE[$name]}"
            [[ -n "$tt" ]] && echo "  rclone:      --bwlimit \"${tt}\""
        else
            echo "  Bandwidth:   off (unlimited)"
        fi
        if [[ -n "${PROFILE_PROBLEMS[$name]}" ]]; then
            ok=1
            echo "  PROBLEMS (this remote would be skipped):"
            printf '%s\n' "${PROFILE_PROBLEMS[$name]}" | sed 's/^/    - /'
        else
            echo "  OK"
        fi
    done
    return $ok
}

# ======================================== Main =========================================
MODE_ARG="normal"; ONLY=""
case "${1:-}" in
    "")             ;;
    --force)        MODE_ARG="force" ;;
    --only)         MODE_ARG="only"; ONLY="${2:-}" ;;
    --check-config) show_config; exit $? ;;
    *)              echo "Unknown option '$1'. Use --force, --only NAME or --check-config."; exit 2 ;;
esac

# 1. Array must be up before anything is written (the log lives on the array)
if ! check_array_started; then
    log "$ARRAY_PROBLEM"
    alert_once "$ARRAY_ALERT" "${PREFIX}Backup NOT run on ${HOST} - array not available" "$ARRAY_PROBLEM" 8
    exit 1
fi
rm -f "$ARRAY_ALERT"
mkdir -p "$STATE_DIR"

# 2. Single-instance lock (released automatically when a run ends or is killed)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Previous run still in progress - skipping this run."
    check_stuck_run
    exit 0
fi

WORK="$(mktemp -d /tmp/rclone-backup.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
RUN_START=$(date +%s)
RUN_STAMP="$(date -d "@$RUN_START" '+%Y-%m-%d_%H%M%S')"
RUN_FAILED=0
echo "$RUN_START $$ 0" > "$RUN_STATE"
DRY_FLAG=()
[[ "$DRY_RUN" == "true" ]] && DRY_FLAG=(--dry-run)

[[ "$DRY_RUN" == "true" ]] && log "Backup started (DRY RUN)"
[[ "$DRY_RUN" != "true" ]] && log "Backup started"

# 3. Global checks
check_log_size
if ! validate_all; then
    log "Backup aborted - fix the REMOTES list above. No changes made."
    finish
fi
if [[ "$MODE_ARG" == "only" ]] && [[ " ${REMOTES[*]} " != *" $ONLY "* ]]; then
    err "--only '$ONLY' is not in REMOTES (${REMOTES[*]})."
    finish
fi
check_array_health

# 4. Each remote in order, when due
for name in "${REMOTES[@]}"; do
    if [[ "$MODE_ARG" == "only" && "$name" != "$ONLY" ]]; then continue; fi
    load_profile "$name"
    if [[ "$MODE_ARG" == "normal" && -z "${PROFILE_PROBLEMS[$name]}" ]] && ! is_due "$name"; then
        CURRENT_REMOTE="$name"
        log "Not due yet (every ${RUN_EVERY_HOURS}h; last success $(date -d "@$(last_success "$name")" '+%F %T'))"
        CURRENT_REMOTE=""
        continue
    fi
    run_remote "$name"
done

finish
