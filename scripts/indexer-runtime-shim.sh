#!/bin/sh
# The entry point Call Recorder and Codex both start.
#
# The JavaScript runtime is 95 MB unpacked and 36 MB archived, and an app that carried it shipped
# 49 MB to every Mac. It travels as a release asset instead: the app downloads the archive with a
# progress bar and leaves it in Application Support, and this script unpacks it once. A build that
# wants to carry everything can still place the archive beside this script, and that copy wins.
# The path in the app bundle never changes, so a Codex registration written by hand or by an
# earlier version keeps working.
#
# Two processes can race here: the app starts indexing while the app's own launch task is still
# running, or Codex starts the MCP server with no app running at all. The first to take the lock
# unpacks; the others wait for it, and unpack themselves only if it fails. Codex can start with no
# app running and no archive downloaded, so this script can fetch the archive itself as well.
set -eu

runtime_root="${CALL_RECORDER_RUNTIME_DIR:-$HOME/Library/Application Support/CallRecorder/runtime}"
bundle_dir=$(cd "$(dirname "$0")" && pwd)
archive="$bundle_dir/runtime.zip"
archive_hash_file="$bundle_dir/runtime.sha256"
# Where the archive can be fetched when the app does not carry one. One line, written when the app
# was built, naming the release asset that holds this archive.
archive_url_file="$bundle_dir/runtime.url"
# The app downloads the archive here, so fetching it once is enough for every later unpack.
support_directory="$(dirname "$runtime_root")"
downloaded_archive="$support_directory/runtime.zip"
# CALL_RECORDER_LOG_DIR keeps the log out of the real home during a test run.
log_directory="${CALL_RECORDER_LOG_DIR:-$HOME/Library/Logs/CallRecorder}"
log_file="$log_directory/indexer-runtime.log"
lock_directory="$runtime_root.lock"
ready_file="$runtime_root/.ready"

mkdir -p "$log_directory"
# The lock and the runtime both live here. Without the parent, taking the lock fails, and a failed
# lock would otherwise read as another process holding it.
mkdir -p "$(dirname "$runtime_root")" || {
    printf 'call-recorder indexer runtime: cannot create %s\n' "$(dirname "$runtime_root")" >&2
    exit 1
}

report() {
    # Every line is stamped. A log without one made a failure from an hour ago read like the
    # failure that had just happened.
    printf '%s call-recorder indexer runtime: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" \
        | tee -a "$log_file" >&2
}

# Removes a downloaded archive that turned out to be unusable, never one the app carries. A bad
# download must not be kept, or every later start would read the same broken file and fail the
# same way. A good one is kept, so a later unpack does not fetch it again.
discard_downloaded_archive() {
    if [ "${archive_from_download:-0}" = "1" ] && [ -f "$downloaded_archive" ]; then
        rm -f -- "$downloaded_archive"
    fi
}

fail() {
    report "$1"
    exit 1
}

# Reads the hash the app was built with. It returns a status rather than reporting, because a
# command substitution would swallow a call to exit and let the caller compare against nothing.
read_expected_hash() {
    [ -f "$archive_hash_file" ] || return 1
    tr -d '[:space:]' < "$archive_hash_file"
}

is_ready() {
    [ -f "$ready_file" ] || return 1
    [ -x "$runtime_root/bun" ] || return 1
    expected=$(read_expected_hash) || return 1
    [ "$(tr -d '[:space:]' < "$ready_file")" = "$expected" ] || return 1
    return 0
}

# Fetches the archive when neither the app nor Application Support holds one.
#
# Returns 1 when this build has nowhere to fetch from, and reports and exits when a fetch was
# attempted and failed.
fetch_archive() {
    [ -f "$archive_url_file" ] || return 1
    archive_url=$(tr -d '[:space:]' < "$archive_url_file")
    [ -n "$archive_url" ] || return 1
    mkdir -p "$support_directory" || fail "cannot create $support_directory"
    staging_download="$downloaded_archive.partial.$$"
    report "downloading the indexer runtime from $archive_url"
    # Codex starts this script with an environment of its own, so the fetcher is named by path when
    # the machine has one there.
    curl_bin=/usr/bin/curl
    [ -x "$curl_bin" ] || curl_bin=curl
    if ! "$curl_bin" --fail --location --silent --show-error --output "$staging_download" \
        "$archive_url" >>"$log_file" 2>&1; then
        rm -f -- "$staging_download"
        fail "the indexer runtime could not be downloaded from $archive_url"
    fi
    mv "$staging_download" "$downloaded_archive" || {
        rm -f -- "$staging_download"
        fail "cannot keep the downloaded runtime archive at $downloaded_archive"
    }
    archive="$downloaded_archive"
    archive_from_download=1
    return 0
}

