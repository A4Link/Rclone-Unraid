#!/bin/bash
#
# test-rclone-backup.sh - static, unit and sandbox integration tests for rclone-backup.sh
#
# Usage:   bash test-rclone-backup.sh [/path/to/rclone-backup.sh]
#          KEEP=1 bash test-rclone-backup.sh      # keep the temp folder for inspection
#          REPORT=TEST-RESULTS.md bash test-rclone-backup.sh   # also write a Markdown results report
#
# Safe to run on the production server. It builds its own throwaway rclone config (two crypt
# remotes over local folders under /tmp), its own config block, log, lock and state files, a fake
# Unraid var.ini, and stubs Gotify. It never reads or changes your real remotes, log or lock.
# Your own config is only read, by the --check-config test (S12).
#
# Needs: bash, rclone, GNU coreutils/sed/awk, flock, timeout, mountpoint. shellcheck is optional.
# Takes roughly 2-3 minutes (each integration run waits 1 s so timestamps differ).

# Test snippets are evaluated later inside the sourced script, and helpers are called via check():
# shellcheck disable=SC2016,SC2034,SC2030,SC2031,SC2329
set -u
SCRIPT="$(realpath "${1:-$(dirname "$0")/rclone-backup.sh}")"
T="$(mktemp -d /tmp/rbtest.XXXXXX)"
if [[ "${KEEP:-0}" == "1" ]]; then echo "Keeping test folder: $T"; else trap 'rm -rf "$T"' EXIT; fi

PASS=0; FAIL=0; SKIP=0; FAILED_TESTS=(); CUR_SECTION=""; RESULTS=()
record()  { RESULTS+=("$1"$'\t'"$CUR_SECTION"$'\t'"$2"$'\t'"${3:-}"); }   # result, name, detail
pass()    { PASS=$((PASS + 1)); printf '  \e[32mPASS\e[0m %s\n' "$1"; record PASS "$1"; }
fail()    { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); printf '  \e[31mFAIL\e[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; record FAIL "$1" "${2:-}"; }
skip()    { SKIP=$((SKIP + 1)); printf '  \e[33mSKIP\e[0m %s\n' "$1"; record SKIP "$1"; }
section() { CUR_SECTION="$1"; printf '\n== %s ==\n' "$1"; }

# Markdown report: one row per check with its ID, expected outcome (the check's name) and result
write_report() {
    local out="$1" line res sec name detail id text last_sec=""
    {
        echo "# rclone-backup.sh - automated test results"
        echo
        echo "- Run: $(date '+%F %T') on $(hostname)"
        echo "- Script: \`$(basename "$SCRIPT")\` (md5 $(md5sum "$SCRIPT" | cut -c1-12))"
        echo "- rclone: $(rclone version 2>/dev/null | head -n 1), bash ${BASH_VERSION%%(*}"
        echo "- Result: **${PASS} passed, ${FAIL} failed, ${SKIP} skipped** of $(( PASS + FAIL + SKIP )) checks"
        echo
        echo "ID prefixes: S = static checks on the script file, U = unit tests of the script's functions, I = integration runs of the whole script with real rclone against throwaway remotes, M = multi-remote and interval integration runs. Each row's text is the expected outcome; PASS means it was observed."
        for line in "${RESULTS[@]}"; do
            IFS=$'\t' read -r res sec name detail <<< "$line"
            if [[ "$sec" != "$last_sec" ]]; then
                printf '\n## %s\n\n| ID | Expected outcome | Result |\n| --- | --- | --- |\n' "$sec"
                last_sec="$sec"
            fi
            id="${name%% *}"; text="${name#* }"
            [[ "$res" == FAIL && -n "$detail" ]] && text+=" (detail: ${detail})"
            printf '| %s | %s | %s |\n' "$id" "${text//|/\\|}" "$res"
        done
    } > "$out"
    echo "Report written to $out"
}
check()   { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

STAMP_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}'
stamp() { date -d "-$1 days -$2 minutes" '+%Y-%m-%d_%H%M%S'; }   # stamp <days ago> <extra minutes ago>

PROD_FILES=(/var/run/rclone-backup.lock /var/run/rclone-backup.array-alert /tmp/rclone-backup.array-alert)
prod_snapshot() { local f; for f in "${PROD_FILES[@]}"; do stat -c '%n %s %Y' "$f" 2>/dev/null || echo "$f absent"; done; }
PROD_BEFORE="$(prod_snapshot)"

# =====================================================================
section "Static checks"
# =====================================================================
if [ -f "$SCRIPT" ]; then pass "S01 script found: $SCRIPT"; else fail "S01 script found: $SCRIPT"; exit 1; fi
check "S02 bash syntax (bash -n)" bash -n "$SCRIPT"
if command -v shellcheck >/dev/null; then
    if out=$(shellcheck -s bash "$SCRIPT" 2>&1); then pass "S03 shellcheck clean"
    else fail "S03 shellcheck clean" "$(printf '%s' "$out" | head -n 5)"; fi
else
    skip "S03 shellcheck not installed"
fi

missing=()
for key in REMOTES RCLONE_CONF LOG_FILE LOCK_FILE DRY_RUN ARRAY_CHECK UNRAID_VAR_INI UNRAID_POOLS_DIR \
           CHECK_TIMEOUT STUCK_RUN_HOURS LOG_WARN_SIZE_MB CLEANUP_INTERVAL_HOURS DUE_GRACE_MINUTES \
           GOTIFY_ENABLED GOTIFY_URL GOTIFY_TOKEN GOTIFY_NOTIFY_SUCCESS GOTIFY_REPEAT_HOURS \
           GOTIFY_MAX_RCLONE_LINES GOTIFY_MAX_ARCHIVED_LINES; do
    grep -q "^${key}=" "$SCRIPT" || missing+=("$key")
done
for key in VERSIONING SKIP_EXISTING ARCHIVE_DIR DELETED_SUBDIR DELETED_RETENTION_DAYS PURGE_WARNING_DAYS \
           MAX_DELETES_PER_JOB CANARY_FILE MOUNT_CHECK PAUSE_SYNC_DELETES_IF_UNMOUNTED BANDWIDTH_LIMIT \
           BANDWIDTH_SCHEDULE RCLONE_EXTRA_FLAGS; do
    grep -q "^    ${key}=" "$SCRIPT" || missing+=("defaults:$key")
