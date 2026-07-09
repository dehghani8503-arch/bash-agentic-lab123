#!/usr/bin/env bash
#
# server-stats.sh — basic server performance stats for any Linux server.
#
# Usage: ./server-stats.sh [-h|--help]
#
# Deliberately does NOT use `set -e`: this script's job is to report as many
# stats as possible even when individual data sources are missing or
# unreadable. A missing `mpstat` or an unreadable auth log should degrade
# that one line to "N/A (reason)", not abort the whole report. We do use
# -u and -o pipefail to catch unset-variable bugs and broken pipes, which
# are genuine programming errors rather than expected environmental gaps.
set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_section() {
    printf '\n=== %s ===\n' "$1"
}

print_kv() {
    # $1 = label, $2 = value
    printf '%-28s %s\n' "$1:" "$2"
}

usage() {
    cat <<'EOF'
server-stats.sh — basic server performance stats for any Linux server.

Usage:
  ./server-stats.sh [OPTIONS]

Options:
  -h, --help    Show this help message and exit

Reports (always):
  Total CPU usage
  Total memory usage (free vs used, with percentage)
  Total disk usage (free vs used, with percentage)
  Top 5 processes by CPU usage
  Top 5 processes by memory usage

Reports (best-effort, shown as "N/A (reason)" if unavailable):
  OS version, uptime, load average, logged-in users, failed login attempts

Exit codes:
  0  Script completed (individual stats may show N/A if a data source was
     unavailable on this system — that is expected, defensive behaviour,
     not a script failure).
  1  A truly fatal condition prevented the script from running at all
     (e.g. /proc is not mounted).
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n\n' "$arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity check: /proc must be available. Everything below leans on it either
# directly or indirectly (via free/ps/df, which themselves read /proc on
# Linux). Without it we cannot produce a meaningful report at all.
# ---------------------------------------------------------------------------

if [ ! -r /proc/stat ]; then
    printf 'FATAL: /proc/stat is not readable. This script requires a Linux system with /proc mounted.\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Mandatory stat 1: Total CPU usage
#
# Strategy: sample /proc/stat's aggregate "cpu" line twice, ~0.5s apart, and
# compute the percentage of non-idle time in that window. This is the same
# technique `top`/`mpstat` use internally, but implemented directly against
# /proc/stat so it works with zero external dependencies. We deliberately
# avoid depending on `mpstat` (part of the optional sysstat package, absent
# on many minimal/container distros — confirmed absent in the environment
# this script was developed and tested in).
# ---------------------------------------------------------------------------

get_cpu_usage() {
    local cpu_line1 cpu_line2
    local -a f1 f2
    local idle1 total1 idle2 total2 idle_delta total_delta cpu_pct

    cpu_line1="$(grep -m1 '^cpu ' /proc/stat)" || { printf 'N/A (could not read /proc/stat)'; return; }
    sleep 0.5
    cpu_line2="$(grep -m1 '^cpu ' /proc/stat)" || { printf 'N/A (could not read /proc/stat)'; return; }

    # Fields: user nice system idle iowait irq softirq steal guest guest_nice
    read -r -a f1 <<< "$cpu_line1"
    read -r -a f2 <<< "$cpu_line2"

    # index 0 is the literal "cpu" label; fields start at 1
    idle1=$(( f1[4] + f1[5] ))   # idle + iowait
    idle2=$(( f2[4] + f2[5] ))

    total1=0
    for v in "${f1[@]:1}"; do total1=$(( total1 + v )); done
    total2=0
    for v in "${f2[@]:1}"; do total2=$(( total2 + v )); done

    idle_delta=$(( idle2 - idle1 ))
    total_delta=$(( total2 - total1 ))

    if [ "$total_delta" -le 0 ]; then
        printf 'N/A (no measurable delta between samples)'
        return
    fi

    cpu_pct=$(awk -v idle="$idle_delta" -v total="$total_delta" 'BEGIN { printf "%.1f", (1 - idle/total) * 100 }')
    printf '%s%%' "$cpu_pct"
}

# ---------------------------------------------------------------------------
# Mandatory stat 2: Total memory usage (free vs used, with percentage)
#
# Strategy: prefer `free -b` (bytes, avoids ambiguous units/rounding from
# `-h`), converted to human-readable MB/GB ourselves for display. Fall back
# to parsing /proc/meminfo directly if `free` is not installed (BusyBox
# systems sometimes omit it; /proc/meminfo is what `free` reads anyway).
# "Used" is computed the way modern `free` does: total - available, which
# correctly accounts for reclaimable cache/buffers rather than the naive
# and misleading total - free.
# ---------------------------------------------------------------------------

human_bytes() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB", units, " ")
        u = 1
        while (b >= 1024 && u < 5) { b /= 1024; u++ }
        printf "%.1f %s", b, units[u]
    }'
}

