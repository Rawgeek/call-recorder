#!/bin/sh
# The entry point Call Recorder and Codex both start.
#
# The JavaScript runtime is 94 MB unpacked, and an app that carried it unpacked shipped 150 MB to
# every Mac. It travels inside the app as one compressed archive instead, and this script unpacks
# it once into Application Support. The path in the app bundle never changes, so a Codex
# registration written by hand or by an earlier version keeps working.
#
# Two processes can race here: the app starts indexing while the app's own launch task is still
# running, or Codex starts the MCP server with no app running at all. The first to take the lock
# unpacks; the others wait for it, and unpack themselves only if it fails.
set -eu

runtime_root="${CALL_RECORDER_RUNTIME_DIR:-$HOME/Library/Application Support/CallRecorder/runtime}"
bundle_dir=$(cd "$(dirname "$0")" && pwd)
archive="$bundle_dir/runtime.zip"
archive_hash_file="$bundle_dir/runtime.sha256"
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

# Unpacks into a staging folder, checks the archive against the hash the app was built with, and
# only then moves it into place. A half-unpacked runtime is never visible to a running process.
unpack() {
    [ -f "$archive" ] || fail "the app is missing its runtime archive at $archive"
    expected=$(read_expected_hash) \
        || fail "the app is missing runtime.sha256 beside the runtime archive"
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    [ "$expected" = "$actual" ] || fail "the runtime archive in the app does not match its recorded hash"

    staging="$runtime_root.incoming.$$"
    if [ -e "$staging" ]; then
        fail "a previous unpack left $staging behind; move it aside and start again"
    fi
    mkdir -p "$staging" || fail "cannot create $staging"
    if ! ditto -x -k "$archive" "$staging" >>"$log_file" 2>&1; then
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
