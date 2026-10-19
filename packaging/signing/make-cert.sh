#!/bin/sh
# Creates Cartouche's self-signed code signing certificate. Run once by the
# maintainer, then store the outputs as repository secrets (docs/RELEASE.md).
#
#   ./make-cert.sh <output folder outside the repository>
#
# Writes cartouche-signing.p12, its password, and the base64 of the p12 for the
# SIGNING_CERT_P12 secret. Every release is signed with this one certificate, so
# its SHA-1 ends up in the designated requirement and must never change.
set -eu

out=${1:?usage: make-cert.sh <output folder>}
name=${CARTOUCHE_CERT_NAME:-Cartouche Self-Signed}
days=${CARTOUCHE_CERT_DAYS:-7300}

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
case "$out/" in
    "$repo"/*)
        rmdir "$out" 2>/dev/null || true
        echo "make-cert: $out is inside the repository, pick a folder outside it" >&2
        exit 1 ;;
esac
if [ -e "$out/cartouche-signing.p12" ]; then
    echo "make-cert: $out/cartouche-signing.p12 exists, refusing to replace it" >&2
    exit 1
fi

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

openssl req -x509 -newkey rsa:3072 -sha256 -days "$days" -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" -subj "/CN=$name" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl rand -base64 24 > "$out/cartouche-signing.password"
# macOS's security tool cannot read the AES p12 that OpenSSL 3 writes by default
legacy=
if openssl version | grep -q '^OpenSSL 3'; then legacy=-legacy; fi
# shellcheck disable=SC2086
openssl pkcs12 -export $legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -passout "file:$out/cartouche-signing.password" -out "$out/cartouche-signing.p12"
base64 < "$out/cartouche-signing.p12" | tr -d '\n' > "$out/cartouche-signing.p12.base64"
cp "$work/cert.pem" "$out/cartouche-signing.cert.pem"

fingerprint="$(openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
echo "==> Certificate \"$name\" valid for $days days, SHA-1 $fingerprint"
echo "==> Secrets: SIGNING_CERT_P12 = $out/cartouche-signing.p12.base64"
echo "==>          SIGNING_CERT_PASSWORD = $out/cartouche-signing.password"
echo "==> Variable: SIGNING_IDENTITY = $name"
echo "==> Keep a copy of $out somewhere safe and offline. Losing it changes the app's identity."