get_memory_usage() {
    local total_b used_b avail_b pct

    if command_exists free; then
        # free -b Mem: row is: total used free shared buff/cache available.
        # We read $2 (total, a stable first-data-field position across
        # procps versions) and $NF (available, always the last column even
        # if a version inserts/removes a middle column) rather than
        # hard-coding every column index, so a shifted middle column
        # doesn't silently break the "available" read.
        local free_out
        free_out="$(free -b 2>/dev/null)" || { printf 'N/A (free command failed)'; return; }
        total_b="$(awk '/^Mem:/{print $2}' <<< "$free_out")"
        avail_b="$(awk '/^Mem:/{print $NF}' <<< "$free_out")"
    elif [ -r /proc/meminfo ]; then
        total_b="$(awk '/^MemTotal:/{print $2 * 1024}' /proc/meminfo)"
        avail_b="$(awk '/^MemAvailable:/{print $2 * 1024}' /proc/meminfo)"
    else
        printf 'N/A (neither free nor /proc/meminfo available)'
        return
    fi

    if [ -z "${total_b:-}" ] || [ -z "${avail_b:-}" ]; then
        printf 'N/A (could not parse memory fields)'
        return
    fi

    used_b=$(( total_b - avail_b ))
    pct=$(awk -v used="$used_b" -v total="$total_b" 'BEGIN { if (total>0) printf "%.1f", (used/total)*100; else print "0.0" }')

    printf 'Used: %s / Total: %s (%s%%) | Free (available): %s' \
        "$(human_bytes "$used_b")" "$(human_bytes "$total_b")" "$pct" "$(human_bytes "$avail_b")"
}

# ---------------------------------------------------------------------------
# Mandatory stat 3: Total disk usage (free vs used, with percentage), for
# the filesystem the script itself is running from (/).
#
# Strategy: `df -kP /`. The -P flag forces POSIX output format, which pins
# the column layout (Filesystem 1024-blocks Used Available Capacity
# Mounted-on) regardless of whether this is GNU coreutils df or BusyBox df
# — both support -P. We deliberately do NOT parse `df -h`, since human-
# readable units differ in rounding/format between implementations.
# ---------------------------------------------------------------------------

get_disk_usage() {
    local df_out used_kb avail_kb total_kb pct

    if ! command_exists df; then
        printf 'N/A (df command not found)'
        return
    fi

    df_out="$(df -kP / 2>/dev/null | awk 'NR==2')" || true
    if [ -z "$df_out" ]; then
        printf 'N/A (df produced no output for /)'
        return
    fi

    total_kb="$(awk '{print $2}' <<< "$df_out")"
    used_kb="$(awk '{print $3}' <<< "$df_out")"
    avail_kb="$(awk '{print $4}' <<< "$df_out")"
    pct="$(awk '{gsub("%","",$5); print $5}' <<< "$df_out")"

    if [ -z "$total_kb" ] || [ -z "$used_kb" ]; then
        printf 'N/A (could not parse df output)'
        return
    fi

    printf 'Used: %s / Total: %s (%s%%) | Free: %s' \
        "$(human_bytes "$(( used_kb * 1024 ))")" \
        "$(human_bytes "$(( total_kb * 1024 ))")" \
        "${pct:-?}" \
        "$(human_bytes "$(( avail_kb * 1024 ))")"
}

