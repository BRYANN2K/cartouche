#!/bin/sh
# Builds the real app twice (two test versions), signs both with one throwaway
# self-signed certificate through packaging/signing, and prints both requirements.
# Evidence for "Identity is stable"; needs Xcode, writes only under /tmp/p9-dr.
set -eu
R="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
W=/tmp/p9-dr
rm -rf "$W"
mkdir -p "$W"
cd "$R"
for v in 0.0.1-test.1 0.0.1-test.2; do
    make -s -o app-payload app "APP_VERSION=$v" > "$W/build-$v.log" 2>&1
    ditto out/Cartouche.app "$W/$v/Cartouche.app"
done
CARTOUCHE_CERT_NAME="Cartouche DR Check" sh packaging/signing/make-cert.sh "$W/cert" > "$W/cert.log"
kc="$W/dr.keychain-db"
before="$(security list-keychains -d user)"
SIGNING_CERT_P12="$(cat "$W/cert/cartouche-signing.p12.base64")" \
SIGNING_CERT_PASSWORD="$(cat "$W/cert/cartouche-signing.password")" \
    sh packaging/signing/import-cert.sh "$kc" > /dev/null
for v in 0.0.1-test.1 0.0.1-test.2; do
    app="$W/$v/Cartouche.app"
    sh packaging/signing/sign-app.sh "$app" "Cartouche DR Check" "$kc" 2>/dev/null > "$W/dr-$v.txt"
    echo "== $v: $(defaults read "$app/Contents/Info" CFBundleShortVersionString) / $(defaults read "$app/Contents/Info" CFBundleVersion)"
    codesign -d -r- "$app" 2>&1 | grep designated
    codesign --verify --deep --strict "$app" && echo "verify --deep --strict: ok"
done
security delete-keychain "$kc"
if [ "$(security list-keychains -d user)" = "$before" ]; then echo "keychain search list unchanged"; fi
cmp "$W/dr-0.0.1-test.1.txt" "$W/dr-0.0.1-test.2.txt" && echo "designated requirements identical"
cat "$W/cert.log"
