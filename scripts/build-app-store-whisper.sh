#!/bin/zsh
# Build the pinned whisper.cpp release as one arm64 helper with no non-system dylib dependencies.
set -euo pipefail

task_root=${0:A:h:h}
task_version=1.9.4
task_source_sha=57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae
task_archive=${1:-}
task_output=${2:-"$task_root/dist/AppStoreInputs/whisper.cpp-$task_version"}

if [[ -z "$task_archive" || ! -f "$task_archive" ]]; then
    print -u2 "usage: $0 /path/to/whisper.cpp-v$task_version.tar.gz [output-directory]"
    print -u2 "Expected source SHA-256: $task_source_sha"
    exit 2
fi
if [[ -e "$task_output" ]]; then
    print -u2 "output already exists; choose an empty path: $task_output"
    exit 2
fi
for task_tool in cmake file lipo otool shasum strip tar; do
    command -v "$task_tool" >/dev/null || {
        print -u2 "required build tool is unavailable: $task_tool"
        exit 2
    }
done

task_actual_sha=$(/usr/bin/shasum -a 256 "$task_archive" | awk '{print $1}')
if [[ "$task_actual_sha" != "$task_source_sha" ]]; then
    print -u2 "source archive SHA-256 does not match whisper.cpp v$task_version"
    exit 2
fi
while IFS= read -r task_entry; do
    case "$task_entry" in
        /*|../*|*/../*|*/..)
            print -u2 "source archive contains an unsafe path: $task_entry"
            exit 2
            ;;
    esac
done < <(/usr/bin/tar -tzf "$task_archive")

task_temp=$(mktemp -d /tmp/call-recorder-whisper.XXXXXX)
[[ "$task_temp" == /tmp/call-recorder-whisper.* ]] || exit 1
trap 'rm -rf -- "$task_temp"' EXIT
/usr/bin/tar -xzf "$task_archive" -C "$task_temp"
task_source="$task_temp/whisper.cpp-$task_version"
task_build="$task_temp/build"
task_prepared="$task_temp/prepared"
[[ -s "$task_source/CMakeLists.txt" && -s "$task_source/LICENSE" ]] || {
    print -u2 "pinned archive does not have the expected whisper.cpp source layout"
    exit 2
}

task_flags=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_STATIC=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS=ON
    -DGGML_BLAS_VENDOR=Apple
    -DWHISPER_BUILD_IS_DEV=OFF
    -DWHISPER_BUILD_EXAMPLES=ON
    -DWHISPER_BUILD_SERVER=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_COMMON_FFMPEG=OFF
)
cmake -S "$task_source" -B "$task_build" "${task_flags[@]}"
cmake --build "$task_build" --config Release --target whisper-cli --parallel

task_binary="$task_build/bin/whisper-cli"
[[ -x "$task_binary" ]] || task_binary="$task_build/bin/Release/whisper-cli"
[[ -x "$task_binary" ]] || {
    print -u2 "whisper-cli was not produced at an expected path"
    exit 1
}

mkdir -p "$task_prepared"
cp "$task_binary" "$task_prepared/whisper-cli"
cp "$task_source/LICENSE" "$task_prepared/whisper.cpp-LICENSE.txt"
/usr/bin/strip -x -S "$task_prepared/whisper-cli"
chmod 755 "$task_prepared/whisper-cli"
file -b "$task_prepared/whisper-cli" | grep -q 'Mach-O' || {
    print -u2 "built helper is not Mach-O"
    exit 1
}
lipo -verify_arch arm64 "$task_prepared/whisper-cli" >/dev/null || {
    print -u2 "built helper does not contain arm64"
    exit 1
}
while IFS= read -r task_load; do
    case "$task_load" in
        /System/Library/*|/usr/lib/*) ;;
        *)
            print -u2 "built helper has a non-system dynamic dependency: $task_load"
            exit 1
            ;;
    esac
done < <(otool -L "$task_prepared/whisper-cli" | tail -n +2 | awk '{print $1}')

{
    print "whisper.cpp version: $task_version"
    print "source archive SHA-256: $task_source_sha"
    print "minimum macOS: 15.0"
    print "architecture: arm64"
    print "CMake flags: ${(j: :)task_flags}"
    print "dynamic dependencies:"
    otool -L "$task_prepared/whisper-cli" | tail -n +2
} > "$task_prepared/whisper-build.txt"
(cd "$task_prepared" && /usr/bin/shasum -a 256 \
    whisper-cli whisper.cpp-LICENSE.txt whisper-build.txt > INPUT-SHA256SUMS)
mkdir -p "${task_output:h}"
mv "$task_prepared" "$task_output"

print "Prepared verified App Store helper inputs in: $task_output"
print "Set package inputs to:"
print "  CALL_RECORDER_APP_STORE_WHISPER_CLI='$task_output/whisper-cli'"
print "  CALL_RECORDER_APP_STORE_WHISPER_CLI_SHA256='$(awk '$2 == "whisper-cli" { print $1 }' "$task_output/INPUT-SHA256SUMS")'"
print "  CALL_RECORDER_APP_STORE_WHISPER_LICENSE='$task_output/whisper.cpp-LICENSE.txt'"
print "  CALL_RECORDER_APP_STORE_WHISPER_LICENSE_SHA256='$(awk '$2 == "whisper.cpp-LICENSE.txt" { print $1 }' "$task_output/INPUT-SHA256SUMS")'"
