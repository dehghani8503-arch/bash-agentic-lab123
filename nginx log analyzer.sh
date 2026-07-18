#!/usr/bin/env bash
#
# nginx_log_analyzer.sh
#
# Analyzes an nginx access log (combined log format) and reports:
#   1. Top N IP addresses by request count
#   2. Top N most requested paths
#   3. Top N response status codes
#   4. Top N user agents
#
# Usage: ./nginx_log_analyzer.sh <log_file> [top_n]
#
# Expected line format (nginx "combined" log format):
#   IP - - [date] "METHOD path HTTP/x.x" status size "referrer" "user agent"

set -uo pipefail
# Note: 'set -e' is deliberately NOT used. It interacts badly with pipelines
# ending in 'head', which closes its input early and causes an upstream
# 'sort' to receive SIGPIPE — with -e that would kill the script even
# though nothing actually went wrong. We check exit status explicitly
# where it matters instead.

# Use the C locale for sort: faster, and byte-order deterministic
# regardless of the user's system locale.
export LC_ALL=C

readonly SCRIPT_NAME="${0##*/}"

usage() {
    echo "Usage: ${SCRIPT_NAME} <log_file> [top_n]" >&2
    echo "  log_file  Path to an nginx access log (combined format)" >&2
    echo "  top_n     Number of top entries to show per report (default: 5)" >&2
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# --- Argument parsing / validation -----------------------------------------

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 1
fi

LOG_FILE=$1
TOP_N=${2:-5}

[[ -f "$LOG_FILE" ]]    || die "file '${LOG_FILE}' does not exist"
[[ -r "$LOG_FILE" ]]    || die "file '${LOG_FILE}' is not readable"
[[ -s "$LOG_FILE" ]]    || die "file '${LOG_FILE}' is empty"
[[ "$TOP_N" =~ ^[0-9]+$ && "$TOP_N" -gt 0 ]] || die "top_n must be a positive integer, got '${TOP_N}'"

# --- Core report function ---------------------------------------------------
#
# Runs an awk extraction program over the log, counts occurrences,
# and prints the top N as "value - N requests".
#
# Args:
#   $1  Human-readable title for the section
#   $2  awk program that prints one extracted field per input line
#
run_report() {
    local title="$1"
    local awk_program="$2"
    local result
    local line_count

    # -k1,1nr sorts by count descending; -k2 breaks ties alphabetically by
    # value, so the order is fully deterministic on any POSIX sort
    # (GNU or BSD/macOS), not dependent on an implementation-specific
    # whole-line tie-break.
    result=$(awk -F'"' "$awk_program" "$LOG_FILE" 2>/dev/null | sort | uniq -c | sort -k1,1nr -k2 | head -n "$TOP_N")

    echo "${title}:"
    if [[ -z "$result" ]]; then
        echo "  (no matching entries found)"
    else
        # Reformat "  COUNT value" -> "value - COUNT requests"
        while read -r count value; do
            printf '%s - %s requests\n' "$value" "$count"
        done <<< "$result"
    fi
    echo ""
}

# --- Malformed-line warning --------------------------------------------------
# A well-formed combined-log line has at least 6 quote-delimited fields
# (request, referrer, user-agent are each quoted). Warn if a meaningful
# fraction of lines don't match, since that means the reports below are
# likely skipping or misparsing data.

total_lines=$(wc -l < "$LOG_FILE")
malformed_lines=$(awk -F'"' 'NF < 6 {c++} END{print c+0}' "$LOG_FILE")

if [[ "$malformed_lines" -gt 0 ]]; then
    echo "Warning: ${malformed_lines} of ${total_lines} lines do not match the" >&2
    echo "expected combined log format and may be excluded or misparsed." >&2
    echo "" >&2
fi

# --- Reports ------------------------------------------------------------

# Field layout after splitting on '"':
#   $1 = 'IP - - [date] '     -> first whitespace token is the IP
#   $2 = 'METHOD path HTTP/x' -> second whitespace token is the path
#   $3 = ' status size '      -> first whitespace token is the status code
#   $4 = referrer
#   $5 = user agent

# NF>=6 guards every extraction: a well-formed combined-log line always
# produces 6 quote-delimited fields. Lines that don't match (e.g. garbage,
# truncated lines) are skipped entirely rather than feeding partial/wrong
# data into the counts -- consistent with the warning printed above.

run_report "Top ${TOP_N} IP addresses with the most requests" \
    '{if (NF>=6) {n=split($1,a," "); if (n>=1) print a[1]}}'

run_report "Top ${TOP_N} most requested paths" \
    '{if (NF>=6) {n=split($2,r," "); if (n>=2) print r[2]}}'

run_report "Top ${TOP_N} response status codes" \
    '{if (NF>=6) {n=split($3,s," "); if (n>=1) print s[1]}}'

run_report "Top ${TOP_N} user agents" \
    '{if (NF>=6) print $6}'