# Unpacks into a staging folder, checks the archive against the hash the app was built with, and
# only then moves it into place. A half-unpacked runtime is never visible to a running process.
unpack() {
    # The archive the app carries wins; then the one a previous download left in Application
    # Support; then a download.
    if [ ! -f "$archive" ] && [ -f "$downloaded_archive" ]; then
        archive="$downloaded_archive"
        archive_from_download=1
    fi
    if [ ! -f "$archive" ]; then
        fetch_archive || fail "this build has no runtime archive and nothing to fetch one from"
    fi
    expected=$(read_expected_hash) \
        || fail "the app is missing runtime.sha256 beside the runtime archive"
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        discard_downloaded_archive
        fail "the runtime archive does not match the hash recorded when the app was built"
    fi

    staging="$runtime_root.incoming.$$"
    if [ -e "$staging" ]; then
        fail "a previous unpack left $staging behind; move it aside and start again"
    fi
    mkdir -p "$staging" || fail "cannot create $staging"
    if ! ditto -x -k "$archive" "$staging" >>"$log_file" 2>&1; then
        discard_downloaded_archive
        report "unpacking the runtime archive failed; the archive may be incomplete"
        exit 1
    fi
    if [ ! -x "$staging/bun" ]; then
        chmod 755 "$staging/bun" 2>/dev/null || true
    fi
    [ -x "$staging/bun" ] || fail "the unpacked runtime has no usable bun executable"

    previous="$runtime_root.previous.$$"
    if [ -e "$runtime_root" ]; then
        mv "$runtime_root" "$previous" || fail "cannot move the earlier runtime aside"
    fi
    if ! mv "$staging" "$runtime_root"; then
        [ -e "$previous" ] && mv "$previous" "$runtime_root" || true
        fail "cannot move the new runtime into place"
    fi
    if [ -e "$previous" ]; then
        case "$previous" in
            */CallRecorder/runtime.previous.*) rm -rf -- "$previous" ;;
            *) report "leaving an unexpected folder in place: $previous" ;;
        esac
    fi
    printf '%s' "$expected" > "$ready_file"
}

ensure_runtime() {
    if is_ready; then
        return 0
    fi
    if mkdir "$lock_directory" 2>/dev/null; then
        trap 'rmdir "$lock_directory" 2>/dev/null || true' EXIT INT TERM
        if ! is_ready; then
            unpack
        fi
        rmdir "$lock_directory" 2>/dev/null || true
        trap - EXIT INT TERM
        return 0
    fi
    # A lock that cannot be created at all is a fault here, not another process at work.
    if [ ! -d "$lock_directory" ]; then
        fail "cannot create $lock_directory"
    fi
    # Another process holds the lock. Wait for its runtime rather than unpacking over it.
    waited=0
    deadline=${CALL_RECORDER_RUNTIME_WAIT_SECONDS:-180}
    while [ "$waited" -lt "$deadline" ]; do
        if is_ready; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "another process is unpacking the runtime and did not finish within $deadline seconds"
}

if [ "$#" -eq 0 ]; then
    fail "usage: bun <script.js> [arguments...]"
fi

if [ "$1" = "--ensure-runtime" ]; then
    ensure_runtime
    exit 0
fi

# The app passes the script inside its own bundle. The runtime keeps its own copy, and the two are
# unpacked and built together, so the name decides which entry point runs.
case "${1##*/}" in
    indexer.js) entry=indexer.js ;;
    *) entry=mcp-server.js ;;
esac
shift

ensure_runtime
exec "$runtime_root/bun" "$runtime_root/$entry" "$@"
