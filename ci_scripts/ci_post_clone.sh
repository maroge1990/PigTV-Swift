#!/bin/sh
# Xcode Cloud (D-70): the release workflow's tests read the server's golden API answers from ../PigTV/test/golden
# (PigTVTests/GoldenChecks.swift looks beside this repository). Xcode Cloud clones only this repository, so fetch just
# that folder of the public server repository next to it. Without it the golden checks would skip, so fail instead.
set -eu
dest="${CI_PRIMARY_REPOSITORY_PATH:?}/../PigTV"
rm -rf "$dest"
git clone --quiet --depth 1 --filter=blob:none --sparse https://github.com/maroge1990/PigTV.git "$dest"
git -C "$dest" sparse-checkout set test/golden
test -f "$dest/test/golden/routes.json" || { echo "ci_post_clone: no golden answers in $dest/test/golden" >&2; exit 1; }
echo "ci_post_clone: golden answers from PigTV $(git -C "$dest" rev-parse --short HEAD)"
