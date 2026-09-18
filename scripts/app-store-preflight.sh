#!/bin/zsh
# Validate repository submission assets or a staged Mac App Store app without uploading it.
set -u

task_root=${0:A:h:h}
task_failures=0

fail() {
    print -u2 "FAIL: $*"
    (( task_failures += 1 ))
}

pass() {
    print "PASS: $*"
}

check_plist() {
    local task_file=$1
    if [[ ! -f "$task_file" ]]; then
        fail "missing $task_file"
    elif plutil -lint "$task_file" >/dev/null; then
        pass "valid plist: ${task_file#$task_root/}"
    else
        fail "invalid plist: $task_file"
    fi
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

expect_value() {
    local task_file=$1 task_key=$2 task_expected=$3 task_actual
    task_actual=$(plist_value "$task_file" "$task_key")
    if [[ "$task_actual" == "$task_expected" ]]; then
        pass "${task_file#$task_root/}:$task_key is $task_expected"
    else
        fail "${task_file#$task_root/}:$task_key is '$task_actual'; expected '$task_expected'"
    fi
}

check_source() {
    local task_info="$task_root/Resources/Info.plist"
    local task_main_entitlements="$task_root/Resources/CallRecorderAppStore.entitlements"
    local task_helper_entitlements="$task_root/Resources/CallRecorderHelper.entitlements"
    local task_privacy="$task_root/Resources/PrivacyInfo.xcprivacy"
    check_plist "$task_info"
    check_plist "$task_main_entitlements"
    check_plist "$task_helper_entitlements"
    check_plist "$task_privacy"
    if [[ -x "$task_root/scripts/check-store-macho.sh" ]]; then
        pass "present and executable: scripts/check-store-macho.sh"
    else
        fail "missing or non-executable: scripts/check-store-macho.sh"
    fi
    if [[ -x "$task_root/scripts/build-app-store-whisper.sh" ]]; then
        pass "present and executable: scripts/build-app-store-whisper.sh"
    else
        fail "missing or non-executable: scripts/build-app-store-whisper.sh"
    fi
    expect_value "$task_info" CRDistributionChannel direct
    expect_value "$task_main_entitlements" com.apple.security.app-sandbox true
    expect_value "$task_main_entitlements" com.apple.security.device.audio-input true
    expect_value "$task_main_entitlements" com.apple.security.network.client true
    expect_value "$task_main_entitlements" com.apple.security.files.user-selected.read-write true
    expect_value "$task_main_entitlements" com.apple.security.files.bookmarks.app-scope true
    expect_value "$task_helper_entitlements" com.apple.security.app-sandbox true
    expect_value "$task_helper_entitlements" com.apple.security.inherit true
    expect_value "$task_privacy" NSPrivacyTracking false
    expect_value "$task_privacy" NSPrivacyTrackingDomains $'Array {\n}'
    expect_value "$task_privacy" NSPrivacyCollectedDataTypes $'Array {\n}'
    expect_value "$task_privacy" NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType \
        NSPrivacyAccessedAPICategoryUserDefaults
    expect_value "$task_privacy" NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0 CA92.1
    expect_value "$task_privacy" NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPIType \
        NSPrivacyAccessedAPICategoryFileTimestamp
    expect_value "$task_privacy" NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPITypeReasons:0 C617.1
    expect_value "$task_privacy" NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPITypeReasons:1 3B52.1

    local task_metadata=(
        AppStore/README.md
        AppStore/metadata/en-US/name.txt
        AppStore/metadata/en-US/subtitle.txt
        AppStore/metadata/en-US/description.txt
        AppStore/metadata/en-US/keywords.txt
        AppStore/metadata/en-US/promotional-text.txt
        AppStore/metadata/en-US/whats-new.txt
        AppStore/metadata/en-US/support-url.txt
        AppStore/metadata/en-US/marketing-url.txt
        AppStore/metadata/en-US/privacy-url.txt
        AppStore/review-notes.md
        AppStore/app-privacy.md
        AppStore/age-rating.md
        AppStore/export-compliance.md
        AppStore/screenshots/README.md
        AppStore/third-party-notices.md
    )
    local task_item
    for task_item in "${task_metadata[@]}"; do
        if [[ -s "$task_root/$task_item" ]]; then
            pass "present: $task_item"
        else
            fail "missing or empty: $task_item"
        fi
    done

    local task_file task_limit task_text
    for task_file task_limit in \
        name.txt 30 \
        subtitle.txt 30 \
        keywords.txt 100 \
        promotional-text.txt 170 \
        description.txt 4000 \
        whats-new.txt 4000; do
        task_text=$(<"$task_root/AppStore/metadata/en-US/$task_file")
        if (( ${#task_text} <= task_limit )); then
            pass "$task_file is within $task_limit characters"
        else
            fail "$task_file has ${#task_text} characters; limit is $task_limit"
        fi
    done
    for task_file in support-url.txt marketing-url.txt privacy-url.txt; do
        task_text=$(<"$task_root/AppStore/metadata/en-US/$task_file")
        [[ "$task_text" == https://* ]] && pass "$task_file uses HTTPS" || fail "$task_file must use HTTPS"
    done

    local task_account_vars=(
        CALL_RECORDER_APP_STORE_BUNDLE_ID
        CALL_RECORDER_APP_STORE_COPYRIGHT
        CALL_RECORDER_APP_STORE_APPLICATION_IDENTITY
        CALL_RECORDER_APP_STORE_INSTALLER_IDENTITY
        CALL_RECORDER_APP_STORE_PROVISIONING_PROFILE
        CALL_RECORDER_APP_STORE_WHISPER_CLI
        CALL_RECORDER_APP_STORE_WHISPER_CLI_SHA256
        CALL_RECORDER_APP_STORE_WHISPER_LICENSE
        CALL_RECORDER_APP_STORE_WHISPER_LICENSE_SHA256
    )
    local task_missing=()
    for task_item in "${task_account_vars[@]}"; do
        [[ -n "${(P)task_item:-}" ]] || task_missing+=("$task_item")
    done
    if (( ${#task_missing[@]} )); then
        print "ACCOUNT-DEPENDENT: package signing was not checked; unset inputs: ${(j:, :)task_missing}"
    else
        pass "all account/build input environment variables are set"
    fi
}

check_app() {
    local task_app=$1
    local task_contents="$task_app/Contents"
    local task_info="$task_contents/Info.plist"
    local task_resources="$task_contents/Resources"
    local task_provenance="$task_resources/Provenance"
    [[ -d "$task_app" ]] || { fail "built app does not exist: $task_app"; return; }
    check_plist "$task_info"
    check_plist "$task_resources/PrivacyInfo.xcprivacy"
    local task_bundle_id
    task_bundle_id=$(plist_value "$task_info" CFBundleIdentifier)
    if [[ -z "$task_bundle_id" || "$task_bundle_id" == local.* || "$task_bundle_id" == com.example.* ]]; then
        fail "built app uses local or placeholder bundle ID: '$task_bundle_id'"
    else
        pass "built app uses non-local bundle ID: $task_bundle_id"
    fi
    expect_value "$task_info" CRDistributionChannel app-store
    local task_copyright
    task_copyright=$(plist_value "$task_info" NSHumanReadableCopyright)
    [[ -n "$task_copyright" ]] \
        && pass "built app has a human-readable copyright" \
        || fail "built app is missing NSHumanReadableCopyright"
    local task_required=(
        "$task_contents/MacOS/CallRecorder"
        "$task_contents/embedded.provisionprofile"
        "$task_resources/PrivacyInfo.xcprivacy"
        "$task_resources/bin/whisper-cli"
        "$task_resources/bin/SHA256SUMS"
        "$task_provenance/whisper-input-SHA256SUMS"
        "$task_provenance/license-input-SHA256SUMS"
        "$task_provenance/libsql-swift-source.txt"
        "$task_resources/Licenses/whisper.cpp-LICENSE.txt"
        "$task_resources/Licenses/libsql-swift-LICENSE.txt"
    )
    local task_item
    for task_item in "${task_required[@]}"; do
        [[ -s "$task_item" ]] && pass "present: ${task_item#$task_app/}" || fail "missing: $task_item"
    done
    local task_forbidden=(
        "$task_resources/bin/ffmpeg"
        "$task_resources/bin/ffprobe"
        "$task_resources/indexer"
        "$task_resources/diarize.py"
    )
    for task_item in "${task_forbidden[@]}"; do
        [[ ! -e "$task_item" ]] \
            && pass "absent from Store app: ${task_item#$task_app/}" \
            || fail "forbidden Store artifact is present: $task_item"
    done
    if xattr -lr "$task_app" 2>/dev/null | grep -q 'com.apple.quarantine'; then
        fail "built app carries com.apple.quarantine"
    else
        pass "built app has no quarantine attribute"
    fi
    if /usr/bin/find "$task_app" -type l -print -quit | grep -q .; then
        fail "built app contains a symbolic link"
    else
        pass "built app contains no symbolic links"
    fi
    if (cd "$task_resources/bin" && /usr/bin/shasum -a 256 -c SHA256SUMS); then
        pass "embedded signed whisper-cli matches its signed-byte manifest"
    else
        fail "embedded signed whisper-cli does not match its signed-byte manifest"
    fi
    if [[ $(wc -l < "$task_provenance/whisper-input-SHA256SUMS") -eq 1 ]] \
        && grep -Eq '^[0-9A-Fa-f]{64}  whisper-cli$' \
            "$task_provenance/whisper-input-SHA256SUMS"; then
        pass "pinned pre-sign whisper-cli provenance is well formed"
    else
        fail "pinned pre-sign whisper-cli provenance is malformed"
    fi
    if [[ $(wc -l < "$task_resources/bin/SHA256SUMS") -eq 1 ]] \
        && grep -Eq '^[0-9A-Fa-f]{64}  whisper-cli$' "$task_resources/bin/SHA256SUMS"; then
        pass "signed-byte manifest covers only whisper-cli"
    else
        fail "signed-byte manifest does not cover exactly whisper-cli"
    fi
    if [[ $(wc -l < "$task_provenance/license-input-SHA256SUMS") -eq 2 ]] \
        && grep -Eq '^[0-9A-Fa-f]{64}  whisper\.cpp-LICENSE\.txt$' \
            "$task_provenance/license-input-SHA256SUMS" \
        && grep -Eq '^[0-9A-Fa-f]{64}  libsql-swift-LICENSE\.txt$' \
            "$task_provenance/license-input-SHA256SUMS" \
        && (cd "$task_resources/Licenses" \
            && /usr/bin/shasum -a 256 -c "$task_provenance/license-input-SHA256SUMS"); then
        pass "bundled third-party license texts match their provenance manifest"
    else
        fail "third-party license provenance is missing, malformed, or does not match"
    fi
    local task_libsql_revision task_recorded_libsql_revision
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
    task_recorded_libsql_revision=$(sed -n 's/^revision=//p' \
        "$task_provenance/libsql-swift-source.txt")
    if [[ "$task_recorded_libsql_revision" == "$task_libsql_revision" ]] \
        && [[ $(grep -c '^identity=libsql-swift$' \
            "$task_provenance/libsql-swift-source.txt") -eq 1 ]] \
        && [[ $(grep -c '^checkout-clean=true$' \
            "$task_provenance/libsql-swift-source.txt") -eq 1 ]]; then
        pass "libsql-swift license provenance matches the pinned clean checkout"
    else
        fail "libsql-swift source provenance does not match Package.resolved"
    fi
    if codesign --verify --strict --verbose=2 "$task_app"; then
        pass "strict code-signature verification"
    else
        fail "strict code-signature verification"
    fi
    local task_temp
    task_temp=$(mktemp -d /tmp/call-recorder-preflight.XXXXXX)
    if codesign -d --entitlements :- "$task_app" > "$task_temp/entitlements.plist" 2>/dev/null; then
        expect_value "$task_temp/entitlements.plist" com.apple.security.app-sandbox true
        expect_value "$task_temp/entitlements.plist" com.apple.security.device.audio-input true
        expect_value "$task_temp/entitlements.plist" com.apple.security.network.client true
        expect_value "$task_temp/entitlements.plist" com.apple.security.files.user-selected.read-write true
        expect_value "$task_temp/entitlements.plist" com.apple.security.files.bookmarks.app-scope true
        if security cms -D -i "$task_contents/embedded.provisionprofile" \
            > "$task_temp/profile.plist" 2>/dev/null; then
            local task_profile_app_id task_signed_app_id task_profile_team_id task_signed_team_id
            local task_profile_expiration task_expiration_epoch task_now_epoch task_certificate_team_id
            task_profile_app_id=$(plist_value "$task_temp/profile.plist" \
                Entitlements:com.apple.application-identifier)
            [[ -n "$task_profile_app_id" ]] || task_profile_app_id=$(plist_value \
                "$task_temp/profile.plist" Entitlements:application-identifier)
            task_profile_team_id=$(plist_value "$task_temp/profile.plist" \
                Entitlements:com.apple.developer.team-identifier)
            [[ -n "$task_profile_team_id" ]] || task_profile_team_id=$(plist_value \
                "$task_temp/profile.plist" TeamIdentifier:0)
            task_signed_app_id=$(plist_value "$task_temp/entitlements.plist" \
                com.apple.application-identifier)
            task_signed_team_id=$(plist_value "$task_temp/entitlements.plist" \
                com.apple.developer.team-identifier)
            [[ "$task_signed_app_id" == "$task_profile_app_id" ]] \
                && pass "signed application identifier matches the provisioning profile" \
                || fail "signed application identifier does not match the provisioning profile"
            [[ "$task_signed_team_id" == "$task_profile_team_id" ]] \
                && pass "signed team identifier matches the provisioning profile" \
                || fail "signed team identifier does not match the provisioning profile"
            [[ "$task_signed_app_id" == "$task_signed_team_id.$task_bundle_id" ]] \
                && pass "signed application identifier matches the bundle ID" \
                || fail "signed application identifier does not match the bundle ID"
            expect_value "$task_temp/entitlements.plist" keychain-access-groups:0 \
                "$task_signed_app_id"
            task_profile_expiration=$(plutil -extract ExpirationDate raw -o - \
                "$task_temp/profile.plist" 2>/dev/null)
            task_expiration_epoch=$(LC_ALL=C date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
                "$task_profile_expiration" '+%s' 2>/dev/null)
            task_now_epoch=$(date '+%s')
            if [[ -n "$task_expiration_epoch" ]] && (( task_expiration_epoch > task_now_epoch )); then
                pass "embedded provisioning profile is not expired"
            else
                fail "embedded provisioning profile is expired or has an unreadable ExpirationDate"
            fi
            task_certificate_team_id=$(codesign -dv --verbose=4 "$task_app" 2>&1 \
                | sed -n 's/^TeamIdentifier=//p' | head -n 1)
            [[ "$task_certificate_team_id" == "$task_profile_team_id" ]] \
                && pass "signing certificate team matches the provisioning profile" \
                || fail "signing certificate team does not match the provisioning profile"
        else
            fail "could not decode embedded provisioning profile"
        fi
    else
        fail "could not read signed app entitlements"
    fi
    "$task_root/scripts/check-store-macho.sh" "$task_app" || fail "Mach-O dependency closure"
    while IFS= read -r -d '' task_item; do
        if file -b "$task_item" | grep -q 'Mach-O'; then
            codesign --verify --strict "$task_item" 2>/dev/null \
                && pass "Mach-O signed: ${task_item#$task_app/}" \
                || fail "Mach-O has invalid signature: $task_item"
        fi
    done < <(/usr/bin/find "$task_contents" -type f -print0)
    rm -rf -- "$task_temp"
}

case "${1:-}" in
    --source)
        check_source
        ;;
    --app)
        check_source
        [[ -n "${2:-}" ]] || { print -u2 "usage: $0 --app /path/to/Call\\ Recorder.app"; exit 2; }
        check_app "$2"
        ;;
    *)
        print -u2 "usage: $0 --source | --app /path/to/Call\\ Recorder.app"
        exit 2
        ;;
esac

if (( task_failures )); then
    print -u2 "App Store preflight failed with $task_failures problem(s)."
    exit 1
fi
print "App Store preflight passed. Account/legal decisions and App Store Connect submission are not certified by this check."
