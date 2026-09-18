#!/bin/zsh
# Builds the app bundle that is handed to someone else.
#
# The signature is what macOS recognises an app by, and a signing key lives in the keychain, which
# asks for a password. A build that stays on this machine therefore needs no keychain at all: with
# no identity named, the bundle is signed ad-hoc. Name one to make a build that ships, or to replace
# an installed app without macOS asking for the microphone and screen-recording permissions again:
#
#   CALL_RECORDER_SIGNING_IDENTITY="Call Recorder Local Development" scripts/package-app.sh
#
# Set CALL_RECORDER_SKIP_SIGNING=1 to build the same bundle with no signature at all. That is for
# measuring and inspecting a build on a machine where nobody is sitting in front of it. The result
# cannot be shared: macOS refuses an unsigned copy of an app it did not build.
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

task_identity=${CALL_RECORDER_SIGNING_IDENTITY:-}
task_skip_signing=${CALL_RECORDER_SKIP_SIGNING:-0}
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
# The JavaScript runtime is built here and shipped as one archive. Unpacked it is about 95 MB and
# archived it is about 36 MB, which was most of the app: 36 MB of a 49 MB download. It travels as
# a release asset instead, and the bundle keeps only its hash and the address to fetch it from.
# The app downloads the archive, and the shim beside it unpacks it once into Application Support.
# scripts/indexer-runtime-shim.sh stays the path Codex registers, so an existing registration
# keeps working, and it can fetch the archive itself when Codex starts with no app running.
#
# Set CALL_RECORDER_EMBED_RUNTIME=1 to build a self-contained app instead: the archive travels
# inside the bundle and no fetch is ever needed. That build is for a machine with no network.
task_runtime="$task_temp/runtime"
task_verify="$task_temp/verify-runtime"
task_packages="$task_root/mcp/node_modules/.pnpm"
task_onnx_dylib="libonnxruntime.1.24.3.dylib"

task_signing_probe="$task_temp/signing-probe"
task_signing_error="$task_temp/signing-error.txt"
if [[ "$task_skip_signing" == "1" ]]; then
    print -u2 "Building without a signature: the copy this writes cannot be shared."
elif [[ -n "$task_identity" ]]; then
    cp /usr/bin/true "$task_signing_probe"
    if ! codesign --force --sign "$task_identity" "$task_signing_probe" 2>"$task_signing_error"; then
        print -u2 "Code-signing key is unavailable; build not started."
        command cat "$task_signing_error" >&2
        print -u2 "Unlock once, then rerun: security unlock-keychain ~/Library/Keychains/login.keychain-db"
        exit 1
    fi
fi

cd "$task_root"
swift build -c release
mkdir -p \
    "$task_contents/MacOS" \
    "$task_indexer" \
    "$task_runtime/node_modules/@huggingface/transformers/dist" \
    "$task_runtime/node_modules/onnxruntime-node/dist" \
    "$task_runtime/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64" \
    "$task_runtime/node_modules/@libsql/darwin-arm64" \
    "$task_runtime/node_modules/@neon-rs/load" \
    "$task_runtime/node_modules/detect-libc" \
    "$task_runtime/node_modules/sharp"
cp .build/release/CallRecorder "$task_contents/MacOS/CallRecorder"
cp Resources/Info.plist "$task_contents/Info.plist"
cp Resources/AppIcon.icns "$task_contents/Resources/AppIcon.icns"
cp Sources/CallRecorderApp/diarize.py "$task_contents/Resources/diarize.py"
chmod 755 "$task_contents/MacOS/CallRecorder"
# The binary carries a symbol table the app never reads: 13 MB of it is 8.5 MB without one.
/usr/bin/strip -x -S "$task_contents/MacOS/CallRecorder"

# The two entry points. Minifying syntax and whitespace takes a quarter off both files; identifier
# names are kept, so a stack trace in the log still reads as code.
"$task_bun" build --target bun --minify-syntax --minify-whitespace \
    --external libsql \
    --external @huggingface/transformers \
    --external onnxruntime-node \
    --external sharp \
    --external @libsql/darwin-arm64 \
    mcp/src/index-call.ts \
    --outfile "$task_runtime/indexer.js"
