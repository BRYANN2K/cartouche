#!/bin/sh
# Installs the latest Cartouche release in /Applications and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/BRYANN2K/NotProton/main/install.sh | sh
#
# curl marks nothing as quarantined, so macOS opens Cartouche without the
# "Not Opened" warning a browser download gets (docs/adr/0012). Before anything
# is installed, the archive must match the SHA-256 published with the release,
# and the app must be signed with Cartouche's own certificate.
set -eu

# SHA-1 of the certificate that signs every release (docs/RELEASE.md)
cert_sha1=
bundle_id=dev.bryann2k.cartouche

release=${CARTOUCHE_RELEASE_URL:-https://github.com/BRYANN2K/NotProton/releases/latest/download}
apps=${CARTOUCHE_APPLICATIONS:-/Applications}

say() { printf '%s\n' "$*"; }
fail() {
    printf 'Cartouche was not installed: %s\n' "$*" >&2
    exit 1
}

main() {
    [ "$(uname -s)" = Darwin ] || fail "Cartouche runs on macOS only."
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || fail "Cartouche needs a Mac with Apple silicon."
    [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ] || fail "Cartouche needs macOS 15 or later."
    [ -n "$cert_sha1" ] || fail "this copy of install.sh does not name Cartouche's certificate."

    # Plain http only to this Mac, for the tests in packaging/tests
    case $release in
        https://*) proto='=https' ;;
        http://127.0.0.1:*) proto='=http' ;;
        *) fail "it downloads only over https, not from $release." ;;
    esac

    work=$(mktemp -d "${TMPDIR:-/tmp}/cartouche-install.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' INT TERM

    say "Downloading the release checksum…"
    fetch SHA256SUMS || fail "SHA256SUMS could not be downloaded from $release."
    archive=$(sed -n 's/^[0-9a-f]\{64\}  \(Cartouche-[0-9A-Za-z.+-]*\.zip\)$/\1/p' "$work/SHA256SUMS" | head -n 1)
    [ -n "$archive" ] || fail "SHA256SUMS names no Cartouche archive."
    version=${archive#Cartouche-}
    version=${version%.zip}

    say "Downloading Cartouche $version…"
    fetch "$archive" || fail "$archive could not be downloaded from $release."

    say "Checking the SHA-256…"
    if ! (cd "$work" && grep -F "  $archive" SHA256SUMS | shasum -a 256 -c -s -); then
        rm -f "$work/$archive"
        fail "$archive does not match the SHA-256 published with the release, so it was deleted."
    fi

    mkdir "$work/unpacked"
    ditto -x -k "$work/$archive" "$work/unpacked" || fail "$archive could not be unpacked."
    app="$work/unpacked/Cartouche.app"
    [ -d "$app" ] || fail "$archive holds no Cartouche.app."

    say "Checking the signature…"
    requirement="identifier \"$bundle_id\" and certificate leaf = H\"$cert_sha1\""
    codesign --verify --deep --strict -R "=$requirement" "$app" 2>/dev/null \
        || fail "the app in $archive is not signed with Cartouche's certificate."

    dest="$apps/Cartouche.app"
    [ -w "$apps" ] || fail "$apps cannot be changed by $(id -un). Ask an administrator, or use the disk image."
    if pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1; then
        fail "Cartouche is open. Quit it, then run the command again."
    fi
    if [ -e "$dest" ]; then
        mv "$dest" "$work/previous.app" || fail "the copy in $apps could not be replaced."
    fi
    if ! mv "$app" "$dest"; then
        [ -e "$work/previous.app" ] && mv "$work/previous.app" "$dest"
        fail "Cartouche could not be moved to $apps."
    fi
    say "Installed in $dest"

    # If a future macOS quarantines curl downloads too, say what to expect
    if xattr -p com.apple.quarantine "$dest" >/dev/null 2>&1; then
        say "macOS will ask once before Cartouche opens. If it says it can't check Cartouche:"
        say "  1. Click Done."
        say "  2. Open System Settings > Privacy & Security, scroll down, click Open Anyway."
        say "  3. Confirm with your password."
    fi

    if [ -z "${CARTOUCHE_NO_OPEN:-}" ]; then
        say "Opening Cartouche…"
        open "$dest"
    fi
}

fetch() {
    curl -fsSL --proto "$proto" --retry 2 -o "$work/$1" "$release/$1"
}

# Nothing runs until the whole script has arrived
main "$@"
