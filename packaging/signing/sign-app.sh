#!/bin/sh
# Signs an app bundle with the release identity and checks the result.
#
#   ./sign-app.sh <app> <identity> [<keychain>]
#
# Contents/Helpers and nested code inside them are signed with the same
# identity first, deepest first; other nested code (Sparkle.framework) keeps
# its own signature, as with 'make app'. Prints the designated requirement,
# which must be the same for every release.
set -eu

app=${1:?usage: sign-app.sh <app> <identity> [<keychain>]}
identity=${2:?usage: sign-app.sh <app> <identity> [<keychain>]}
kc=${3:-}

sign() {
    if [ -n "$kc" ]; then
        codesign -f -s "$identity" --keychain "$kc" "$1"
    else
        codesign -f -s "$identity" "$1"
    fi
    codesign --verify --strict "$1"
}

# Helpers run on their own, so an ad-hoc signature would reset TCC grants
if [ -d "$app/Contents/Helpers" ]; then
    for helper in "$app/Contents/Helpers/"*; do
        sign "$helper"
    done
fi
sign "$app"

# An ad-hoc signature has no certificate, so permissions would reset on every update
if codesign -dv "$app" 2>&1 | grep -q '^Signature=adhoc'; then
    echo "sign-app: $app is signed ad-hoc, not with $identity" >&2
    exit 1
fi
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p'