"$task_bun" build --target bun --minify-syntax --minify-whitespace \
    --external libsql \
    --external @huggingface/transformers \
    --external onnxruntime-node \
    --external sharp \
    --external @libsql/darwin-arm64 \
    mcp/src/server.ts \
    --outfile "$task_runtime/mcp-server.js"
cp "$task_bun" "$task_runtime/bun"
chmod 755 "$task_runtime/bun"

# Only the files the entry points load, and only the files this Mac runs.
#
# The unpruned dependency tree is 78 MB. What is left here is 32 MB, and every folder removed is
# one nothing in the runtime reads:
# - sharp and libvips (15 MB): the image library the embedding model imports at startup for image
#   input. A stand-in in scripts/indexer-deps answers that import, so nothing else needs it.
# - the browser, CommonJS, and minified builds of the embedding library, and its types and
#   sources (7 MB): the runtime imports one file, dist/transformers.node.mjs.
# - the source maps and type declarations of the ONNX runtime: nothing reads them at run time.
ditto "$task_packages/@huggingface+transformers@4.2.0/node_modules/@huggingface/transformers/package.json" \
    "$task_runtime/node_modules/@huggingface/transformers/package.json"
ditto "$task_packages/@huggingface+transformers@4.2.0/node_modules/@huggingface/transformers/dist/transformers.node.mjs" \
    "$task_runtime/node_modules/@huggingface/transformers/dist/transformers.node.mjs"
ditto "$task_packages/libsql@0.5.29/node_modules/libsql" "$task_runtime/node_modules/libsql"
ditto "$task_packages/@libsql+darwin-arm64@0.5.29/node_modules/@libsql/darwin-arm64" \
    "$task_runtime/node_modules/@libsql/darwin-arm64"
ditto "$task_packages/@neon-rs+load@0.0.4/node_modules/@neon-rs/load" "$task_runtime/node_modules/@neon-rs/load"
# The database client reads this to pick the right binding for the platform.
ditto "$task_packages/detect-libc@2.1.2/node_modules/detect-libc" "$task_runtime/node_modules/detect-libc"
ditto "$task_packages/onnxruntime-common@1.24.3/node_modules/onnxruntime-common" \
    "$task_runtime/node_modules/onnxruntime-common"
cp "$task_packages/onnxruntime-node@1.24.3/node_modules/onnxruntime-node/package.json" \
    "$task_runtime/node_modules/onnxruntime-node/package.json"
for task_script in index.js backend.js binding.js version.js; do
    cp "$task_packages/onnxruntime-node@1.24.3/node_modules/onnxruntime-node/dist/$task_script" \
        "$task_runtime/node_modules/onnxruntime-node/dist/$task_script"
done
ditto "$task_packages/onnxruntime-node@1.24.3/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64" \
    "$task_runtime/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64"
cp scripts/indexer-deps/sharp/package.json "$task_runtime/node_modules/sharp/package.json"
cp scripts/indexer-deps/sharp/index.js "$task_runtime/node_modules/sharp/index.js"

# The largest file in the runtime is the ONNX library that runs the embedding model. Its symbols
# are not needed to load it: strip takes 36 MB down to 23 MB, and the ad-hoc signature replaces
# the one stripping invalidates.
task_onnx_path="$task_runtime/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64/$task_onnx_dylib"
/usr/bin/strip -x -S "$task_onnx_path"
codesign --force --sign - "$task_onnx_path"

task_runtime_archive="$task_temp/runtime.zip"
# The archive is built from the same tree on every release, and a zip records when each file was
# written. Those times made two builds of one runtime different bytes, which gave the same runtime
# a new address at every release and made every app update fetch all 36 MB again. The times are
# flattened and the entries are written in sorted order instead, so the same tree always produces
# the same archive, and an update that changes nothing about the runtime reuses what is unpacked.
/usr/bin/find "$task_runtime" -exec /usr/bin/touch -h -t 202001010000.00 {} +
(cd "$task_runtime" && /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort \
    | /usr/bin/zip -X -q "$task_runtime_archive" -@)
task_runtime_hash=$(shasum -a 256 "$task_runtime_archive" | awk '{print $1}')
task_runtime_short=${task_runtime_hash[1,8]}
print -n "$task_runtime_hash" > "$task_indexer/runtime.sha256"
cp scripts/indexer-runtime-shim.sh "$task_indexer/bun"
chmod 755 "$task_indexer/bun"

