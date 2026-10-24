#!/bin/sh
# Runs install.sh against fixture releases served on 127.0.0.1: a good one, a
# tampered archive, an app signed by someone else, an ad-hoc signed app and a
# running copy. Installs only into a scratch Applications folder, opens nothing,
# and uses a throwaway certificate and keychain.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
signing="$repo/packaging/signing"
work="$(mktemp -d)"
kc="$work/install-test.keychain-db"
kc2="$work/install-test-other.keychain-db"
server=
trap '[ -z "$server" ] || kill "$server" 2>/dev/null || true; security delete-keychain "$kc" 2>/dev/null || true
      security delete-keychain "$kc2" 2>/dev/null || true; rm -rf "$work"' EXIT

fail() { echo "install-test: $*" >&2; exit 1; }

cert() {
    CARTOUCHE_CERT_NAME="$1" CARTOUCHE_CERT_DAYS=2 sh "$signing/make-cert.sh" "$work/$2" >/dev/null
    openssl x509 -in "$work/$2/cartouche-signing.cert.pem" -noout -fingerprint -sha1 \
        | sed 's/.*=//; s/://g' | tr '[:upper:]' '[:lower:]'
}

keychain() {
    SIGNING_CERT_P12="$(cat "$work/$1/cartouche-signing.p12.base64")" \
    SIGNING_CERT_PASSWORD="$(cat "$work/$1/cartouche-signing.password")" \
        sh "$signing/import-cert.sh" "$2" >/dev/null
}

searchlist_before="$(security list-keychains -d user)"
sha1=$(cert "Cartouche Install Test" cert)
other=$(cert "Someone Else" other)
keychain cert "$kc"
keychain other "$kc2"

# A small app that stays open, so the running-copy case has something to find
printf '#include <unistd.h>\nint main(void){sleep(30);return 0;}\n' > "$work/main.c"
clang -o "$work/Cartouche" "$work/main.c"

# release <name> <identity|-> <keychain> [<bundle id>]: a release folder as GitHub serves it
release() {
    dir="$work/releases/$1"
    app="$work/build-$1/Cartouche.app"
    mkdir -p "$dir" "$app/Contents/MacOS"
    cp "$work/Cartouche" "$app/Contents/MacOS/Cartouche"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Cartouche</string>
<key>CFBundleIdentifier</key><string>${4:-dev.bryann2k.cartouche}</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
EOF
    if [ "$2" = - ]; then
        codesign -f -s - "$app" 2>/dev/null
    else
        codesign -f -s "$2" --keychain "$3" "$app" 2>/dev/null
    fi
    ditto -c -k --keepParent "$app" "$dir/Cartouche-0.1.0.zip"
    python3 "$repo/packaging/release.py" checksums "$dir/Cartouche-0.1.0.zip" --out "$dir/SHA256SUMS"
}

release good "Cartouche Install Test" "$kc"
release other "Someone Else" "$kc2"
release adhoc - -
release identifier "Cartouche Install Test" "$kc" com.example.other
mkdir -p "$work/releases/tampered" "$work/releases/traversal"
cp "$work/releases/good/"* "$work/releases/tampered/"
printf 'x' >> "$work/releases/tampered/Cartouche-0.1.0.zip"
sed 's/Cartouche-0.1.0.zip/..\/good\/Cartouche-0.1.0.zip/' "$work/releases/good/SHA256SUMS" > "$work/releases/traversal/SHA256SUMS"

# Serves the releases folder on a free loopback port, written to $work/port
python3 -I -c '
import functools, http.server, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
open(sys.argv[2], "w").write(str(httpd.server_address[1]))
httpd.serve_forever()
' "$work/releases" "$work/port" 2>"$work/server.log" &
server=$!
n=0
while [ ! -s "$work/port" ]; do
    n=$((n + 1)); [ $n -lt 100 ] || fail "the fixture server did not start"; sleep 0.1
done
base="http://127.0.0.1:$(cat "$work/port")"

