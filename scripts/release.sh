#!/bin/zsh
#
# Keep the documents in step with the version, and ship a release.
#
#   scripts/release.sh --check     fail if the documents name another version, the changelog has
#                                  no entry for this one, or a screenshot the README shows is gone
#   scripts/release.sh --test      the Swift suite, with the serial run as the fallback a busy
#                                  machine needs
#   scripts/release.sh --sync      write the version into the documents and re-render the
#                                  screenshots into docs/images
#   scripts/release.sh --publish   check, test, package, publish the release with its two assets,
#                                  then download the archive back and check it
#
# A release is built from the commit that is pushed, so --publish refuses a dirty tree or a HEAD
# that origin/main has not seen. The tag then points at the same bytes the documents and the
# screenshots were generated from.
#
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
tag="v$version"
archive="CallRecorder-$version.zip"
hooks="scripts/install-hooks.sh"

# The screenshots the README shows, read from the README so the list cannot drift from it.
images=(${(f)"$(grep -o 'docs/images/[A-Za-z0-9._-]*[.]png' README.md | sort -u)"})

check() {
    local problems=()
    if ! grep -q "$archive" README.md; then
        problems+=("README.md does not name $archive")
    fi
    if [[ "$(head -1 DISTRIBUTION_README.txt)" != "Call Recorder $version" ]]; then
        problems+=("DISTRIBUTION_README.txt starts with \"$(head -1 DISTRIBUTION_README.txt)\"")
    fi
    if ! grep -q "^## \[$version\]" CHANGELOG.md; then
        problems+=("CHANGELOG.md has no entry for $version")
    fi
    local image
    for image in $images; do
        if [[ ! -f "$image" ]]; then
            problems+=("README.md shows $image, which does not exist")
        fi
    done
    if [[ ${#problems[@]} -gt 0 ]]; then
        print -u2 "The documents are out of step with the bundle ($version):"
        local problem
        for problem in $problems; do
            print -u2 "  - $problem"
        done
        print -u2 "Run: scripts/release.sh --sync"
        return 1
    fi
    return 0
}

sync() {
    perl -pi -e "s/CallRecorder-[0-9][0-9.]*[.]zip/$archive/g" README.md
    sed -i '' "1s/^Call Recorder .*/Call Recorder $version/" DISTRIBUTION_README.txt

    scripts/preview.sh >/dev/null
    local image
    for image in $images; do
        local rendered="dist/preview/${image:t}"
        if [[ ! -f "$rendered" ]]; then
            print -u2 "The renderer wrote no $rendered."
            print -u2 "A snapshot name in SnapshotRunner.swift and its README image have drifted."
            return 1
        fi
        cp "$rendered" "$image"
    done
    print "Documents and screenshots are in step with $version."
}

publish() {
    check
    if [[ -n "$(git status --porcelain)" ]]; then
        print -u2 "The working tree is not clean:"
        git status --short
        print -u2 "Commit or stash the change, then publish again."
        return 1
    fi
    local head=$(git rev-parse HEAD)
    local pushed=$(git rev-parse origin/main 2>/dev/null || print "")
    if [[ "$head" != "$pushed" ]]; then
        print -u2 "HEAD ($head) is not what origin/main points at ($pushed). Push first."
        return 1
    fi
    if gh release view "$tag" >/dev/null 2>&1; then
        print -u2 "Release $tag already exists."
        return 1
    fi

    print "Testing..."
    test_suite

    print "Packaging..."
    scripts/package-app.sh

    local notes="dist/release-notes-$version.md"
    awk -v heading="## [$version]" '
        index($0, heading) == 1 { inside = 1; next }
        inside && index($0, "## [") == 1 { exit }
        inside { print }
    ' CHANGELOG.md > "$notes"

    local assets="dist/release-$version"
    mkdir -p "$assets"
    cp "dist/Call Recorder $version.zip" "$assets/$archive"
    cp DISTRIBUTION_README.txt "$assets/README.txt"

    local arguments=(--title "Call Recorder $version" --notes-file "$notes" --target main)
    gh release create "$tag" "${arguments[@]}" "$assets/$archive" "$assets/README.txt"

    verify
}

test_suite() {
    if ! swift test; then
        # A busy machine can starve the parallel run's threads. The serial run is the reliable
        # proof, and it is the same code either way.
        print "The parallel run failed; running the suite serially..."
        swift test --no-parallel
    fi
}

verify() {
    local temp=$(mktemp -d /tmp/call-recorder-verify.XXXXXX)
    trap 'rm -rf -- "$temp"' EXIT

    gh release download "$tag" --pattern "$archive" --dir "$temp" --clobber
    local digest=$(shasum -a 256 "$temp/$archive" | awk '{ print $1 }')
    gh release view "$tag" --json assets > "$temp/assets.json"
    local published=$(jq -r --arg name "$archive" '.assets[] | select(.name == $name) | .digest' "$temp/assets.json" | sed 's/^sha256://')
    if [[ "$digest" != "$published" ]]; then
        print -u2 "The download does not match the digest the release published."
        return 1
    fi

    ditto -x -k "$temp/$archive" "$temp/unpacked"
    local bundle="$temp/unpacked/Call Recorder.app"
    if [[ ! -d "$bundle" ]]; then
        print -u2 "The archive holds no Call Recorder.app at its top level."
        return 1
    fi
    local shipped_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$bundle/Contents/Info.plist")
    local shipped_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$bundle/Contents/Info.plist")
    if [[ "$shipped_version" != "$version" || "$shipped_build" != "$build" ]]; then
        print -u2 "The archive carries $shipped_version ($shipped_build), not $version ($build)."
        return 1
    fi
    codesign --verify --deep --strict "$bundle"
    print "$tag is published: $archive, digest $digest, build $shipped_build, signature valid."
}

case "${1:---check}" in
    --check) check ;;
    --sync) sync ;;
    --test) test_suite ;;
    --publish) publish ;;
    *)
        print -u2 "usage: scripts/release.sh [--check | --test | --sync | --publish]"
        print -u2 "Do not run a release by hand: $hooks installs the hooks that keep the documents in step."
        exit 2
        ;;
esac
