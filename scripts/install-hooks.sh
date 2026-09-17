#!/bin/sh
#
# Point this clone at the hooks in .githooks. Run once per clone; the hooks are committed, so they
# travel with the repository and only the path to them is local.
#
set -eu

root=$(git rev-parse --show-toplevel)
git -C "$root" config core.hooksPath .githooks
echo "Hooks installed from $(git -C "$root" config core.hooksPath)"