# The script as published, with the test certificate pinned instead of Cartouche's
sed "s/^cert_sha1=.*/cert_sha1=$sha1/" "$repo/install.sh" > "$work/install.sh"
grep -q "^cert_sha1=$sha1\$" "$work/install.sh" || fail "install.sh has no cert_sha1= line to pin"

apps="$work/Applications"
mkdir -p "$apps" "$work/tmp"

# run <release> [<script>]: output in $work/out, exit status in $status
run() {
    status=0
    TMPDIR="$work/tmp" CARTOUCHE_RELEASE_URL="$base/$1" CARTOUCHE_APPLICATIONS="$apps" CARTOUCHE_NO_OPEN=1 \
        sh "${2:-$work/install.sh}" > "$work/out" 2>&1 || status=$?
    [ -z "$(ls -A "$work/tmp")" ] || fail "$1: left files behind in TMPDIR: $(ls -A "$work/tmp")"
}

refused() {
    [ "$status" -ne 0 ] || fail "$1: exited 0: $(cat "$work/out")"
    grep -q "$2" "$work/out" || fail "$1: no '$2' in: $(cat "$work/out")"
    [ ! -e "$apps/Cartouche.app" ] || fail "$1: something was installed"
    echo "==> install-test: $1 refused: $(grep 'not installed' "$work/out")"
}

run good
[ "$status" -eq 0 ] || fail "good release: exit $status: $(cat "$work/out")"
codesign --verify --strict "$apps/Cartouche.app" || fail "the installed app does not verify"
xattr -p com.apple.quarantine "$apps/Cartouche.app" > "$work/xattr" 2>&1 && fail "the installed app is quarantined"
grep -q 'No such xattr' "$work/xattr" || fail "unexpected xattr output: $(cat "$work/xattr")"
grep -q 'Opening Cartouche' "$work/out" && fail "CARTOUCHE_NO_OPEN was not honored"
echo "==> install-test: good release installed; $(cat "$work/xattr")"
sed 's/^/    /' "$work/out"

# Installing again replaces the copy in place
run good
[ "$status" -eq 0 ] || fail "reinstall: exit $status: $(cat "$work/out")"

# A copy running from the destination is never replaced
"$apps/Cartouche.app/Contents/MacOS/Cartouche" &
running=$!
sleep 0.5
run good
kill "$running" 2>/dev/null || true
wait "$running" 2>/dev/null || true
[ "$status" -ne 0 ] || fail "a running copy was replaced"
grep -q 'Quit it' "$work/out" || fail "running copy: no reason given: $(cat "$work/out")"
echo "==> install-test: running copy refused: $(grep 'not installed' "$work/out")"

rm -rf "$apps/Cartouche.app"
run tampered; refused "tampered archive" "does not match the SHA-256"
grep -q 'so it was deleted' "$work/out" || fail "tampered archive: the deletion is not said"
run other; refused "other certificate" "not signed with Cartouche's certificate"
run adhoc; refused "ad-hoc signature" "not signed with Cartouche's certificate"
run identifier; refused "other bundle identifier" "not signed with Cartouche's certificate"
run traversal; refused "archive name with a path" "names no Cartouche archive"
run missing; refused "missing release" "SHA256SUMS could not be downloaded"
sed "s/^cert_sha1=.*/cert_sha1=/" "$repo/install.sh" > "$work/unpinned.sh"
run good "$work/unpinned.sh"; refused "unpinned script" "does not name Cartouche's certificate"

status=0
TMPDIR="$work/tmp" CARTOUCHE_RELEASE_URL="http://example.com/download" CARTOUCHE_APPLICATIONS="$apps" \
    CARTOUCHE_NO_OPEN=1 sh "$work/install.sh" > "$work/out" 2>&1 || status=$?
refused "plain http" "only over https"

sh -n "$repo/install.sh" || fail "install.sh does not parse"
kill "$server"
wait "$server" 2>/dev/null || true
server=
security delete-keychain "$kc"
security delete-keychain "$kc2"
[ "$(security list-keychains -d user)" = "$searchlist_before" ] || fail "the keychain search list changed"
[ "$other" != "$sha1" ] || fail "the two certificates are the same"
echo "==> install-test: install.sh checks the SHA-256 and the certificate, and installs without quarantine"
