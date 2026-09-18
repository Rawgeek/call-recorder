#!/bin/zsh
# Prove that Store-bundle Mach-O code is arm64 and resolves only to the bundle or macOS.
set -euo pipefail

task_app=${1:-}
if [[ -z "$task_app" || ! -d "$task_app/Contents" ]]; then
    print -u2 "usage: $0 /path/to/Call\\ Recorder.app"
    exit 2
fi

task_contents=$(/bin/realpath "$task_app/Contents")
typeset -a task_machos task_executables task_runpaths
typeset -A task_seen task_active

while IFS= read -r -d '' task_candidate; do
    if file -b "$task_candidate" | grep -q 'Mach-O'; then
        task_machos+=("$task_candidate")
        if ! lipo -verify_arch arm64 "$task_candidate" >/dev/null 2>&1; then
            print -u2 "Store Mach-O does not contain arm64: $task_candidate"
            exit 1
        fi
        if file -b "$task_candidate" | grep -q 'executable'; then
            task_executables+=("$task_candidate")
        fi
    fi
done < <(/usr/bin/find "$task_contents" -type f -print0)

if (( ! ${#task_executables[@]} )); then
    print -u2 "Store bundle contains no Mach-O executable"
    exit 1
fi

store_load_commands() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 ~ /^LC_(LOAD|LOAD_WEAK|REEXPORT|LOAD_UPWARD)_DYLIB$/ {
            wanted = 1
            next
        }
        wanted && $1 == "name" {
            print $2
            wanted = 0
        }
    '
}

store_rpaths() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" {
            wanted = 1
            next
        }
        wanted && $1 == "path" {
            print $2
            wanted = 0
        }
    '
}

canonical_store_path() {
    local task_candidate=$1
    local task_real

    case "$task_candidate" in
        ../*|*/../*|*/..)
            return 1
            ;;
    esac
    case "$task_candidate" in
        /System/Library/*|/usr/lib/*)
            # dyld shared-cache libraries need not exist as standalone filesystem entries.
            print -r -- "$task_candidate"
            return 0
            ;;
    esac
    task_real=$(/bin/realpath "$task_candidate" 2>/dev/null) || return 1
    [[ "$task_real" == "$task_contents"/* ]] || return 1
    print -r -- "$task_real"
}

expand_store_path() {
    local task_value=$1 task_loader_directory=$2 task_executable_directory=$3
    local task_candidate

    case "$task_value" in
        @loader_path*)
            task_candidate="$task_loader_directory${task_value#@loader_path}"
            ;;
        @executable_path*)
            task_candidate="$task_executable_directory${task_value#@executable_path}"
            ;;
        /*)
            task_candidate="$task_value"
            ;;
        *)
            return 1
            ;;
    esac
    canonical_store_path "$task_candidate"
}

resolve_store_load() {
    local task_load=$1 task_loader_directory=$2 task_executable_directory=$3
    local task_candidate task_rpath

    case "$task_load" in
        @rpath/*)
            for task_rpath in "${task_runpaths[@]}"; do
                task_candidate=$(canonical_store_path \
                    "$task_rpath/${task_load#@rpath/}" 2>/dev/null) || continue
                print -r -- "$task_candidate"
                return 0
            done
            return 1
            ;;
        *)
            expand_store_path "$task_load" "$task_loader_directory" \
                "$task_executable_directory"
            ;;
    esac
}

check_store_image() {
    local task_image=$1 task_executable_directory=$2
    local task_key="$task_executable_directory|$task_image"
    local task_loader_directory=${task_image:h}
    local task_rpath task_expanded task_load task_resolved
    local -a task_saved_runpaths=("${task_runpaths[@]}")

    [[ -z "${task_active[$task_key]:-}" ]] || return 0
    task_active[$task_key]=1
    task_seen[$task_image]=1

    while IFS= read -r task_rpath; do
        task_expanded=$(expand_store_path "$task_rpath" "$task_loader_directory" \
            "$task_executable_directory" 2>/dev/null) || {
            print -u2 "unsupported or external LC_RPATH $task_rpath in $task_image"
            exit 1
        }
        task_runpaths+=("$task_expanded")
    done < <(store_rpaths "$task_image")

    while IFS= read -r task_load; do
        task_resolved=$(resolve_store_load "$task_load" "$task_loader_directory" \
            "$task_executable_directory" 2>/dev/null) || {
            print -u2 "unresolved or external dynamic dependency $task_load in $task_image"
            exit 1
        }
        case "$task_resolved" in
            /System/Library/*|/usr/lib/*)
                continue
                ;;
        esac
        if [[ ! -f "$task_resolved" ]] || ! file -b "$task_resolved" | grep -q 'Mach-O'; then
            print -u2 "dynamic dependency is not bundled Mach-O code: $task_resolved"
            exit 1
        fi
        check_store_image "$task_resolved" "$task_executable_directory"
    done < <(store_load_commands "$task_image")

    task_runpaths=("${task_saved_runpaths[@]}")
    unset "task_active[$task_key]"
}

for task_executable in "${task_executables[@]}"; do
    task_runpaths=()
    check_store_image "$task_executable" "${task_executable:h}"
done

for task_candidate in "${task_machos[@]}"; do
    if [[ -z "${task_seen[$task_candidate]:-}" ]]; then
        print -u2 "Mach-O has no provable executable load path: $task_candidate"
        exit 1
    fi
done

print "PASS: arm64 Mach-O dependency closure is self-contained"