# ---------------------------------------------------------------------------
# Mandatory stats 4 & 5: Top 5 processes by CPU / memory usage
#
# Strategy: GNU `ps` supports `--sort=-%cpu` / `--sort=-%mem` directly, which
# is the most robust approach (no manual re-sorting needed). BusyBox ps is
# more limited than just "no --sort": its -o column list does not include
# %cpu or %mem at all (confirmed directly against a real busybox binary
# during development — supported columns are user,group,comm,args,pid,
# ppid,pgid,nice,rgroup,ruser,tty,vsz,sid,stat,rss only). So detection has
# to be a real capability probe of the exact column spec we intend to use,
# not just a flag/version sniff, or we would print a silently-empty section
# on a real BusyBox system. Process names are printed as-is but never
# interpolated into anything executed, so arbitrarily long or strange
# process names cannot cause injection — they're purely display strings.
# ---------------------------------------------------------------------------

ps_field_supported() {
    # Real capability probe: try the exact -o field spec we want to use and
    # see if ps accepts it, rather than inferring support from --help text
    # or a version/flavour guess. $1 = field name (e.g. "%cpu", "%mem").
    ps -eo "pid,comm,$1" >/dev/null 2>&1
}

ps_supports_sort() {
    # This greps `ps --help` (documentation text) to detect a capability
    # flag, not `ps`'s process listing output. SC2009 exists to warn against
    # the latter (fragile/race-prone process scraping); it doesn't apply to
    # introspecting --help text, so it is suppressed on the line below.
    # shellcheck disable=SC2009
    ps --help 2>&1 | grep -q -- '--sort'
}

get_top_procs() {
    # $1 = "cpu" or "mem" — everything else is derived from that.
    local key="$1"
    local sort_field="%${key}"
    local header
    local fallback_field=''
    local fallback_label=''

    if ! command_exists ps; then
        printf 'N/A (ps command not found)\n'
        return
    fi

    if ! ps_field_supported "$sort_field"; then
        # The GNU-style %cpu/%mem column genuinely does not exist on this
        # ps implementation (observed on real BusyBox ps, which has no CPU%
        # concept at all). For memory we can offer a real, honestly-labeled
        # proxy (rss = resident set size in KB, which BusyBox ps does
        # support). For CPU there is no equivalent proxy available via ps
        # on such systems, so we say so plainly instead of guessing or
        # printing nothing.
        if [ "$key" = "mem" ] && ps_field_supported "rss"; then
            fallback_field='rss'
            fallback_label='RSS(KB)'
        else
            printf 'N/A (this ps does not support %%%s or an equivalent column — seen on minimal/BusyBox ps builds, which expose no per-process %s metric at all)\n' \
                "$key" "$key"
            return
        fi
    fi

    if [ -n "$fallback_field" ]; then
        header="$(printf '%-8s %-25s %s' 'PID' 'COMMAND' "$fallback_label")"
    else
        header="$(printf '%-8s %-25s %s' 'PID' 'COMMAND' "${sort_field^^}")"
    fi
    printf '%s\n' "$header"
    printf '%s\n' "-------- ------------------------- ------"

    if [ -n "$fallback_field" ]; then
        # rss has no --sort support to rely on either (same BusyBox ps that
        # lacks %cpu/%mem also lacks --sort) — sort it ourselves.
        ps -eo pid,comm,"$fallback_field" 2>/dev/null \
            | awk 'NR>1' \
            | sort -k3 -rn \
            | head -n 5 \
            | awk '{printf "%-8s %-25s %s\n", $1, $2, $3}'
    elif ps_supports_sort; then
        ps -eo pid,comm,"$sort_field" --sort="-$sort_field" --no-headers 2>/dev/null \
            | head -n 5 \
            | awk '{printf "%-8s %-25s %s\n", $1, $2, $3}'
    else
        # GNU/procps ps that supports the %cpu/%mem column but not --sort
        # (uncommon in practice, but handled the same defensive way).
        ps -eo pid,comm,"$sort_field" --no-headers 2>/dev/null \
            | sort -k3 -rn \
            | head -n 5 \
            | awk '{printf "%-8s %-25s %s\n", $1, $2, $3}'
    fi
}

# ---------------------------------------------------------------------------
# Stretch goal: OS version
# ---------------------------------------------------------------------------

get_os_version() {
    if [ -r /etc/os-release ]; then
        awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release
    elif command_exists lsb_release; then
        lsb_release -d 2>/dev/null | awk -F'\t' '{print $2}'
    elif command_exists uname; then
        uname -srm
    else
        printf 'N/A (no os-release, lsb_release, or uname available)'
    fi
}

