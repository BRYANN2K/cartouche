#!/bin/sh
# Makes a throwaway self-signed certificate, signs two different builds of a small
# app with it and checks both carry the same designated requirement. Everything
# lives in a temporary folder and keychain; the user's keychains are not used.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
signing="$here/../signing"
work="$(mktemp -d)"
kc="$work/test-signing.keychain-db"
searchlist_before="$(security list-keychains -d user)"
trap 'security delete-keychain "$kc" 2>/dev/null || true; rm -rf "$work"' EXIT

fail() { echo "signing-test: $*" >&2; exit 1; }

CARTOUCHE_CERT_NAME="Cartouche Test Signing" CARTOUCHE_CERT_DAYS=2 \
    sh "$signing/make-cert.sh" "$work/cert" >/dev/null
SIGNING_CERT_P12="$(cat "$work/cert/cartouche-signing.p12.base64")" \
SIGNING_CERT_PASSWORD="$(cat "$work/cert/cartouche-signing.password")" \
    sh "$signing/import-cert.sh" "$kc" >/dev/null

printf 'int main(void){return %s;}\n' 1 > "$work/one.c"
printf 'int main(void){return %s;}\n' 2 > "$work/two.c"
for v in 1 2; do
    app="$work/v$v/Cartouche.app"
    mkdir -p "$app/Contents/MacOS"
    src=one; [ "$v" = 2 ] && src=two
    clang -o "$app/Contents/MacOS/Cartouche" "$work/$src.c"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Cartouche</string>
<key>CFBundleIdentifier</key><string>dev.bryann2k.cartouche</string>
<key>CFBundleShortVersionString</key><string>0.0.$v</string>
<key>CFBundleVersion</key><string>0.0.$v</string>
</dict></plist>
EOF
    sh "$signing/sign-app.sh" "$app" "Cartouche Test Signing" "$kc" > "$work/dr$v"
done

[ -s "$work/dr1" ] || fail "no designated requirement printed"
cmp -s "$work/dr1" "$work/dr2" || fail "designated requirements differ: $(cat "$work/dr1") / $(cat "$work/dr2")"
grep -q 'identifier "dev.bryann2k.cartouche"' "$work/dr1" || fail "requirement does not name the bundle ID: $(cat "$work/dr1")"
sha1="$(openssl x509 -in "$work/cert/cartouche-signing.cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr '[:upper:]' '[:lower:]')"
grep -q "certificate leaf = H\"$sha1\"" "$work/dr1" || fail "requirement does not pin the certificate $sha1: $(cat "$work/dr1")"
cmp -s "$work/v1/Cartouche.app/Contents/MacOS/Cartouche" "$work/v2/Cartouche.app/Contents/MacOS/Cartouche" \
    && fail "the two builds are identical, the test proves nothing"

# A bundle signed ad-hoc must be refused
adhoc="$work/adhoc/Cartouche.app"
mkdir -p "$adhoc/Contents/MacOS"
cp "$work/v1/Cartouche.app/Contents/Info.plist" "$adhoc/Contents/"
cp "$work/v1/Cartouche.app/Contents/MacOS/Cartouche" "$adhoc/Contents/MacOS/"
if sh "$signing/sign-app.sh" "$adhoc" - >/dev/null 2>&1; then fail "an ad-hoc signature was accepted"; fi

security delete-keychain "$kc"
[ "$(security list-keychains -d user)" = "$searchlist_before" ] || fail "the keychain search list changed"
echo "==> signing-test: two builds share the requirement: $(cat "$work/dr1")"