done
if (( ${#missing[@]} == 0 )); then pass "S04 all global settings and defaults present"; else fail "S04 all settings present" "missing: ${missing[*]}"; fi
check "S05 production default: DRY_RUN=false"  grep -q '^DRY_RUN="false"' "$SCRIPT"
check "S06 production default: ARRAY_CHECK=true" grep -q '^ARRAY_CHECK="true"' "$SCRIPT"
check "S07 config marker lines present exactly once each" bash -c "[[ \$(grep -cE '^#+ CONFIG START #+$' '$SCRIPT') == 1 && \$(grep -cE '^#+ CONFIG END #+$' '$SCRIPT') == 1 ]]"
check "S08 deleted-stamp format _DELETED_YYYY-MM-DD_HHMMSS" grep -q '_DELETED_\${RUN_STAMP}' "$SCRIPT"
check "S09 run stamp has seconds" grep -q "%Y-%m-%d_%H%M%S" "$SCRIPT"
if grep -q 'PASTE_APP_TOKEN_HERE' "$SCRIPT"; then
    skip "S10 Gotify token still the placeholder (set GOTIFY_TOKEN before going live)"
else
    pass "S10 Gotify token set"
fi
tools_missing=()
for t in rclone flock timeout mountpoint curl md5sum awk sed realpath logger; do
    command -v "$t" >/dev/null || tools_missing+=("$t")
done
if (( ${#tools_missing[@]} == 0 )); then pass "S11 required tools installed"; else fail "S11 required tools installed" "missing: ${tools_missing[*]}"; fi
if ! command -v rclone >/dev/null; then echo "rclone is required for the remaining tests."; exit 1; fi

# S12: your own config, checked read-only (log path redirected so nothing is written)
sed "s#^LOG_FILE=.*#LOG_FILE=\"$T/s12/backup.log\"#" "$SCRIPT" > "$T/s12.sh"
if out=$(bash "$T/s12.sh" --check-config 2>&1); then pass "S12 your configured remotes pass --check-config"
else fail "S12 your configured remotes pass --check-config" "$(printf '%s' "$out" | grep -A3 PROBLEMS | head -n 6)"; fi

# =====================================================================
# Stubs used by unit and integration tests
# =====================================================================
mkdir -p "$T/bin" "$T/gotify"
export GOTIFY_CAPTURE="$T/gotify"
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
dir="${GOTIFY_CAPTURE:?}"; mkdir -p "$dir"
f="$dir/$(printf '%04d' $(( $(ls "$dir" | wc -l) + 1 ))).txt"
for a in "$@"; do case "$a" in title=*|priority=*|message=*) printf '%s\n' "$a" >> "$f";; esac; done
printf 200
EOF
REAL_MOUNTPOINT="$(command -v mountpoint)"
cat > "$T/bin/mountpoint" <<EOF
#!/bin/bash
for a; do last="\$a"; done
[ "\$last" = "/mnt/user" ] && exit "\${FAKE_USER_MOUNTED:-0}"
exec "$REAL_MOUNTPOINT" "\$@"
EOF
chmod +x "$T/bin/curl" "$T/bin/mountpoint"

gotify_reset() { rm -rf "$T/gotify"; mkdir -p "$T/gotify"; }
gotify_n()     { find "$T/gotify" -type f | wc -l; }
gotify_has()   { grep -rqF -- "$1" "$T/gotify" 2>/dev/null; }

printf 'mdState="STARTED"\nmdNumMissing="0"\nmdNumDisabled="1"\nmdNumInvalid="0"\nfsNumUnmountable="0"\n' > "$T/var-degraded.ini"
printf 'mdState="STARTED"\nmdNumMissing="0"\nmdNumDisabled="0"\nmdNumInvalid="0"\nfsNumUnmountable="0"\n' > "$T/var-ok.ini"
printf 'mdState="STOPPED"\n' > "$T/var-stopped.ini"
mkdir -p "$T/pools-none" "$T/pools-missing"; touch "$T/pools-missing/nosuchpool.cfg"

# =====================================================================
section "Unit tests (functions sourced from the script)"
# =====================================================================
FUNCS="$T/funcs.sh"
sed -n '1,/^# =* Main =*$/p' "$SCRIPT" > "$FUNCS"

unit() {
    (
        export PATH="$T/bin:$PATH"
        # shellcheck disable=SC1090
        source "$FUNCS"
        STATE_DIR="$T/unit"; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
        LOG_FILE="$STATE_DIR/log"; RUN_STATE="$STATE_DIR/run"; STUCK_ALERT="$STATE_DIR/stuck"
        GOTIFY_URL="http://gotify.stub"; HOST="testhost"; PREFIX=""; DRY_RUN="false"; DRY_FLAG=()
        UNRAID_POOLS_DIR="$T/pools-none"; POOLS=""; ALIAS_POOLS="cache"
        ERRORS=(); WARNINGS=(); G_ERRORS=(); G_WARNINGS=(); PAUSE_REASONS=(); GLOBAL_PAUSE_REASONS=()
        RUN_START=$(date +%s); RUN_STAMP=x
        eval "$1"
    ) >"$T/unit.out" 2>&1
}

check "U01 norm_path '/a//b/' -> 'a/b'"   unit '[[ "$(norm_path "/a//b/")" == "a/b" ]]'
check "U02 norm_path '' -> ''"            unit '[[ -z "$(norm_path "")" ]]'

# ---- Bandwidth schedule ----
check "U03 days: Daily -> all 7"          unit '[[ "$(expand_days Daily)" == "0 1 2 3 4 5 6" ]]'
check "U04 days: Mon-Fri"                 unit '[[ "$(expand_days Mon-Fri)" == "0 1 2 3 4" ]]'
check "U05 days: Fri-Mon wraps weekend"   unit '[[ "$(expand_days fri-mon)" == "4 5 6 0" ]]'
check "U06 days: Mon,Wed,Fri list"        unit '[[ "$(expand_days Mon,Wed,Fri)" == "0 2 4" ]]'
check "U07 days: unknown name rejected"   unit '! expand_days Funday'
check "U07b days: Weekdays / Weekends aliases" unit '[[ "$(expand_days Weekdays)" == "0 1 2 3 4" && "$(expand_days weekends)" == "5 6" ]]'
check "U08 timetable: 3 changes a day + weekend, Mbps converted" unit '
    BANDWIDTH_SCHEDULE=("Mon-Fri 06:00 20" "Mon-Fri 18:00 2.5" "Mon-Fri 23:00 unlimited" "Sat-Sun 0:00 unlimited")
    bw_timetable && [[ "$BW_RESULT" == "Mon-06:00,2441k Tue-06:00,2441k Wed-06:00,2441k Thu-06:00,2441k Fri-06:00,2441k Mon-18:00,305k Tue-18:00,305k Wed-18:00,305k Thu-18:00,305k Fri-18:00,305k Mon-23:00,off Tue-23:00,off Wed-23:00,off Thu-23:00,off Fri-23:00,off Sat-00:00,off Sun-00:00,off" ]]'
check "U09 timetable: bad time rejected"     unit 'BANDWIDTH_SCHEDULE=("Daily 25:00 20"); ! bw_timetable && [[ $BW_ERROR == *"24-hour"* ]]'
check "U10 timetable: speed 0 rejected"      unit 'BANDWIDTH_SCHEDULE=("Daily 06:00 0"); ! bw_timetable && [[ $BW_ERROR == *"above 0"* ]]'
check "U11 timetable: text speed rejected"   unit 'BANDWIDTH_SCHEDULE=("Daily 06:00 fast"); ! bw_timetable'
check "U12 timetable: same day+time twice rejected" unit 'BANDWIDTH_SCHEDULE=("Mon-Fri 06:00 20" "Fri 06:00 50"); ! bw_timetable && [[ $BW_ERROR == *"Fri-06:00 twice"* ]]'
check "U13 timetable: missing field rejected" unit 'BANDWIDTH_SCHEDULE=("Daily 06:00"); ! bw_timetable'
check "U14 timetable: empty schedule rejected" unit 'BANDWIDTH_SCHEDULE=(); ! bw_timetable && [[ $BW_ERROR == *empty* ]]'
check "U15 rclone accepts the generated timetable" unit '
    BANDWIDTH_SCHEDULE=("Mon-Fri 06:00 20" "Mon-Fri 18:00 50" "Daily 23:00 unlimited")
    bw_timetable && rclone lsf /tmp --max-depth 1 --bwlimit "$BW_RESULT"'

# ---- Path aliases ----
check "U16 share_key: /mnt/cache/x -> @shares/x"  unit 'ALIAS_POOLS="cache"; [[ $(share_key /mnt/cache/x) == "@shares/x" ]]'
check "U17 share_key: /mnt/user/x and /mnt/disk3/x" unit '[[ $(share_key /mnt/user/x/y) == "@shares/x/y" && $(share_key /mnt/disk3/x) == "@shares/x" ]]'
check "U18 share_key: /mnt/user alone = all shares" unit '[[ $(share_key /mnt/user) == "@shares" ]]'
check "U19 share_key: non-share path has no key"   unit '[[ -z $(share_key /mnt/remotes/x) && -z $(share_key /boot/x) ]]'
check "U20 overlap: /mnt/user/remoteshare/a is inside /mnt/cache/remoteshare" unit '[[ $(mount_overlap /mnt/user/remoteshare/a /mnt/cache/remoteshare) == inside ]]'
check "U21 overlap: /mnt/user contains /mnt/cache/remoteshare" unit '[[ $(mount_overlap /mnt/user /mnt/cache/remoteshare) == contains ]]'
check "U22 overlap: unrelated share is fine"     unit '[[ -z $(mount_overlap /mnt/user/media /mnt/cache/remoteshare) ]]'

# ---- Config validation ----
VC_BASE='
remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy" "/mnt/user/s2|d2|sync"); }
remote_b() { REMOTE="rb:"; RUN_EVERY_HOURS=12; MOUNT_POINT="/mnt/cache/mb"; JOBS=("/mnt/user/s1|d1|copy"); }
defaults() { :; }
REMOTES=("a" "b")'
vc_ok()   { unit "$VC_BASE; $1; validate_all && [[ -z \${PROFILE_PROBLEMS[a]} && -z \${PROFILE_PROBLEMS[b]} ]]"; }
vc_prob() { unit "$VC_BASE; $1; validate_all && [[ \${PROFILE_PROBLEMS[$2]} == *\"$3\"* ]]"; }
vc_abort(){ unit "$VC_BASE; $1; ! validate_all && printf '%s\n' \"\${G_ERRORS[@]}\" | grep -qF \"$2\""; }

check "U23 valid two-remote config accepted (same dest on different remotes is fine)" vc_ok ':'
check "U24 unknown mode flagged"              vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|mirror"); }' a "unknown mode 'mirror'"
check "U25 nested destinations flagged"       vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|sync" "/mnt/user/s2|/d1//x/|copy"); }' a "Destinations overlap"
check "U26 overlap across remotes sharing a REMOTE flagged on both" unit "$VC_BASE"'
    remote_b() { REMOTE="ra:"; RUN_EVERY_HOURS=12; MOUNT_POINT="/mnt/cache/mb"; JOBS=("/mnt/user/s9|d1/sub|copy"); }
    validate_all && [[ ${PROFILE_PROBLEMS[a]} == *overlap* && ${PROFILE_PROBLEMS[b]} == *overlap* ]]'
check "U27 source inside ANOTHER remote's mount flagged" vc_prob 'remote_b() { REMOTE="rb:"; RUN_EVERY_HOURS=12; MOUNT_POINT="/mnt/cache/mb"; JOBS=("/mnt/cache/ma/x|d9|copy"); }' b "inside the mount /mnt/cache/ma (remote 'a')"
check "U28 source via /mnt/user alias of a cache mount flagged" vc_prob 'remote_b() { REMOTE="rb:"; RUN_EVERY_HOURS=12; MOUNT_POINT="/mnt/cache/mb"; JOBS=("/mnt/user/ma/x|d9|copy"); }' b "inside the mount /mnt/cache/ma"
check "U29 source /mnt/user (contains mounts) flagged" vc_prob 'remote_b() { REMOTE="rb:"; RUN_EVERY_HOURS=12; MOUNT_POINT="/mnt/cache/mb"; JOBS=("/mnt/user|all|copy"); }' b "contains the mount"
check "U30 REMOTE without ':' or '/' flagged" vc_prob 'remote_a() { REMOTE="ra"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); }' a "must end in ':' or '/'"
check "U31 RUN_EVERY_HOURS 0 flagged"         vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=0; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); }' a "RUN_EVERY_HOURS '0'"
check "U32 empty MOUNT_POINT with MOUNT_CHECK=true flagged" vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT=""; JOBS=("/mnt/user/s1|d1|copy"); }' a "MOUNT_POINT is empty"
check "U33 empty MOUNT_POINT with MOUNT_CHECK=false accepted" vc_ok 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT=""; MOUNT_CHECK="false"; JOBS=("/mnt/user/s1|d1|copy"); }'
check "U34 bad bandwidth line flagged with its text" vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); BANDWIDTH_LIMIT="on"; BANDWIDTH_SCHEDULE=("Workdays 06:00 20"); }' a "unknown days 'Workdays'"
check "U35 BANDWIDTH_LIMIT typo flagged"       vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); BANDWIDTH_LIMIT="yes"; }' a "must be \\\"on\\\" or \\\"off\\\""
check "U36 bad boolean flagged"                vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); VERSIONING="yes"; }' a "VERSIONING 'yes'"
check "U37 missing remote block aborts"        vc_abort 'REMOTES=("a" "c")' "no remote_c block"
check "U38 duplicate remote name aborts"       vc_abort 'REMOTES=("a" "a")' "listed twice"
check "U39 invalid remote name aborts"         vc_abort 'REMOTES=("my-remote")' "not allowed"
check "U40 empty REMOTES aborts"               vc_abort 'REMOTES=()' "REMOTES is empty"
check "U40b non-numeric global setting aborts"  vc_abort 'STUCK_RUN_HOURS=three' "STUCK_RUN_HOURS 'three' must be a whole number"
check "U40c non-boolean global setting aborts"  vc_abort 'DRY_RUN=yes' "DRY_RUN 'yes' must be"
check "U40d refused rclone flag flagged"        vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); RCLONE_EXTRA_FLAGS=("--transfers" "3" "--delete-excluded"); }' a "contains '--delete-excluded'"
check "U40e harmless rclone flags accepted"     vc_ok   'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); RCLONE_EXTRA_FLAGS=("--transfers" "3" "--checkers" "6" "--fast-list"); }'
check "U40f ARCHIVE_DIR with a slash flagged"   vc_prob 'remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); ARCHIVE_DIR="arch/ive"; }' a "ARCHIVE_DIR 'arch/ive' must be a single folder"
check "U41 defaults apply, a block overrides them for itself only" unit "$VC_BASE"'
    defaults() { MAX_DELETES_PER_JOB=100; }
    remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/m"; JOBS=("/s|d|copy"); MAX_DELETES_PER_JOB=5; }
    load_profile a; [[ $MAX_DELETES_PER_JOB == 5 ]] && load_profile b && [[ $MAX_DELETES_PER_JOB == 100 ]]'
