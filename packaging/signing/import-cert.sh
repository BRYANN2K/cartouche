#!/bin/sh
# Imports the signing certificate into a throwaway keychain and prints its path.
#
#   SIGNING_CERT_P12=<base64> SIGNING_CERT_PASSWORD=<password> ./import-cert.sh <keychain path>
#
# The keychain gets a random password and only codesign may use the key. Delete
# it with 'security delete-keychain <path>' when signing is done.
set -eu

kc=${1:?usage: import-cert.sh <keychain path>}
: "${SIGNING_CERT_P12:?SIGNING_CERT_P12 is not set}"
: "${SIGNING_CERT_PASSWORD:?SIGNING_CERT_PASSWORD is not set}"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%s' "$SIGNING_CERT_P12" | base64 --decode > "$work/cert.p12"
kcpass="$(openssl rand -hex 24)"
security create-keychain -p "$kcpass" "$kc"
security set-keychain-settings -lut 3600 "$kc"
security unlock-keychain -p "$kcpass" "$kc"
security import "$work/cert.p12" -k "$kc" -f pkcs12 -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
# Without this, codesign stops on a UI prompt for the key
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$kc" >/dev/null
echo "$kc"