# The archive is published beside the app rather than inside it. The address is named for the
# bytes, so the same runtime keeps one address across app releases, and the hash written above is
# what decides whether what arrives is accepted.
mkdir -p "$task_root/dist/releases"
task_runtime_asset="$task_root/dist/releases/CallRecorder-runtime-$task_runtime_short.zip"
cp "$task_runtime_archive" "$task_runtime_asset"
if [[ "${CALL_RECORDER_EMBED_RUNTIME:-0}" == "1" ]]; then
    cp "$task_runtime_archive" "$task_indexer/runtime.zip"
else
    print -n "${CALL_RECORDER_RUNTIME_URL:-https://github.com/Rawgeek/call-recorder/releases/download/runtime-$task_runtime_short/CallRecorder-runtime-$task_runtime_short.zip}" \
        > "$task_indexer/runtime.url"
fi

# Unpack the archive here, so a build that would fail on the first recording fails now instead.
mkdir -p "$task_verify"
ditto -x -k "$task_runtime_archive" "$task_verify"
for task_member in \
    bun \
    indexer.js \
    mcp-server.js \
    "node_modules/@huggingface/transformers/dist/transformers.node.mjs" \
    "node_modules/@libsql/darwin-arm64/index.node" \
    "node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64/$task_onnx_dylib"; do
    if [[ ! -s "$task_verify/$task_member" ]]; then
        print -u2 "the runtime archive is missing $task_member"
        exit 1
    fi
done
if [[ ! -x "$task_verify/bun" ]]; then
    print -u2 "the unpacked runtime has no executable bun"
    exit 1
fi
if ! "$task_verify/bun" --version >/dev/null; then
    print -u2 "the runtime archive does not run"
    exit 1
fi

task_required=(
    "$task_contents/MacOS/CallRecorder"
    "$task_contents/Info.plist"
    "$task_contents/Resources/diarize.py"
    "$task_indexer/bun"
    "$task_indexer/runtime.sha256"
)
for task_file in "${task_required[@]}"; do
    if [[ ! -s "$task_file" ]]; then
        print -u2 "required bundle file is missing or empty: $task_file"
        exit 1
    fi
done
# The runtime is either carried or fetched, and the bundle has to say which.
if [[ ! -s "$task_indexer/runtime.zip" && ! -s "$task_indexer/runtime.url" ]]; then
    print -u2 "the bundle has no runtime archive and no address to fetch one from"
    exit 1
fi
# The Silero VAD model is a download now, and the runtime is an archive. A copy inside the bundle
# is the mistake this guards against: it is what made the app 150 MB.
if rg --files "$task_app" | rg -q 'ggml-silero'; then
    print -u2 "the Silero VAD model must be downloaded, not bundled"
    exit 1
fi
if rg --files "$task_app" | rg -q 'Resources/indexer/node_modules/'; then
    print -u2 "the indexer runtime must ship as an archive, not unpacked"
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

if [[ "$task_skip_signing" == "1" ]]; then
    print -u2 "Skipping the signature on the app bundle."
elif [[ -n "$task_identity" ]]; then
    codesign --force --deep --options runtime \
        --sign "$task_identity" \
        --entitlements Resources/CallRecorder.entitlements \
        "$task_app"
    codesign --verify --deep --strict --verbose=2 "$task_app"
else
    # A signature with no name of its own: enough for the app to run where it was built, and it
    # needs no keychain. macOS cannot recognise the app by it on another machine, so nothing built
    # this way is published.
    codesign --force --deep --options runtime \
        --sign - \
        --entitlements Resources/CallRecorder.entitlements \
        "$task_app"
    codesign --verify --deep --strict --verbose=2 "$task_app"
    print "Signed ad-hoc: this build is for this machine. Name CALL_RECORDER_SIGNING_IDENTITY to publish one."
fi

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
# The archive holds the app itself, not the folder it was staged in. The updater unpacks a
# release beside the running app and looks for the bundle inside it, and a copy of the app that
# has to be found one level down is a shape it refused the first time it met one.
ditto -c -k --sequesterRsrc --keepParent "$task_output/Call Recorder.app" "$task_archive"
print "$task_archive"
print "$task_runtime_asset"