check "U41b MOUNT_CHECK: default true, one remote false, the other inherits true" unit "$VC_BASE"'
    defaults() { MOUNT_CHECK="true"; }
    remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1;  MOUNT_POINT="/mnt/cache/ma"; JOBS=("/mnt/user/s1|d1|copy"); }
    remote_b() { REMOTE="rb:"; RUN_EVERY_HOURS=12; MOUNT_POINT="/mnt/cache/mb"; JOBS=("/mnt/user/s1|d1|copy"); MOUNT_CHECK="false"; }
    load_profile a; [[ $MOUNT_CHECK == true ]] && load_profile b && [[ $MOUNT_CHECK == false ]] && validate_all && [[ -z ${PROFILE_PROBLEMS[a]} && -z ${PROFILE_PROBLEMS[b]} ]]'
check "U42 settings don't leak between remotes" unit "$VC_BASE"'
    remote_a() { REMOTE="ra:"; RUN_EVERY_HOURS=1; MOUNT_POINT="/m"; JOBS=("/s|d|copy"); BANDWIDTH_LIMIT="on"; BANDWIDTH_SCHEDULE=("Daily 00:00 5"); }
    load_profile a; load_profile b; [[ $BANDWIDTH_LIMIT == off && ${#BANDWIDTH_SCHEDULE[@]} == 0 ]]'

# ---- Interval / due logic ----
due_case() { unit "RUN_EVERY_HOURS=$1; DUE_GRACE_MINUTES=10; echo \$(( RUN_START - $2 )) > \"\$STATE_DIR/r.last-success\"; $3 is_due r"; }
check "U43 1h remote due 59m50s after last success (grace)" due_case 1 3590 ""
check "U44 1h remote not due 40 min after"   due_case 1 2400 "!"
check "U45 12h remote not due after 6h"      due_case 12 21600 "!"
check "U46 12h remote due after 11h55m"      due_case 12 42900 ""
check "U47 never-run remote is due"          unit 'RUN_EVERY_HOURS=12; is_due neverran'

# ---- Array, mount, purge, report ----
check "U48 ini_val reads quoted value"       unit "UNRAID_VAR_INI='$T/var-ok.ini'; [[ \$(ini_val mdState) == STARTED ]]"
check "U49 degraded array pauses deletions for all remotes" unit "ARRAY_CHECK=true; UNRAID_VAR_INI='$T/var-degraded.ini'; check_array_health; [[ \${GLOBAL_PAUSE_REASONS[*]} == *degraded* ]]"
check "U50 a pool that isn't mounted pauses deletions" unit "ARRAY_CHECK=true; UNRAID_VAR_INI='$T/var-ok.ini'; POOLS='nosuchpool'; check_array_health; [[ \${G_WARNINGS[*]} == *\"pool 'nosuchpool' not mounted\"* ]]"
check "U51 healthy array, no pools: no pause" unit "ARRAY_CHECK=true; UNRAID_VAR_INI='$T/var-ok.ini'; POOLS=''; check_array_health; (( \${#GLOBAL_PAUSE_REASONS[@]} == 0 ))"
check "U52 stopped array fails started-check" unit "ARRAY_CHECK=true; UNRAID_VAR_INI='$T/var-stopped.ini'; ! check_array_started && [[ \$ARRAY_PROBLEM == *'not started'* ]]"
check "U53 /mnt/user not mounted fails started-check" unit "export FAKE_USER_MOUNTED=1; ARRAY_CHECK=true; UNRAID_VAR_INI='$T/var-ok.ini'; ! check_array_started"

mkdir -p "$T/hangbin" "$T/nconnbin" "$T/fakemnt"; touch "$T/fakemnt/.backup-canary"
printf '#!/bin/bash\nsleep 60\n' > "$T/hangbin/stat"
printf '#!/bin/bash\necho "stat: Transport endpoint is not connected" >&2\nexit 1\n' > "$T/nconnbin/stat"
chmod +x "$T/hangbin/stat" "$T/nconnbin/stat"
MOUNT_SETUP='CURRENT_REMOTE=r1; MOUNT_CHECK=true; CANARY_FILE=.backup-canary; CHECK_TIMEOUT=2; PAUSE_SYNC_DELETES_IF_UNMOUNTED=true; mount_listed() { return 0; }'
check "U54 hung mount detected, counted per remote, deletions paused" unit "$MOUNT_SETUP; MOUNT_POINT=/mnt/x
    PATH='$T/hangbin':\$PATH check_mount; PATH='$T/hangbin':\$PATH check_mount
    read -r s c < \"\$STATE_DIR/r1.mount-hung-since\"; [[ \$c == 2 && \${WARNINGS[*]} == *'hung/frozen since'* && \${PAUSE_REASONS[*]} == *mount* ]]"
check "U55 'transport endpoint not connected' treated as hung" unit "$MOUNT_SETUP; MOUNT_POINT=/mnt/x; CHECK_TIMEOUT=5
    PATH='$T/nconnbin':\$PATH check_mount; [[ \${WARNINGS[*]} == *'hung/frozen'* ]]"
check "U56 healthy mount clears hung state"  unit "$MOUNT_SETUP; MOUNT_POINT='$T/fakemnt'; CHECK_TIMEOUT=5
    echo '1 5' > \"\$STATE_DIR/r1.mount-hung-since\"; check_mount; [ ! -f \"\$STATE_DIR/r1.mount-hung-since\" ] && (( \${#WARNINGS[@]} == 0 ))"
check "U57 mounted but canary missing warns 'not visible'" unit "$MOUNT_SETUP; MOUNT_POINT='$T'; CHECK_TIMEOUT=5; check_mount; [[ \${WARNINGS[*]} == *'not visible'* ]]"

cat > "$T/purge-list.txt" <<EOF
s/a/expired_DELETED_$(stamp 31 0).txt
s/b/day1_DELETED_$(stamp 29 720).pdf
s/c/day2_DELETED_$(stamp 28 720).jpg
s/d/day3_DELETED_$(stamp 27 720)
s/e/fresh_DELETED_$(stamp 2 0).txt
s/f/oldformat_DELETED_2020-01-01_0000.txt
s/g_DELETED_$(stamp 40 0)/in-stamped-folder.txt
s/h/plain.txt
s/i/x_DELETED_$(stamp 40 0)_DELETED_$(stamp 1 0).txt
EOF
PURGE_SETUP="CURRENT_REMOTE=r1; REMOTE='x:'; ARCHIVE_DIR=_archive; DELETED_SUBDIR=deleted; DELETED_RETENTION_DAYS=30; CLEANUP_INTERVAL_HOURS=24; PURGE_WARNING_DAYS=3; DELETED_ROOT=x:_archive/deleted; GOTIFY_ENABLED=true"
check "U58 purge selects only expired stamped files" unit "$PURGE_SETUP; WORK='$T/uw'; mkdir -p \$WORK
    rc() { case \$1 in lsf) cat '$T/purge-list.txt';; delete) shift; while (( \$# )); do [[ \$1 == --files-from-raw ]] && cp \"\$2\" '$T/deleted.txt'; shift; done;; esac; return 0; }
    cleanup_deleted && [[ \$(cat '$T/deleted.txt') == s/a/expired_DELETED_*.txt ]] && (( \$(wc -l < '$T/deleted.txt') == 1 ))"
gotify_reset
check "U59 countdown 3/2/1 days + purged count, titled with remote name" unit "$PURGE_SETUP; WORK='$T/uw2'; mkdir -p \$WORK
    rc() { case \$1 in lsf) cat '$T/purge-list.txt';; esac; return 0; }
    cleanup_deleted
    grep -rqF '3 day(s) until 1 archived file(s)' '$T/gotify' && grep -rqF '1 day(s) until 1 archived file(s)' '$T/gotify' &&
    grep -rqF 'Permanently deleted this run: 1' '$T/gotify' && grep -rqF '(r1)' '$T/gotify'"
check "U60 purge listing failure is an ERROR and retries" unit "$PURGE_SETUP; WORK='$T/uw3'; mkdir -p \$WORK
    rc() { return 7; }; ! cleanup_deleted && [ ! -f \"\$STATE_DIR/r1.last-deleted-cleanup\" ] && [[ \${ERRORS[*]} == *'exit code 7'* ]]"
check "U61 purge 'not found' (exit 3) is not an error" unit "$PURGE_SETUP; WORK='$T/uw4'; mkdir -p \$WORK
    rc() { return 3; }; cleanup_deleted && [ -f \"\$STATE_DIR/r1.last-deleted-cleanup\" ] && (( \${#ERRORS[@]} == 0 ))"
check "U62 purge markers are per remote" unit "$PURGE_SETUP; WORK='$T/uw5'; mkdir -p \$WORK
    rc() { return 3; }; cleanup_deleted; CURRENT_REMOTE=r2; rc() { return 7; }; ! cleanup_deleted"

gotify_reset
check "U63 repeat suppression: growing counts suppressed" unit "GOTIFY_ENABLED=true; GOTIFY_REPEAT_HOURS=6
    WARNINGS=('Mount /m is hung/frozen since 2026-10-07 10:00:00 (3 consecutive run(s)). Fix: x'); report ' (r1)' \"\$STATE_DIR/g\" ''
    WARNINGS=('Mount /m is hung/frozen since 2026-10-07 10:00:00 (4 consecutive run(s)). Fix: x'); report ' (r1)' \"\$STATE_DIR/g\" ''
    (( \$(find '$T/gotify' -type f | wc -l) == 1 ))"
gotify_reset
check "U64 repeat suppression: different paths are new alerts" unit "GOTIFY_ENABLED=true; GOTIFY_REPEAT_HOURS=6
    ERRORS=('Upload failed for /mnt/sharepath1'); report ' (r1)' \"\$STATE_DIR/g\" ''
    ERRORS=('Upload failed for /mnt/sharepath2'); report ' (r1)' \"\$STATE_DIR/g\" ''
    (( \$(find '$T/gotify' -type f | wc -l) == 2 ))"
gotify_reset
check "U65 suppression and recovery are per remote" unit "GOTIFY_ENABLED=true; GOTIFY_REPEAT_HOURS=6
    WARNINGS=('same text'); report ' (r1)' \"\$STATE_DIR/r1\" ''; report ' (r2)' \"\$STATE_DIR/r2\" ''
    WARNINGS=(); report ' (r1)' \"\$STATE_DIR/r1\" ''
    (( \$(find '$T/gotify' -type f | wc -l) == 3 )) && grep -rqF 'Backup recovered on testhost (r1)' '$T/gotify' && [ -f \"\$STATE_DIR/r2\" ]"

# =====================================================================
section "Sandbox integration tests (real rclone, throwaway crypt remotes)"
# =====================================================================
CONF="$T/rclone.conf"
cat > "$CONF" <<EOF
[tb_local]
type = local

[tb_secret]
type = crypt
remote = tb_local:$T/backend
password = $(rclone obscure test-password-123)

[tb_secret2]
type = crypt
remote = tb_local:$T/backend2
password = $(rclone obscure test-password-456)
EOF
R="tb_secret:"; R2="tb_secret2:"
rcl()        { rclone --config "$CONF" "$@"; }
remote_ls()  { rcl lsf -R --files-only "${2:-$R}" 2>/dev/null | LC_ALL=C sort; }
has()        { remote_ls "" "${2:-$R}" | grep -qxF -- "$1"; }
has_re()     { remote_ls "" "${2:-$R}" | grep -qE -- "$1"; }
cat_is()     { [ "$(rcl cat "${3:-$R}$1" 2>/dev/null)" = "$2" ]; }
out_has()    { grep -qF -- "$1" "$T/out.txt"; }
STATE="$T/state/logs/state"
LOGF="$T/state/logs/backup.log"
D="_archive/deleted/nested/t-sync"

# Build a test copy: the real script with its CONFIG section replaced by a test config.
#   Globals can be overridden with KEY=VALUE arguments. Per-test pieces come from:
#   REMOTES_LIST (default "t1"), T1_EXTRA / T2_EXTRA (lines inside remote_t1 / remote_t2), T1_JOBS
make_script() {
    local kv k
    local -A G=(
        [RCLONE_CONF]="$CONF" [LOG_FILE]="$LOGF" [LOCK_FILE]="$T/lock" [DRY_RUN]="false"
        [ARRAY_CHECK]="true" [UNRAID_VAR_INI]="$T/var.ini" [UNRAID_POOLS_DIR]="$T/pools-none"
        [CHECK_TIMEOUT]="10" [STUCK_RUN_HOURS]="3" [LOG_WARN_SIZE_MB]="1024" [CLEANUP_INTERVAL_HOURS]="24"
        [DUE_GRACE_MINUTES]="10" [GOTIFY_ENABLED]="true" [GOTIFY_URL]="http://gotify.stub" [GOTIFY_TOKEN]="test"
        [GOTIFY_NOTIFY_SUCCESS]="false" [GOTIFY_REPEAT_HOURS]="0" [GOTIFY_MAX_RCLONE_LINES]="10" [GOTIFY_MAX_ARCHIVED_LINES]="10"
    )
    for kv in "$@"; do G[${kv%%=*}]="${kv#*=}"; done
    {
        awk '{ print } /^#+ CONFIG START #+$/ { exit }' "$SCRIPT"
        echo "REMOTES=(${REMOTES_LIST:-\"t1\"})"
        for k in "${!G[@]}"; do printf '%s="%s"\n' "$k" "${G[$k]}"; done
        echo 'defaults() { MOUNT_CHECK="false"; }'
        echo "remote_t1() {"
        echo "    REMOTE=\"$R\"; RUN_EVERY_HOURS=1; MOUNT_POINT=\"$T/remoteshare\""
        echo "    JOBS=("
        printf '%s\n' "${T1_JOBS:-$T/src/copy|t-copy|copy
$T/src/sync|nested/t-sync|sync}" | sed 's/.*/        "&"/'
        echo "    )"
        echo "    ${T1_EXTRA:-:}"
        echo "}"
        echo "remote_t2() {"
        echo "    REMOTE=\"$R2\"; RUN_EVERY_HOURS=12; MOUNT_POINT=\"$T/remoteshare2\""
        echo "    JOBS=( \"$T/src/sync|nested/t-sync|sync\" )"
        echo "    ${T2_EXTRA:-:}"
        echo "}"
        awk '/^#+ CONFIG END #+$/ { f = 1 } f { print }' "$SCRIPT"
    } > "$T/run.sh"
}

fresh() {
    rm -rf "$T/backend" "$T/backend2" "$T/src" "$T/state" "$T/remoteshare" "$T/remoteshare2" "$T/lock"
    mkdir -p "$T/backend" "$T/backend2" "$T/src/copy" "$T/src/sync" "$T/remoteshare" "$T/remoteshare2"
    cp "$T/var-ok.ini" "$T/var.ini"
    rcl touch "${R}.backup-canary"; rcl touch "${R2}.backup-canary"
    gotify_reset
    REMOTES_LIST='"t1"'; T1_EXTRA=":"; T2_EXTRA=":"; T1_JOBS=""
    unset FAKE_USER_MOUNTED
}

run() {
    PATH="$T/bin:$PATH" bash "$T/run.sh" "$@" > "$T/out.txt" 2>&1
    RC=$?
    sleep 1    # keep each run's timestamp unique
}
force() { run --force; }   # most single-remote tests run back-to-back, so ignore the 1h interval

# ---- Copy mode ----
fresh; make_script
mkdir -p "$T/src/copy/docs"; echo v1 > "$T/src/copy/docs/a.txt"; echo s > "$T/src/sync/keep.txt"
force
check "I01 copy: new file uploaded, exit 0"                  bash -c "[[ $RC == 0 ]]"
check "I01 copy: content correct"                            cat_is "t-copy/docs/a.txt" v1
echo v2 > "$T/src/copy/docs/a.txt"; force
check "I02 copy: modified file updated"                      cat_is "t-copy/docs/a.txt" v2
V=$(remote_ls | grep -E "^_archive/${STAMP_RE}/t-copy/docs/a.txt$" | head -n 1)
check "I02 copy: old version in _archive/<stamp>/..."        test -n "$V"
check "I02 copy: archived version holds old content"         cat_is "$V" v1
rm "$T/src/copy/docs/a.txt"; force
check "I03 copy: locally deleted file stays on remote"       has "t-copy/docs/a.txt"
check "I03 copy: nothing in _archive/deleted"                bash -c "! rclone --config '$CONF' lsf -R '${R}_archive/deleted' 2>/dev/null | grep -q ."
check "I04 copy: uploads/versions send no Gotify"            bash -c "(( \$(find '$T/gotify' -type f | wc -l) == 0 ))"

# ---- Sync mode ----
fresh; make_script
mkdir -p "$T/src/sync/photos/2024" "$T/src/sync/My Files"
echo img > "$T/src/sync/photos/2024/img.jpg"; echo mk > "$T/src/sync/Makefile"; echo k > "$T/src/sync/keep.txt"
echo tz > "$T/src/sync/backup.tar.gz"; echo u > "$T/src/sync/My Files/naïve résumé.pdf"
force
check "I05 sync: new uploads only -> no Gotify"              bash -c "[[ $RC == 0 ]] && (( \$(find '$T/gotify' -type f | wc -l) == 0 ))"
rm "$T/src/sync/photos/2024/img.jpg" "$T/src/sync/Makefile" "$T/src/sync/backup.tar.gz" "$T/src/sync/My Files/naïve résumé.pdf"
force
check "I06 sync: archived with folders kept + stamp before extension" has_re "^$D/photos/2024/img_DELETED_${STAMP_RE}\.jpg$"
IMG=$(remote_ls | grep -E "^$D/photos/2024/img_DELETED_" | head -n 1)
check "I06 sync: archived content intact"                    cat_is "$IMG" img
check "I06 sync: removed from destination"                   bash -c "! rclone --config '$CONF' lsf '${R}nested/t-sync/photos/2024/' 2>/dev/null | grep -q img.jpg"
check "I07 sync: no-extension and compound-extension names"  bash -c "rclone --config '$CONF' lsf '${R}$D' | grep -qE '^Makefile_DELETED_${STAMP_RE}$' && rclone --config '$CONF' lsf '${R}$D' | grep -qE '^backup_DELETED_${STAMP_RE}\.tar\.gz$'"
check "I08 sync: spaces/Unicode names archived"              has_re "^$D/My Files/naïve résumé_DELETED_${STAMP_RE}\.pdf$"
check "I09 archive message: one 'Files archived ... (t1)', priority 4" bash -c "(( \$(find '$T/gotify' -type f | wc -l) == 1 )) && grep -rlF 'title=Files archived on' '$T/gotify' | xargs grep -qx 'priority=4' && grep -rqF '(t1)' '$T/gotify'"
check "I09 archive message: count, paths and purge date"     bash -c "grep -rqF '4 file(s) deleted locally were moved to ${R}_archive/deleted' '$T/gotify' && grep -rqF 'nested/t-sync/My Files/naïve résumé.pdf' '$T/gotify' && grep -rqF 'permanently deleted after $(date -d '+30 days' +%F)' '$T/gotify'"
echo k2 > "$T/src/sync/keep.txt"; force
check "I10 sync: modified file versioned, not archived as deleted" bash -c "rclone --config '$CONF' lsf -R '${R}_archive' | grep -qE '^${STAMP_RE}/nested/t-sync/keep\.txt$' && ! rclone --config '$CONF' lsf '${R}$D' | grep -q '^keep'"
echo again > "$T/src/sync/Makefile"; force; rm "$T/src/sync/Makefile"; force
check "I11 sync: same file deleted twice -> two stamped copies" bash -c "[[ \$(rclone --config '$CONF' lsf '${R}$D' | grep -c '^Makefile_DELETED_') == 2 ]]"

# ---- Leftover partial uploads ----
fresh; make_script; echo k > "$T/src/sync/keep.txt"; echo u > "$T/src/sync/keep.1234abcd.partial"; force
rcl touch -t 2020-01-01T00:00:00 "${R}nested/t-sync/big.bin.a7435d68.partial"
rcl touch "${R}nested/t-sync/young.bin.0badcafe.partial"
gotify_reset; force
check "I12 partial: old leftover partial deleted"            bash -c "! rclone --config '$CONF' lsf -R '$R' | grep -q 'big.bin.a7435d68'"
check "I12 partial: not archived, not in any message"        bash -c "! rclone --config '$CONF' lsf -R '${R}_archive' 2>/dev/null | grep -q partial && ! grep -rq partial '$T/gotify'"
check "I12 partial: young partial (<1h) left alone"          has "nested/t-sync/young.bin.0badcafe.partial"
check "I12 partial: same-named LOCAL file never removed"     has "nested/t-sync/keep.1234abcd.partial"
check "I12 partial: removal logged"                          grep -q "leftover partial upload" "$LOGF"

# ---- Mount down ----
fresh; T1_EXTRA='MOUNT_CHECK="true"; PAUSE_SYNC_DELETES_IF_UNMOUNTED="true"'; make_script
echo a > "$T/src/sync/a.txt"; echo b > "$T/src/sync/b.txt"; echo stranded > "$T/remoteshare/stranded.txt"
force; rm "$T/src/sync/b.txt"; echo new > "$T/src/sync/new.txt"; force
check "I13 mount down: exit 0, uploads still run"            bash -c "[[ $RC == 0 ]] && rclone --config '$CONF' lsf -R '$R' | grep -qx nested/t-sync/new.txt"
check "I13 mount down: deletion paused (file kept)"          has "nested/t-sync/b.txt"
check "I13 mount down: no 'Files archived' message"          bash -c "! grep -rqF 'Files archived' '$T/gotify'"
check "I14 stranded files warned, never uploaded"            bash -c "grep -rqF 'on the LOCAL drive' '$T/gotify' && ! rclone --config '$CONF' lsf -R '$R' | grep -q stranded"
T1_EXTRA='MOUNT_CHECK="true"; PAUSE_SYNC_DELETES_IF_UNMOUNTED="false"'; make_script; force
check "I15 mount down + pause off: deletion archived"        has_re "^$D/b_DELETED_${STAMP_RE}\.txt$"

# ---- Hard stops ----
fresh; make_script; echo x > "$T/src/copy/x.txt"; echo s > "$T/src/sync/s.txt"
rcl deletefile "${R}.backup-canary"; force
check "I16 canary missing: remote skipped, exit 1, nothing uploaded" bash -c "[[ $RC == 1 ]] && ! rclone --config '$CONF' lsf -R '$R' | grep -q x.txt"
check "I16 canary missing: 'Backup FAILED on <host> (t1)'"   gotify_has "Backup FAILED on $(hostname) (t1)"

fresh; T1_JOBS="$T/src/sync|photos|sync
$T/src/copy|photos/2024|copy"; make_script; echo x > "$T/src/copy/x.txt"; echo s > "$T/src/sync/s.txt"; force
check "I17 overlapping destinations: remote skipped, nothing uploaded" bash -c "[[ $RC == 1 ]] && ! rclone --config '$CONF' lsf -R '$R' | grep -q 'x.txt\|s.txt'"
check "I17 overlapping destinations: alert explains the fix" gotify_has "Fix: use side-by-side folders"

fresh; make_script; cp "$T/var-stopped.ini" "$T/var.ini"; echo x > "$T/src/copy/x.txt"; force
check "I18 array stopped: exit 1, no state folder, nothing uploaded" bash -c "[[ $RC == 1 ]] && [ ! -d '$T/state' ] && ! rclone --config '$CONF' lsf -R '$R' | grep -q x.txt"
check "I18 array stopped: Gotify alert"                      gotify_has "array not available"
check "I18 array alert marker kept next to the TEST lock, not production's" bash -c "[ -f '$T/lock.array-alert' ] && [ ! -e /var/run/rclone-backup.array-alert ] && [ ! -e /tmp/rclone-backup.array-alert ]"
fresh; make_script; export FAKE_USER_MOUNTED=1; echo x > "$T/src/copy/x.txt"; force; unset FAKE_USER_MOUNTED
check "I19 /mnt/user not mounted: exit 1, nothing uploaded"  bash -c "[[ $RC == 1 ]] && ! rclone --config '$CONF' lsf -R '$R' | grep -q x.txt"

fresh; make_script; echo a > "$T/src/sync/a.txt"; echo b > "$T/src/sync/b.txt"; force
cp "$T/var-degraded.ini" "$T/var.ini"; rm "$T/src/sync/b.txt"; echo n > "$T/src/sync/n.txt"; force
check "I20 degraded array: uploads continue, deletion paused" bash -c "rclone --config '$CONF' lsf -R '$R' | grep -qx nested/t-sync/n.txt && rclone --config '$CONF' lsf -R '$R' | grep -qx nested/t-sync/b.txt"
check "I20 degraded array: one global warning (no remote suffix)" bash -c "grep -rqF 'title=Backup warnings on $(hostname)' '$T/gotify' && grep -rlF 'array is degraded' '$T/gotify' | xargs grep -h '^title=' | grep -vqF '(t1)'"

# ---- Sync guards ----
fresh; T1_EXTRA='MAX_DELETES_PER_JOB=2'; make_script
for i in 1 2 3 4 5; do echo "$i" > "$T/src/sync/f$i.txt"; done; force
rm "$T"/src/sync/f[1-4].txt; force
NARCH=$(rcl lsf -R "${R}_archive/deleted" 2>/dev/null | grep -c _DELETED_)
check "I21 max-delete: exit 1, no more than 2 archived"      bash -c "[[ $RC == 1 ]] && (( $NARCH <= 2 ))"
check "I21 max-delete: message matches files archived ($NARCH) + error alert" bash -c "grep -rqF '$NARCH file(s) deleted locally' '$T/gotify' && grep -rqF 'hit MAX_DELETES_PER_JOB' '$T/gotify'"
fresh; make_script; echo a > "$T/src/sync/a.txt"; force; rm "$T/src/sync/a.txt"; force
check "I22 empty sync source: exit 1, nothing archived"      bash -c "[[ $RC == 1 ]] && ! rclone --config '$CONF' lsf -R '$R' | grep -q _DELETED_"

# ---- Purge ----
fresh; make_script; echo s > "$T/src/sync/s.txt"
for f in "expired_DELETED_$(stamp 31 0).txt" "arc_DELETED_$(stamp 35 0).tar.gz" "day1_DELETED_$(stamp 29 720).txt" "day2_DELETED_$(stamp 28 720).txt" \
         "day3_DELETED_$(stamp 27 720).txt" "fresh_DELETED_$(stamp 2 0).txt" "oldformat_DELETED_2020-01-01_0000.txt" "plain.txt"; do
    rcl touch "$R$D/$f"
done
rcl touch "${R}_archive/2020-01-01_000000/t-copy/oldversion.txt"
force
check "I23 purge: expired files deleted"                     bash -c "! rclone --config '$CONF' lsf '${R}$D' | grep -qE '^(expired|arc)_'"
check "I23 purge: due/fresh/unstamped/old-format kept"       bash -c "[[ \$(rclone --config '$CONF' lsf '${R}$D' | grep -cE '^(day1|day2|day3|fresh|oldformat|plain)') == 6 ]]"
check "I23 purge: version folders untouched"                 has "_archive/2020-01-01_000000/t-copy/oldversion.txt"
check "I24 purge: countdown + purged count in one message"   bash -c "grep -rqF '1 day(s) until 1 archived file(s) will be deleted' '$T/gotify' && grep -rqF 'Permanently deleted this run: 2' '$T/gotify'"
N=$(gotify_n); force
check "I25 purge: only once per CLEANUP_INTERVAL_HOURS"      bash -c "(( \$(find '$T/gotify' -type f | wc -l) == $N ))"

# ---- Dry run ----
fresh; make_script; echo a > "$T/src/sync/a.txt"; echo b > "$T/src/sync/b.txt"; force
rcl touch "$R$D/expired_DELETED_$(stamp 31 0).txt"
make_script "DRY_RUN=true"; rm "$T/src/sync/b.txt"; echo n > "$T/src/sync/n.txt"; echo n > "$T/src/copy/n.txt"
rm -f "$STATE/t1.last-deleted-cleanup"; LS_BEFORE=$(cat "$STATE/t1.last-success")
BEFORE=$(remote_ls); force; AFTER=$(remote_ls)
check "I26 dry run: remote unchanged"                        test "$BEFORE" = "$AFTER"
check "I26 dry run: purge marker and last-success unchanged" bash -c "[ ! -f '$STATE/t1.last-deleted-cleanup' ] && [[ \$(cat '$STATE/t1.last-success') == $LS_BEFORE ]]"
check "I26 dry run: '[DRY RUN] Files would be archived (t1)'" gotify_has "title=[DRY RUN] Files would be archived on $(hostname) (t1)"

# ---- Bandwidth ----
fresh; T1_EXTRA='BANDWIDTH_LIMIT="on"; BANDWIDTH_SCHEDULE=("Daily 00:00 80")'; make_script; echo a > "$T/src/copy/a.txt"; force
check "I27 bandwidth on: rclone limiter started at 80 Mbps (9.537 MiB/s)" grep -q "Starting bandwidth limiter at 9.537Mi" "$LOGF"
fresh; make_script; echo a > "$T/src/copy/a.txt"; force
check "I28 bandwidth off: no limiter"                        bash -c "! grep -q 'bandwidth limiter' '$LOGF'"

# ---- Multiple remotes and intervals ----
fresh; REMOTES_LIST='"t1" "t2"'; make_script; echo a > "$T/src/sync/a.txt"; echo c > "$T/src/copy/c.txt"
run
check "M01 first run: both remotes run, t1 first then t2"    bash -c "[[ $RC == 0 ]] && grep -n '\[t1\] Backing up\|\[t2\] Backing up' '$LOGF' | head -1 | grep -q t1 && grep -q '\[t2\] Backing up' '$LOGF'"
check "M01 both remotes received the file"                   bash -c "rclone --config '$CONF' lsf -R '$R' | grep -qx nested/t-sync/a.txt && rclone --config '$CONF' lsf -R '$R2' | grep -qx nested/t-sync/a.txt"
echo b > "$T/src/sync/b.txt"; run
check "M02 immediate rerun: neither remote due, nothing uploaded" bash -c "grep -q '\[t1\] Not due yet' '$T/out.txt' && grep -q '\[t2\] Not due yet' '$T/out.txt' && ! rclone --config '$CONF' lsf -R '$R' | grep -q b.txt"
echo $(( $(date +%s) - 3590 )) > "$STATE/t1.last-success"; run
check "M03 59m50s later: hourly t1 runs (grace), 12h t2 does not" bash -c "rclone --config '$CONF' lsf -R '$R' | grep -qx nested/t-sync/b.txt && ! rclone --config '$CONF' lsf -R '$R2' | grep -q b.txt && grep -q '\[t2\] Not due yet' '$T/out.txt'"
echo $(( $(date +%s) - 42900 )) > "$STATE/t2.last-success"; echo $(( $(date +%s) - 3590 )) > "$STATE/t1.last-success"; run
check "M04 11h55m later: t2 runs too"                        bash -c "rclone --config '$CONF' lsf -R '$R2' | grep -qx nested/t-sync/b.txt"
T2_LS_BEFORE=$(cat "$STATE/t2.last-success")
rcl deletefile "${R2}.backup-canary"; echo c > "$T/src/sync/c.txt"; gotify_reset; run --force
check "M05 t2 failing does not stop t1"                      bash -c "[[ $RC == 1 ]] && rclone --config '$CONF' lsf -R '$R' | grep -qx nested/t-sync/c.txt"
check "M05 failure alert names t2 only"                      bash -c "grep -rqF 'Backup FAILED on $(hostname) (t2)' '$T/gotify' && ! grep -rqF 'FAILED on $(hostname) (t1)' '$T/gotify'"
check "M06 failed remote keeps its previous last-success (so it is retried next run)" bash -c "[[ \$(cat '$STATE/t2.last-success') == $T2_LS_BEFORE ]] && [[ \$(cat '$STATE/t1.last-success') != $T2_LS_BEFORE ]]"
rcl touch "${R2}.backup-canary"; echo d > "$T/src/sync/d.txt"; run --only t2
check "M07 --only t2: runs t2 now, t1 untouched"             bash -c "rclone --config '$CONF' lsf -R '$R2' | grep -qx nested/t-sync/d.txt && ! rclone --config '$CONF' lsf -R '$R' | grep -q d.txt && ! grep -q '\[t1\]' '$T/out.txt'"
check "M07 recovery message names t2"                        gotify_has "Backup recovered on $(hostname) (t2)"
run --only nosuch
check "M08 --only with an unknown name: error, exit 1"       bash -c "[[ $RC == 1 ]] && grep -qF -- \"--only 'nosuch' is not in REMOTES\" '$T/out.txt'"
rm "$T/src/sync/a.txt"; gotify_reset; run --force
check "M09 same deletion archived on BOTH remotes, one message each" bash -c "rclone --config '$CONF' lsf -R '$R' | grep -qE '^$D/a_DELETED_' && rclone --config '$CONF' lsf -R '$R2' | grep -qE '^$D/a_DELETED_' && grep -rqF 'Files archived on $(hostname) (t1)' '$T/gotify' && grep -rqF 'Files archived on $(hostname) (t2)' '$T/gotify'"
T2_EXTRA='BANDWIDTH_LIMIT="on"; BANDWIDTH_SCHEDULE=("Workdays 06:00 20")'; make_script; echo e > "$T/src/sync/e.txt"; gotify_reset; run --force
check "M10 bad t2 bandwidth line: t2 skipped, t1 still runs" bash -c "[[ $RC == 1 ]] && rclone --config '$CONF' lsf -R '$R' | grep -qx nested/t-sync/e.txt && ! rclone --config '$CONF' lsf -R '$R2' | grep -q e.txt"
check "M10 config alert names t2 and quotes the bad line"    bash -c "grep -rqF 'Backup FAILED on $(hostname) (t2)' '$T/gotify' && grep -rqF \"unknown days 'Workdays'\" '$T/gotify'"
PATH="$T/bin:$PATH" bash "$T/run.sh" --check-config > "$T/cc.txt" 2>&1; CC=$?
check "M11 --check-config: exit 1 and lists the problem"     bash -c "[[ $CC == 1 ]] && grep -q 'PROBLEMS (this remote would be skipped)' '$T/cc.txt' && grep -q 'Workdays' '$T/cc.txt'"
T2_EXTRA=':'; make_script; PATH="$T/bin:$PATH" bash "$T/run.sh" --check-config > "$T/cc.txt" 2>&1; CC=$?
check "M12 --check-config: valid config exits 0, shows both remotes" bash -c "[[ $CC == 0 ]] && grep -q '== t1 ==' '$T/cc.txt' && grep -q '== t2 ==' '$T/cc.txt'"
LOGSZ=$(stat -c %s "$LOGF"); REMOTES_LIST='"t1" "nosuch"'; make_script; PATH="$T/bin:$PATH" bash "$T/run.sh" --check-config > "$T/cc.txt" 2>&1; CC=$?
check "M12 --check-config with a broken REMOTES list: exit 1, explains, writes nothing to the log" bash -c "[[ $CC == 1 ]] && grep -q 'no remote_nosuch block' '$T/cc.txt' && [[ \$(stat -c %s '$LOGF') == $LOGSZ ]]"
REMOTES_LIST='"t1" "t2"'
REMOTES_LIST='"t2"'; make_script; echo f > "$T/src/sync/f.txt"; run --force
check "M13 removing t1 from REMOTES pauses it"               bash -c "! grep -q '\[t1\]' '$T/out.txt' && ! rclone --config '$CONF' lsf -R '$R' | grep -q f.txt"

# ---- Locking / stuck runs ----
fresh; make_script; echo a > "$T/src/copy/a.txt"
( exec 9>"$T/lock"; flock 9; exec sleep 60 ) & HOLDER=$!; sleep 0.5
force
check "I29 overlapping run: exits 0, skips, uploads nothing" bash -c "[[ $RC == 0 ]] && grep -q 'still in progress' '$T/out.txt' && ! rclone --config '$CONF' lsf -R '$R' | grep -q a.txt"
mkdir -p "$STATE"; echo "$(( $(date +%s) - 4 * 3600 )) 99999 2" > "$STATE/run-in-progress"
force
check "I30 stuck run: 'Backup stuck' alert, counter incremented" bash -c "grep -rqF 'Backup stuck' '$T/gotify' && [[ \$(cut -d' ' -f3 '$STATE/run-in-progress') == 3 ]]"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
force
check "I31 lock released: next run proceeds, run-state removed" bash -c "rclone --config '$CONF' lsf -R '$R' | grep -qx t-copy/a.txt && [ ! -f '$STATE/run-in-progress' ]"

# ---- Notifications ----
fresh; T1_EXTRA='MOUNT_CHECK="true"'; make_script "GOTIFY_REPEAT_HOURS=6"; echo a > "$T/src/sync/a.txt"
force; force
check "I32 repeat suppression: one alert for two identical runs" bash -c "(( \$(find '$T/gotify' -type f | wc -l) == 1 ))"
T1_EXTRA=':'; make_script "GOTIFY_REPEAT_HOURS=6"; force
check "I33 recovery message after problem clears"            gotify_has "Backup recovered on $(hostname) (t1)"
fresh; make_script "LOG_WARN_SIZE_MB=1"; echo a > "$T/src/sync/a.txt"
mkdir -p "$(dirname "$LOGF")"; head -c 2097152 /dev/zero | tr '\0' 'x' > "$LOGF"; force
check "I34 log size warning (global) with truncate instructions" gotify_has "truncate -s 0"
fresh; make_script; for i in $(seq 1 12); do echo "$i" > "$T/src/sync/n$i.txt"; done; echo k > "$T/src/sync/keep.txt"
echo c > "$T/src/copy/c.txt"; force; gotify_reset
rm "$T"/src/sync/n*.txt "$T/src/copy/c.txt"; force
check "I35 archive message: 12 files, 10 listed + '... and 2 more'; copy deletions never listed" bash -c "grep -rqF '12 file(s) deleted locally' '$T/gotify' && grep -rqF '... and 2 more' '$T/gotify' && ! grep -rqF 't-copy/c.txt' '$T/gotify'"

# ---- Settings paths not covered elsewhere ----
fresh; T1_EXTRA='VERSIONING="false"'; make_script; echo v1 > "$T/src/copy/a.txt"; echo s > "$T/src/sync/s.txt"; force; echo v2 > "$T/src/copy/a.txt"; force
check "I39 VERSIONING=false: modified file overwritten, no version folder" bash -c "[[ \$(rclone --config '$CONF' cat '${R}t-copy/a.txt') == v2 ]] && ! rclone --config '$CONF' lsf -R '${R}_archive' 2>/dev/null | grep -q t-copy"
fresh; T1_EXTRA='VERSIONING="false"; SKIP_EXISTING="true"'; make_script; echo v1 > "$T/src/copy/a.txt"; echo s > "$T/src/sync/s.txt"; force; echo v2 > "$T/src/copy/a.txt"; echo n > "$T/src/copy/new.txt"; force
check "I40 SKIP_EXISTING=true: existing file kept, new file uploaded" bash -c "[[ \$(rclone --config '$CONF' cat '${R}t-copy/a.txt') == v1 ]] && rclone --config '$CONF' lsf -R '$R' | grep -qx t-copy/new.txt"
fresh; T1_JOBS="$T/src/copy|t-copy|copy
$T/src/nope|t-nope|copy
$T/src/sync|nested/t-sync|sync"; make_script; echo a > "$T/src/copy/a.txt"; echo s > "$T/src/sync/s.txt"; force
check "I41 missing source folder: that job skipped, other jobs still run, exit 1, alert names it" bash -c "[[ $RC == 1 ]] && rclone --config '$CONF' lsf -R '$R' | grep -qx t-copy/a.txt && rclone --config '$CONF' lsf -R '$R' | grep -qx nested/t-sync/s.txt && grep -rqF 'does not exist' '$T/gotify'"
fresh; make_script "ARRAY_CHECK=false"; cp "$T/var-stopped.ini" "$T/var.ini"; echo a > "$T/src/copy/a.txt"; echo s > "$T/src/sync/s.txt"; force
check "I42 ARRAY_CHECK=false: stopped-array ini ignored, run proceeds" bash -c "[[ $RC == 0 ]] && rclone --config '$CONF' lsf -R '$R' | grep -qx t-copy/a.txt"
fresh; T1_EXTRA='DELETED_RETENTION_DAYS=0'; make_script; echo s > "$T/src/sync/s.txt"; rcl touch "$R$D/expired_DELETED_$(stamp 40 0).txt"; force
check "I43 DELETED_RETENTION_DAYS=0: nothing purged, no countdown message" bash -c "rclone --config '$CONF' lsf '${R}$D' | grep -q '^expired_' && ! grep -rqF 'due for deletion' '$T/gotify'"
fresh; make_script "GOTIFY_NOTIFY_SUCCESS=true"; echo a > "$T/src/copy/a.txt"; echo s > "$T/src/sync/s.txt"; force
check "I44 GOTIFY_NOTIFY_SUCCESS=true: 'Backup OK on <host> (t1)' priority 2" bash -c "grep -rlF 'title=Backup OK on $(hostname) (t1)' '$T/gotify' | xargs grep -qx 'priority=2'"

# ---- Housekeeping ----
fresh; make_script; echo a > "$T/src/copy/a.txt"
TMP_BEFORE=$(find /tmp -maxdepth 1 -name 'rclone-backup.*' -type d 2>/dev/null | wc -l); force
TMP_AFTER=$(find /tmp -maxdepth 1 -name 'rclone-backup.*' -type d 2>/dev/null | wc -l)
check "I36 temp work folder removed after run"               test "$TMP_BEFORE" -eq "$TMP_AFTER"
run --bogus
check "I37 unknown option: exit 2 with usage hint"           bash -c "[[ $RC == 2 ]] && grep -q 'Use --force' '$T/out.txt'"

# ---- Isolation ----
check "I38 production lock and alert marker untouched by the whole suite" test "$PROD_BEFORE" = "$(prod_snapshot)"

# =====================================================================
printf '\n== Summary ==\n  %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ -n "${REPORT:-}" ] && write_report "$REPORT"
if (( FAIL )); then
    printf '  Failed:\n'; printf '    - %s\n' "${FAILED_TESTS[@]}"
    [[ "${KEEP:-0}" == "1" ]] || echo "  Re-run with KEEP=1 to inspect $T"
    exit 1
fi
exit 0
