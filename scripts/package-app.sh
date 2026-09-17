#!/bin/zsh
set -euo pipefail

task_root=${0:A:h:h}
task_bun=${CALL_RECORDER_BUN:-}
if [[ -z "$task_bun" ]]; then
    task_bun=$(command -v bun || true)
fi
if [[ ! -x "$task_bun" ]]; then
    print -u2 "bun is required; set CALL_RECORDER_BUN to its executable path"
    exit 1
fi

task_identity=${CALL_RECORDER_SIGNING_IDENTITY:-Call Recorder Local Development}
task_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$task_root/Resources/Info.plist")
task_output=${1:-"$task_root/dist/Call Recorder $task_version"}
task_archive="$task_output.zip"
task_stamp="$(date '+%Y%m%d-%H%M%S')-$$"
task_temp=$(mktemp -d /tmp/call-recorder-release.XXXXXX)
[[ "$task_temp" == /tmp/call-recorder-release.* ]] || exit 1
trap 'rm -rf -- "$task_temp"' EXIT

task_app="$task_temp/Call Recorder.app"
task_contents="$task_app/Contents"
task_indexer="$task_contents/Resources/indexer"
task_modules="$task_indexer/node_modules"
task_packages="$task_root/mcp/node_modules/.pnpm"

task_signing_probe="$task_temp/signing-probe"
task_signing_error="$task_temp/signing-error.txt"
cp /usr/bin/true "$task_signing_probe"
if ! codesign --force --sign "$task_identity" "$task_signing_probe" 2>"$task_signing_error"; then
    print -u2 "Code-signing key is unavailable; build not started."
    command cat "$task_signing_error" >&2
    print -u2 "Unlock once, then rerun: security unlock-keychain ~/Library/Keychains/login.keychain-db"
    exit 1
fi

cd "$task_root"
swift build -c release
mkdir -p \
    "$task_contents/MacOS" \
    "$task_modules/@libsql" \
    "$task_modules/@huggingface" \
    "$task_modules/@img" \
    "$task_modules/@neon-rs" \
    "$task_modules/onnxruntime-node/bin/napi-v6/darwin/arm64"
cp .build/release/CallRecorder "$task_contents/MacOS/CallRecorder"
cp Resources/Info.plist "$task_contents/Info.plist"
cp Resources/AppIcon.icns "$task_contents/Resources/AppIcon.icns"
cp Sources/CallRecorderApp/diarize.py "$task_contents/Resources/diarize.py"
cp Resources/ggml-silero-v6.2.0.bin "$task_contents/Resources/ggml-silero-v6.2.0.bin"
cp "$task_bun" "$task_indexer/bun"
chmod 755 "$task_contents/MacOS/CallRecorder" "$task_indexer/bun"
/usr/bin/strip -S "$task_contents/MacOS/CallRecorder"

"$task_bun" build --target bun \
    --external libsql \
    --external @huggingface/transformers \
    --external onnxruntime-node \
    --external sharp \
    --external @libsql/darwin-arm64 \
    mcp/src/index-call.ts \
    --outfile "$task_indexer/indexer.js"
"$task_bun" build --target bun \
    --external libsql \
    --external @huggingface/transformers \
    --external onnxruntime-node \
    --external sharp \
    --external @libsql/darwin-arm64 \
    mcp/src/server.ts \
    --outfile "$task_indexer/mcp-server.js"

