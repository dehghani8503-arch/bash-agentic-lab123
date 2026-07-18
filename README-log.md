# Nginx Log Analyzer

A small, dependency-free Bash tool that parses an nginx access log
(combined log format) and reports the top IP addresses, requested
paths, status codes, and user agents.

Two implementations are included, producing identical output:

| Script | Field extraction |
|---|---|
| `nginx_log_analyzer.sh` | `awk` |
| `nginx_log_analyzer_grepsed.sh` | `grep` + `sed` (stretch-goal alternative) |

## Requirements

- Bash 4+ (uses `[[ ]]`, `local`, `readonly`)
- Standard POSIX utilities: `awk`, `grep`, `sed`, `sort`, `uniq`, `head`, `wc`
- No external dependencies, no internet access needed at runtime

Tested on Linux (GNU coreutils). Field extraction avoids GNU-only
`awk`/`sort` extensions, so it should also run on macOS/BSD, though
this hasn't been verified there directly.

## Expected log format

Both scripts expect the nginx **combined** log format:

```
IP - - [date] "METHOD path HTTP/x.x" status size "referrer" "user agent"
```

Example:

```
45.76.135.253 - - [10/Oct/2023:13:55:36 +0000] "GET /api/v1/users HTTP/1.1" 200 1024 "-" "Mozilla/5.0 (Windows NT 10.0)"
```

Lines that don't match this shape (truncated lines, custom
`log_format` directives, garbage input) are **skipped**, and the
script prints a warning to stderr with a count of how many lines were
excluded. It does not guess or partially parse malformed lines.

## Usage

```bash
./nginx_log_analyzer.sh <log_file> [top_n]
```

- `log_file` — path to an nginx access log (required)
- `top_n` — number of entries to show per report (optional, default: `5`)

The `grep`/`sed` version takes the same arguments:

```bash
./nginx_log_analyzer_grepsed.sh <log_file> [top_n]
```

### Examples

```bash
# Top 5 of everything (default)
./nginx_log_analyzer.sh access.log

# Top 10 of everything
./nginx_log_analyzer.sh access.log 10

# Make it executable first, if needed
chmod +x nginx_log_analyzer.sh
```

## Sample output

```
Top 5 IP addresses with the most requests:
45.76.135.253 - 1000 requests
142.93.143.8 - 600 requests
178.128.94.113 - 50 requests
43.224.43.187 - 30 requests
91.132.10.4 - 20 requests

Top 5 most requested paths:
/api/v1/users - 1000 requests
/api/v1/products - 600 requests
/api/v1/orders - 50 requests
/api/v1/payments - 30 requests
/api/v1/reviews - 20 requests

Top 5 response status codes:
200 - 1000 requests
404 - 600 requests
500 - 50 requests
401 - 30 requests
304 - 20 requests

Top 5 user agents:
Mozilla/5.0 (Windows NT 10.0) - 800 requests
curl/7.68.0 - 400 requests
...
```

If a log contains malformed lines, a warning like this is printed to
stderr (reports on stdout are unaffected, so you can still redirect
cleanly):

```
Warning: 3 of 1500 lines do not match the
expected combined log format and may be excluded or misparsed.
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Bad usage, missing/unreadable/empty log file, or invalid `top_n` |

## Design notes

- **Field parsing** splits each line on `"` (double quote) rather than
  on whitespace. The request, referrer, and user-agent fields are all
  quoted and can contain spaces, so naive whitespace/column-based
  parsing (e.g. plain `awk '{print $7}'`) silently breaks on real
  traffic. Splitting on quotes first, then whitespace within each
  quoted/unquoted segment, is robust to that.
- **`LC_ALL=C`** is set before sorting for speed and to make sort
  order independent of the machine's locale.
- **Tie-breaking** in the rankings is explicit (`sort -k1,1nr -k2`):
  count descending, then value ascending. This keeps output
  deterministic across different `sort` implementations (GNU vs.
  BSD/macOS) when two entries have the same count.
- **`set -e` is intentionally not used.** Pipelines ending in `head`
  cause an upstream `sort` to receive `SIGPIPE` once `head` stops
  reading; combined with `set -e` this would abort the script even
  though nothing went wrong. Errors are instead checked explicitly
  (file existence/readability/emptiness, argument validation).
- **Malformed lines are excluded, not guessed at**, from every report
  consistently — the warning count and the actual report output never
  disagree with each other.

## Known limitations

- Assumes the standard nginx combined log format; a custom
  `log_format` directive with a different field order will not parse
  correctly (the script will report this via the malformed-line
  warning rather than fail silently).
- Not benchmarked on multi-GB log files; for very large logs consider
  streaming/chunking or a purpose-built tool (e.g. `goaccess`).
