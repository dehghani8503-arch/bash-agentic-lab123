# log-archive

A simple command-line tool that compresses a log directory into a
timestamped `tar.gz` archive, and keeps a log of every archive operation.

## Project overview

`log-archive` takes one directory as input, compresses its contents into
a `.tar.gz` archive with a timestamped filename, stores that archive in
an `archive/` folder (created automatically if it doesn't exist), and
appends a record of the operation (date/time, archive filename, source
directory) to an archive log file.

## Requirements

- Bash (any recent version)
- `tar` (standard on Linux/macOS)
- No external dependencies

## Installation

1. Save the script as `log-archive`.
2. Make it executable:

   ```bash
   chmod +x log-archive
   ```

3. (Optional) Move it somewhere on your `PATH` so you can run it from
   anywhere:

   ```bash
   sudo mv log-archive /usr/local/bin/
   ```

## Usage

```bash
log-archive <log-directory>
```

- `<log-directory>` — path to the directory containing the logs you want
  to archive.

## Example command

```bash
./log-archive /var/log/myapp
```

## Example output

```
Success: '/var/log/myapp' archived to 'archive/logs_archive_20240816_100648.tar.gz'
```

## Archive location

Archives are stored in an `archive/` folder created in the current
working directory (the directory you run the script from). Each archive
is named:

```
logs_archive_YYYYMMDD_HHMMSS.tar.gz
```

Example: `logs_archive_20240816_100648.tar.gz`

## Log file location

Every archive operation is recorded in:

```
archive/archive.log
```

Each line records the date/time, the source directory, and the
resulting archive filename, for example:

```
2024-08-16 10:06:48 - Archived '/var/log/myapp' -> 'archive/logs_archive_20240816_100648.tar.gz'
```
