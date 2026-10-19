#!/bin/sh
# Signs an app bundle with the release identity and checks the result.
#
#   ./sign-app.sh <app> <identity> [<keychain>]
#
# Nested code (Sparkle.framework) keeps its own signature, as with 'make app'.
# Prints the designated requirement, which must be the same for every release.
set -eu

app=${1:?usage: sign-app.sh <app> <identity> [<keychain>]}
identity=${2:?usage: sign-app.sh <app> <identity> [<keychain>]}
kc=${3:-}

if [ -n "$kc" ]; then
    codesign -f -s "$identity" --keychain "$kc" "$app"
else
    codesign -f -s "$identity" "$app"
fi
codesign --verify --strict "$app"

# An ad-hoc signature has no certificate, so permissions would reset on every update
if codesign -dv "$app" 2>&1 | grep -q '^Signature=adhoc'; then
    echo "sign-app: $app is signed ad-hoc, not with $identity" >&2
    exit 1
fi
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p'