# ---------------------------------------------------------------------------
# Stretch goal: Uptime
# ---------------------------------------------------------------------------

get_uptime() {
    local secs days hours mins

    if [ -r /proc/uptime ]; then
        secs="$(awk '{print int($1)}' /proc/uptime)"
        days=$(( secs / 86400 ))
        hours=$(( (secs % 86400) / 3600 ))
        mins=$(( (secs % 3600) / 60 ))
        printf '%dd %dh %dm' "$days" "$hours" "$mins"
    elif command_exists uptime; then
        uptime -p 2>/dev/null || uptime
    else
        printf 'N/A (no /proc/uptime or uptime command)'
    fi
}

# ---------------------------------------------------------------------------
# Stretch goal: Load average
# ---------------------------------------------------------------------------

get_load_average() {
    if [ -r /proc/loadavg ]; then
        awk '{printf "%s (1m)  %s (5m)  %s (15m)", $1, $2, $3}' /proc/loadavg
    else
        printf 'N/A (/proc/loadavg not readable)'
    fi
}

# ---------------------------------------------------------------------------
# Stretch goal: Logged-in users
# ---------------------------------------------------------------------------

get_logged_in_users() {
    if command_exists who; then
        local n
        n="$(who 2>/dev/null | wc -l)"
        if [ "$n" -eq 0 ]; then
            printf '0 (none currently logged in)'
        else
            printf '%s' "$n"
        fi
    else
        printf 'N/A (who command not found)'
    fi
}

# ---------------------------------------------------------------------------
# Stretch goal: Failed login attempts
#
# Strategy, in order: `lastb` (reads btmp) -> /var/log/auth.log (Debian/
# Ubuntu) -> /var/log/secure (RHEL/CentOS) -> explicit N/A. All three
# sources commonly require root; a permission error is treated the same as
# "unavailable" rather than leaking a raw stack-trace-like Permission denied
# to stderr.
# ---------------------------------------------------------------------------

get_failed_logins() {
    local count

    if command_exists lastb; then
        local lastb_output lastb_status
        lastb_output="$(lastb 2>/dev/null)"
        lastb_status=$?
        # A zero exit status means lastb successfully read btmp (even if it
        # contains zero failed-login records, which is a real and useful
        # answer, not the same as "no source available"). A nonzero status
        # means it couldn't read btmp at all (missing file, no permission),
        # in which case we fall through to the log-file fallbacks below.
        if [ "$lastb_status" -eq 0 ]; then
            count="$(printf '%s\n' "$lastb_output" | grep -vc '^btmp begins\|^$')"
            printf '%s (via lastb)' "$count"
            return
        fi
    fi

    if [ -r /var/log/auth.log ]; then
        count="$(grep -c 'Failed password' /var/log/auth.log 2>/dev/null || printf '0')"
        printf '%s (via /var/log/auth.log)' "$count"
        return
    fi

    if [ -r /var/log/secure ]; then
        count="$(grep -c 'Failed password' /var/log/secure 2>/dev/null || printf '0')"
        printf '%s (via /var/log/secure)' "$count"
        return
    fi

    printf 'N/A (no readable btmp, auth.log, or secure log found on this system)'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    printf 'Server Stats Report — %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Host: %s\n' "$(hostname 2>/dev/null || printf 'unknown')"

    print_section 'CPU Usage'
    print_kv 'Total CPU usage' "$(get_cpu_usage)"

    print_section 'Memory Usage'
    print_kv 'Memory' "$(get_memory_usage)"

    print_section 'Disk Usage (/)'
    print_kv 'Disk' "$(get_disk_usage)"

    print_section 'Top 5 Processes by CPU'
    get_top_procs cpu

    print_section 'Top 5 Processes by Memory'
    get_top_procs mem

    print_section 'Additional Info'
    print_kv 'OS version' "$(get_os_version)"
    print_kv 'Uptime' "$(get_uptime)"
    print_kv 'Load average' "$(get_load_average)"
    print_kv 'Logged-in users' "$(get_logged_in_users)"
    print_kv 'Failed login attempts' "$(get_failed_logins)"

    printf '\n'
}

main
