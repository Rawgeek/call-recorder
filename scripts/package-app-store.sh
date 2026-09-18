#!/bin/zsh
# Build and sign a Mac App Store installer. This script deliberately does not upload anything.
set -euo pipefail

task_root=${0:A:h:h}
task_bundle_id=${CALL_RECORDER_APP_STORE_BUNDLE_ID:-}
task_copyright=${CALL_RECORDER_APP_STORE_COPYRIGHT:-}
task_app_identity=${CALL_RECORDER_APP_STORE_APPLICATION_IDENTITY:-}
task_installer_identity=${CALL_RECORDER_APP_STORE_INSTALLER_IDENTITY:-}
task_profile=${CALL_RECORDER_APP_STORE_PROVISIONING_PROFILE:-}
task_whisper=${CALL_RECORDER_APP_STORE_WHISPER_CLI:-}
task_whisper_sha=${CALL_RECORDER_APP_STORE_WHISPER_CLI_SHA256:-}
task_whisper_license=${CALL_RECORDER_APP_STORE_WHISPER_LICENSE:-}
task_whisper_license_sha=${CALL_RECORDER_APP_STORE_WHISPER_LICENSE_SHA256:-}
task_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$task_root/Resources/Info.plist")
task_output=${1:-"$task_root/dist/AppStore"}
task_app="$task_output/Call Recorder.app"
task_pkg=${2:-"$task_output/CallRecorder-$task_version.pkg"}

task_missing=()
[[ -n "$task_bundle_id" ]] || task_missing+=(CALL_RECORDER_APP_STORE_BUNDLE_ID)
[[ -n "$task_copyright" ]] || task_missing+=(CALL_RECORDER_APP_STORE_COPYRIGHT)
[[ -n "$task_app_identity" ]] || task_missing+=(CALL_RECORDER_APP_STORE_APPLICATION_IDENTITY)
[[ -n "$task_installer_identity" ]] || task_missing+=(CALL_RECORDER_APP_STORE_INSTALLER_IDENTITY)
[[ -n "$task_profile" ]] || task_missing+=(CALL_RECORDER_APP_STORE_PROVISIONING_PROFILE)
[[ -n "$task_whisper" ]] || task_missing+=(CALL_RECORDER_APP_STORE_WHISPER_CLI)
[[ -n "$task_whisper_sha" ]] || task_missing+=(CALL_RECORDER_APP_STORE_WHISPER_CLI_SHA256)
[[ -n "$task_whisper_license" ]] || task_missing+=(CALL_RECORDER_APP_STORE_WHISPER_LICENSE)
[[ -n "$task_whisper_license_sha" ]] \
    || task_missing+=(CALL_RECORDER_APP_STORE_WHISPER_LICENSE_SHA256)
