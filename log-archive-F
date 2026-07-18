#!/bin/bash
#
# log-archive
#
# A simple CLI tool that compresses a log directory into a timestamped
# tar.gz archive, and records the operation in a log file.
#
# Usage:
#   log-archive <log-directory>
#
# Example:
#   log-archive /var/log/myapp
#

# ---------------------------------------------------------------------------
# STEP 1: Check that the user gave us exactly one argument.
#
# "$#" holds the number of arguments passed to the script.
# If it's not equal to 1, the user either gave nothing or too many args.
# ---------------------------------------------------------------------------
if [ "$#" -ne 1 ]; then
    echo "Error: exactly one directory argument is required."
    echo "Usage: log-archive <log-directory>"
    exit 1
fi

# ---------------------------------------------------------------------------
# STEP 2: Store the argument in a clearly named variable.
#
# Quoting "$1" protects us from word-splitting if the path has spaces.
# ---------------------------------------------------------------------------
log_dir="$1"

# ---------------------------------------------------------------------------
# STEP 3: Validate that the given path is actually a directory.
#
# "-d" is a test operator that checks: does this path exist AND is it
# a directory (not a regular file)?
# ---------------------------------------------------------------------------
if [ ! -d "$log_dir" ]; then
    echo "Error: '$log_dir' is not a valid directory."
    exit 2
fi

# ---------------------------------------------------------------------------
# STEP 4: Define where archives and the log file will live.
#
# We keep everything inside a fixed "archive" folder in the current
# working directory, so re-running the tool always looks in the same place.
# ---------------------------------------------------------------------------
archive_dir="archive"
log_file="$archive_dir/archive.log"

# ---------------------------------------------------------------------------
# STEP 5: Create the archive directory if it doesn't already exist.
#
# "mkdir -p" creates the directory only if needed, and does not error
# out if it already exists. We still check whether it succeeded, since
# it can fail if we don't have permission to create it here (for
# example, if the current working directory is read-only).
# ---------------------------------------------------------------------------
if ! mkdir -p "$archive_dir"; then
    echo "Error: unable to create archive directory '$archive_dir' (permission denied)."
    exit 3
fi

# ---------------------------------------------------------------------------
# STEP 6: Build a timestamp and the final archive filename.
#
# "date +%Y%m%d_%H%M%S" produces something like: 20240816_100648
# We then plug that into the required filename format.
# ---------------------------------------------------------------------------
timestamp=$(date +%Y%m%d_%H%M%S)
archive_name="logs_archive_${timestamp}.tar.gz"
archive_path="$archive_dir/$archive_name"

# ---------------------------------------------------------------------------
# STEP 7: Create the compressed archive with tar, and check whether it
# succeeded.
#
#   -c  create a new archive
#   -z  compress the archive using gzip
#   -f  the archive filename that follows
#
# "basename" gets just the final folder name from the path (e.g. "myapp"
# from "/var/log/myapp"), and we archive from its parent directory.
# This keeps the folder structure inside the archive clean, instead of
# storing full absolute paths.
#
# Running the command directly inside "if ! ...; then" checks its exit
# status right away: 0 means success, anything else means failure (for
# example, permission denied while writing the archive file).
# ---------------------------------------------------------------------------
dir_name=$(basename "$log_dir")
parent_dir=$(dirname "$log_dir")

if ! tar -czf "$archive_path" -C "$parent_dir" "$dir_name"; then
    echo "Error: failed to create archive (permission denied or tar error)."
    exit 3
fi

# ---------------------------------------------------------------------------
# STEP 8: Record this archive operation in the log file.
#
# We append (>>) a line containing the timestamp, the archive filename,
# and the original source directory.
# ---------------------------------------------------------------------------
echo "$(date '+%Y-%m-%d %H:%M:%S') - Archived '$log_dir' -> '$archive_path'" >> "$log_file"

# ---------------------------------------------------------------------------
# STEP 9: Let the user know it worked.
# ---------------------------------------------------------------------------
echo "Success: '$log_dir' archived to '$archive_path'"
exit 0