ditto "$task_packages/@libsql+darwin-arm64@0.5.29/node_modules/@libsql/darwin-arm64" "$task_modules/@libsql/darwin-arm64"
ditto "$task_packages/libsql@0.5.29/node_modules/libsql" "$task_modules/libsql"
ditto "$task_packages/@neon-rs+load@0.0.4/node_modules/@neon-rs/load" "$task_modules/@neon-rs/load"
ditto "$task_packages/@huggingface+transformers@4.2.0/node_modules/@huggingface/transformers" "$task_modules/@huggingface/transformers"
cp "$task_packages/onnxruntime-node@1.24.3/node_modules/onnxruntime-node/package.json" "$task_modules/onnxruntime-node/package.json"
ditto "$task_packages/onnxruntime-node@1.24.3/node_modules/onnxruntime-node/dist" "$task_modules/onnxruntime-node/dist"
ditto "$task_packages/onnxruntime-node@1.24.3/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64" "$task_modules/onnxruntime-node/bin/napi-v6/darwin/arm64"
ditto "$task_packages/onnxruntime-common@1.24.3/node_modules/onnxruntime-common" "$task_modules/onnxruntime-common"
ditto "$task_packages/sharp@0.35.4/node_modules/sharp" "$task_modules/sharp"
ditto "$task_packages/detect-libc@2.1.2/node_modules/detect-libc" "$task_modules/detect-libc"
ditto "$task_packages/semver@7.8.5/node_modules/semver" "$task_modules/semver"
ditto "$task_packages/@img+colour@1.1.0/node_modules/@img/colour" "$task_modules/@img/colour"
ditto "$task_packages/@img+sharp-darwin-arm64@0.35.4/node_modules/@img/sharp-darwin-arm64" "$task_modules/@img/sharp-darwin-arm64"
ditto "$task_packages/@img+sharp-libvips-darwin-arm64@1.3.3/node_modules/@img/sharp-libvips-darwin-arm64" "$task_modules/@img/sharp-libvips-darwin-arm64"

task_required=(
    "$task_contents/MacOS/CallRecorder"
    "$task_contents/Info.plist"
    "$task_contents/Resources/diarize.py"
    "$task_contents/Resources/ggml-silero-v6.2.0.bin"
    "$task_indexer/bun"
    "$task_indexer/indexer.js"
    "$task_indexer/mcp-server.js"
)
for task_file in "${task_required[@]}"; do
    if [[ ! -s "$task_file" ]]; then
        print -u2 "required bundle file is missing or empty: $task_file"
        exit 1
    fi
done
task_vad="$task_contents/Resources/ggml-silero-v6.2.0.bin"
if [[ "$(stat -f%z "$task_vad")" != "885098" ]]; then
    print -u2 "Silero VAD model has the wrong size"
    exit 1
fi
if [[ "$(shasum -a 256 "$task_vad" | awk '{print $1}')" != "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987" ]]; then
    print -u2 "Silero VAD model failed integrity verification"
    exit 1
fi
plutil -lint "$task_contents/Info.plist" >/dev/null
if rg --files "$task_app" | rg -q '\.(db|sqlite|sqlite3)(-wal|-shm)?$'; then
    print -u2 "database files must not be bundled"
    exit 1
fi
if rg -a -q 'hf_[A-Za-z0-9_-]{12,}' "$task_app"; then
    print -u2 "a Hugging Face token-like value was found in the bundle"
    exit 1
fi
if rg -a -F -q "$task_root" "$task_app"; then
    print -u2 "the bundle contains an absolute workspace path"
    exit 1
fi
if rg -a -F -q 'Documents/Codex/' "$task_app"; then
    print -u2 "the bundle contains a home-relative development path"
    exit 1
fi
if rg -a -F -q '/.venv/bin/python3' "$task_app"; then
    print -u2 "the bundle contains a development virtualenv path"
    exit 1
fi

codesign --force --deep --options runtime \
    --sign "$task_identity" \
    --entitlements Resources/CallRecorder.entitlements \
    "$task_app"
codesign --verify --deep --strict --verbose=2 "$task_app"

if [[ -e "$task_output" ]]; then
    mv "$task_output" "$task_output.previous-$task_stamp"
fi
if [[ -e "$task_archive" ]]; then
    mv "$task_archive" "$task_archive.previous-$task_stamp"
fi
mkdir -p "${task_output:h}"
mkdir -p "$task_output"
ditto "$task_app" "$task_output/Call Recorder.app"
cp DISTRIBUTION_README.txt "$task_output/README.txt"
ditto -c -k --sequesterRsrc --keepParent "$task_output" "$task_archive"
print "$task_archive"