if (( ${#task_missing[@]} )); then
    print -u2 "Mac App Store packaging needs the missing release inputs listed below."
    print -u2 "Set the following environment variables:"
    printf '  %s\n' "${task_missing[@]}" >&2
    print -u2 "See AppStore/README.md. Nothing was built or uploaded."
    exit 2
fi

if [[ "$task_bundle_id" == local.* || "$task_bundle_id" == com.example.* || "$task_bundle_id" != *.* ]]; then
    print -u2 "CALL_RECORDER_APP_STORE_BUNDLE_ID must be the registered, non-placeholder App ID."
    exit 2
fi

for task_input in "$task_profile" "$task_whisper" "$task_whisper_license"; do
    if [[ ! -f "$task_input" ]]; then
        print -u2 "required App Store input is not a file: $task_input"
        exit 2
    fi
done
if [[ ! -s "$task_whisper_license" ]]; then
    print -u2 "whisper.cpp license input is empty: $task_whisper_license"
    exit 2
fi
for task_helper in "$task_whisper"; do
    if [[ ! -x "$task_helper" ]]; then
        print -u2 "prebuilt helper is not executable: $task_helper"
        exit 2
    fi
    if ! file -b "$task_helper" | grep -q 'Mach-O'; then
        print -u2 "prebuilt helper is not a macOS Mach-O binary: $task_helper"
        exit 2
    fi
done
if ! print -r -- "$task_whisper_license_sha" | grep -Eq '^[0-9A-Fa-f]{64}$'; then
    print -u2 "expected whisper.cpp license SHA-256 is not 64 hexadecimal characters"
    exit 2
fi
task_actual_license_sha=$(/usr/bin/shasum -a 256 "$task_whisper_license" | awk '{print $1}')
if [[ "${task_actual_license_sha:l}" != "${task_whisper_license_sha:l}" ]]; then
    print -u2 "whisper.cpp license SHA-256 does not match the pinned release input"
    exit 2
fi
for task_helper task_expected_sha in "$task_whisper" "$task_whisper_sha"; do
    if ! print -r -- "$task_expected_sha" | grep -Eq '^[0-9A-Fa-f]{64}$'; then
        print -u2 "expected helper SHA-256 is not 64 hexadecimal characters: $task_helper"
        exit 2
    fi
    task_actual_sha=$(/usr/bin/shasum -a 256 "$task_helper" | awk '{print $1}')
    if [[ "${task_actual_sha:l}" != "${task_expected_sha:l}" ]]; then
        print -u2 "helper SHA-256 does not match the pinned release input: $task_helper"
        exit 2
    fi
done

task_temp=$(mktemp -d /tmp/call-recorder-app-store.XXXXXX)
[[ "$task_temp" == /tmp/call-recorder-app-store.* ]] || exit 1
trap 'rm -rf -- "$task_temp"' EXIT
task_stage="$task_temp/Call Recorder.app"
task_contents="$task_stage/Contents"
task_resources="$task_contents/Resources"
task_bin="$task_resources/bin"
task_provenance="$task_resources/Provenance"
task_licenses="$task_resources/Licenses"

if ! security cms -D -i "$task_profile" > "$task_temp/profile.plist"; then
    print -u2 "provisioning profile cannot be decoded: $task_profile"
    exit 2
fi
task_profile_app_id=$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.application-identifier' \
    "$task_temp/profile.plist" 2>/dev/null || true)
if [[ -z "$task_profile_app_id" ]]; then
    # Older profiles can use the iOS-style spelling. Accept it as an input, but always sign the
    # macOS app with com.apple.application-identifier below.
    task_profile_app_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' \
        "$task_temp/profile.plist" 2>/dev/null || true)
fi
task_team_id=$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.team-identifier' \
    "$task_temp/profile.plist" 2>/dev/null || true)
if [[ -z "$task_team_id" ]]; then
    task_team_id=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' \
        "$task_temp/profile.plist" 2>/dev/null || true)
fi
if [[ -z "$task_team_id" || "$task_profile_app_id" != "$task_team_id.$task_bundle_id" ]]; then
    print -u2 "provisioning profile application-identifier does not match $task_bundle_id"
    exit 2
fi
task_resolved_entitlements="$task_temp/app-store-entitlements.plist"
cp Resources/CallRecorderAppStore.entitlements "$task_resolved_entitlements"
/usr/libexec/PlistBuddy -c \
    "Add :com.apple.application-identifier string $task_profile_app_id" \
    "$task_resolved_entitlements"
/usr/libexec/PlistBuddy -c \
    "Add :com.apple.developer.team-identifier string $task_team_id" \
    "$task_resolved_entitlements"
/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups array' "$task_resolved_entitlements"
/usr/libexec/PlistBuddy -c \
    "Add :keychain-access-groups:0 string $task_profile_app_id" \
    "$task_resolved_entitlements"

# Fail before the expensive build if the application signing key is unavailable.
cp /usr/bin/true "$task_temp/signing-probe"
if ! codesign --force --sign "$task_app_identity" "$task_temp/signing-probe"; then
    print -u2 "Mac App Store application signing identity is unavailable: $task_app_identity"
    exit 2
fi

cd "$task_root"
swift build -c release
mkdir -p "$task_contents/MacOS" "$task_resources" "$task_bin" "$task_provenance" \
    "$task_licenses"
task_libsql_license="$task_root/.build/checkouts/libsql-swift/LICENSE"
if [[ ! -s "$task_libsql_license" ]]; then
    print -u2 "the pinned libsql-swift checkout has no license file"
    exit 1
fi
task_libsql_checkout="$task_root/.build/checkouts/libsql-swift"
task_libsql_revision=$(awk '
    /"identity"[[:space:]]*:[[:space:]]*"libsql-swift"/ { in_libsql = 1 }
    in_libsql && /"revision"[[:space:]]*:/ {
        revision = $0
        sub(/^.*"revision"[[:space:]]*:[[:space:]]*"/, "", revision)
        sub(/".*$/, "", revision)
        print revision
        exit
    }
' "$task_root/Package.resolved")
if ! print -r -- "$task_libsql_revision" | grep -Eq '^[0-9a-f]{40}$'; then
    print -u2 "Package.resolved has no valid pinned libsql-swift revision"
    exit 1
fi
task_libsql_checkout_revision=$(git -C "$task_libsql_checkout" rev-parse HEAD)
if [[ "$task_libsql_checkout_revision" != "$task_libsql_revision" ]]; then
    print -u2 "libsql-swift checkout revision does not match Package.resolved"
    exit 1
fi
if [[ -n "$(git -C "$task_libsql_checkout" status --porcelain --untracked-files=no)" ]]; then
    print -u2 "libsql-swift checkout has tracked changes; refusing unproven license input"
    exit 1
fi
cp .build/release/CallRecorder "$task_contents/MacOS/CallRecorder"
cp Resources/Info.plist "$task_contents/Info.plist"
cp Resources/AppIcon.icns "$task_resources/AppIcon.icns"
cp Resources/PrivacyInfo.xcprivacy "$task_resources/PrivacyInfo.xcprivacy"
cp "$task_profile" "$task_contents/embedded.provisionprofile"
cp "$task_whisper" "$task_bin/whisper-cli"
cp "$task_whisper_license" "$task_licenses/whisper.cpp-LICENSE.txt"
cp "$task_libsql_license" "$task_licenses/libsql-swift-LICENSE.txt"
printf '%s  %s\n' "${task_whisper_sha:l}" whisper-cli \
    > "$task_provenance/whisper-input-SHA256SUMS"
printf '%s  %s\n%s  %s\n' \
    "${task_whisper_license_sha:l}" whisper.cpp-LICENSE.txt \
    "$(/usr/bin/shasum -a 256 "$task_libsql_license" | awk '{print $1}')" \
    libsql-swift-LICENSE.txt > "$task_provenance/license-input-SHA256SUMS"
printf 'identity=libsql-swift\nrevision=%s\ncheckout-clean=true\n' \
    "$task_libsql_revision" > "$task_provenance/libsql-swift-source.txt"
chmod 755 "$task_contents/MacOS/CallRecorder" "$task_bin/whisper-cli"
/usr/bin/strip -x -S "$task_contents/MacOS/CallRecorder"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $task_bundle_id" "$task_contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CRDistributionChannel app-store" "$task_contents/Info.plist"
if ! /usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright $task_copyright" \
    "$task_contents/Info.plist" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string $task_copyright" \
        "$task_contents/Info.plist"
fi

for task_required in \
    "$task_contents/MacOS/CallRecorder" \
    "$task_contents/Info.plist" \
    "$task_contents/embedded.provisionprofile" \
    "$task_resources/PrivacyInfo.xcprivacy" \
    "$task_resources/AppIcon.icns" \
    "$task_bin/whisper-cli" \
    "$task_provenance/whisper-input-SHA256SUMS" \
    "$task_provenance/license-input-SHA256SUMS" \
    "$task_provenance/libsql-swift-source.txt" \
    "$task_licenses/whisper.cpp-LICENSE.txt" \
    "$task_licenses/libsql-swift-LICENSE.txt"; do
    if [[ ! -s "$task_required" ]]; then
        print -u2 "required Store bundle file is missing or empty: $task_required"
        exit 1
    fi
done
if rg --files "$task_stage" | rg -q '\.(db|sqlite|sqlite3)(-wal|-shm)?$'; then
    print -u2 "database files must not be bundled"
    exit 1
fi
if rg -a -q 'hf_[A-Za-z0-9_-]{12,}' "$task_stage"; then
    print -u2 "a Hugging Face token-like value was found in the Store bundle"
    exit 1
fi
if rg -a -F -q "$task_root" "$task_stage"; then
    print -u2 "the Store bundle contains an absolute workspace path"
    exit 1
fi
if xattr -lr "$task_stage" 2>/dev/null | grep -q 'com.apple.quarantine'; then
    print -u2 "Store inputs carry com.apple.quarantine; obtain clean, verified helper builds."
    exit 1
fi
if /usr/bin/find "$task_stage" -type l -print -quit | grep -q .; then
    print -u2 "Store bundle must not contain symbolic links"
    exit 1
fi
plutil -lint "$task_contents/Info.plist" "$task_resources/PrivacyInfo.xcprivacy" >/dev/null

# Swift and prebuilt tools can carry development-machine run paths. Remove every absolute or
# otherwise unsupported LC_RPATH before dependency analysis; install_name_tool changes bytes before
# nested signing, and the signed-byte manifests below are intentionally generated afterwards.
task_contents_real=$(/bin/realpath "$task_contents")
while IFS= read -r -d '' task_candidate; do
    if ! file -b "$task_candidate" | grep -q 'Mach-O'; then
        continue
    fi
    while IFS= read -r task_rpath; do
        case "$task_rpath" in
            ../*|*/../*|*/..)
                ;;
            /System/Library/*|/usr/lib/*|@loader_path*|@executable_path*)
                continue
                ;;
        esac
        task_rpath_real=$(/bin/realpath "$task_rpath" 2>/dev/null || true)
        if [[ -n "$task_rpath_real" && "$task_rpath_real" == "$task_contents_real"/* ]]; then
            continue
        fi
        install_name_tool -delete_rpath "$task_rpath" "$task_candidate"
    done < <(otool -l "$task_candidate" | awk \
        '$1 == "cmd" && $2 == "LC_RPATH" { wanted = 1; next }
         wanted && $1 == "path" { print $2; wanted = 0 }')
done < <(/usr/bin/find "$task_contents" -type f -print0)

scripts/check-store-macho.sh "$task_stage"

# Sign every nested Mach-O first. The outer app is signed last; --deep is intentionally avoided.
task_macho=()
while IFS= read -r -d '' task_candidate; do
    if file -b "$task_candidate" | grep -q 'Mach-O'; then
        task_macho+=("$task_candidate")
    fi
done < <(/usr/bin/find "$task_contents" -type f ! -path "$task_contents/MacOS/CallRecorder" -print0)
for task_code in "${task_macho[@]}"; do
    task_kind=$(file -b "$task_code")
    if [[ -x "$task_code" && "$task_kind" == *executable* ]]; then
        codesign --force --timestamp \
            --entitlements Resources/CallRecorderHelper.entitlements \
            --sign "$task_app_identity" "$task_code"
    else
        # Native libraries and Mach-O bundles are code-signed, but entitlements belong to the
        # executable that loads them, not to dylibs or bundles.
        codesign --force --timestamp \
            --sign "$task_app_identity" "$task_code"
    fi
done

# Nested signing changes Mach-O bytes. Keep the verified input hashes in Provenance and generate
# separate manifests for the exact signed bytes that the outer app signature will seal.
printf '%s  %s\n' \
    "$(/usr/bin/shasum -a 256 "$task_bin/whisper-cli" | awk '{print $1}')" whisper-cli \
    > "$task_bin/SHA256SUMS"

codesign --force --timestamp --options runtime \
    --entitlements "$task_resolved_entitlements" \
    --sign "$task_app_identity" "$task_stage"
codesign --verify --strict --verbose=2 "$task_stage"
task_entitlements="$task_temp/entitlements.plist"
codesign -d --entitlements :- "$task_stage" > "$task_entitlements"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$task_entitlements")" != true ]]; then
    print -u2 "signed app is missing the App Sandbox entitlement"
    exit 1
fi

# Validate the signed app and a temporary package before publishing either output path. A failed
# preflight therefore cannot leave a fresh upload-looking artifact in dist/AppStore.
scripts/app-store-preflight.sh --app "$task_stage"
task_temp_pkg="$task_temp/CallRecorder-$task_version.pkg"
productbuild --component "$task_stage" /Applications --sign "$task_installer_identity" "$task_temp_pkg"
task_pkg_signature=$(pkgutil --check-signature "$task_temp_pkg")
print -r -- "$task_pkg_signature"
task_installer_team_id=$(print -r -- "$task_pkg_signature" \
    | sed -nE 's/^[[:space:]]*1\..*\(([A-Z0-9]{10})\)[[:space:]]*$/\1/p' | head -n 1)
if [[ "$task_installer_team_id" != "$task_team_id" ]]; then
    print -u2 "installer package certificate team does not match provisioning profile team"
    exit 1
fi

task_stamp="$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$task_output"
if [[ -e "$task_app" ]]; then
    mv "$task_app" "$task_app.previous-$task_stamp"
fi
if [[ -e "$task_pkg" ]]; then
    mv "$task_pkg" "$task_pkg.previous-$task_stamp"
fi
ditto "$task_stage" "$task_app"
ditto "$task_temp_pkg" "$task_pkg"
print "$task_pkg"
print "Package created locally; no upload was attempted."
