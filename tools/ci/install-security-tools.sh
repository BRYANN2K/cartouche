#!/bin/sh
# Installs the security tools the CI and nightly jobs run, each pinned by version and
# checked against its sha256 before it is unpacked. Never piped into a shell.
#
#   tools/ci/install-security-tools.sh <bin dir> <tool>...
#   tools: gitleaks osv-scanner zizmor actionlint (Linux x86_64 release binaries),
#          cppcheck (built from its source tarball, Linux or macOS)
#
# Each sha256 below was checked on 2026-11-05 against the project's own checksum file
# where it publishes one (gitleaks_<v>_checksums.txt, osv-scanner_SHA256SUMS) and against
# the digest GitHub records for the release asset. Semgrep is pinned by hash in
# tools/ci/requirements-security.txt. Bump a version and its sha256 together.
set -eu

GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb # gitleaks_8.30.1_linux_x64.tar.gz
OSV_SCANNER_VERSION=2.7.0
OSV_SCANNER_SHA256=160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b # osv-scanner_linux_amd64
ZIZMOR_VERSION=1.32.0
ZIZMOR_SHA256=bb110cc765eca9cd7efb2e284a956be5974c60027b0970f16397d86208a9957b # zizmor-x86_64-unknown-linux-gnu.tar.gz
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 # actionlint_1.7.12_linux_amd64.tar.gz
CPPCHECK_VERSION=2.22.0
CPPCHECK_SHA256=d74945deb2d50393430e07596b766f8a779512c7f60dac2a30ea64e059ece57b # github.com/danmar/cppcheck/archive/refs/tags/2.22.0.tar.gz

bin=$1; shift
mkdir -p "$bin"
bin=$(cd "$bin" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh=https://github.com

# url, sha256, file name in $tmp
fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/$3" "$1"
  echo "$2  $tmp/$3" | shasum -a 256 -c - >/dev/null || { echo "install-security-tools: sha256 mismatch for $1" >&2; exit 1; }
}

linux_x86_64() {
  [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || { echo "install-security-tools: $1 is pinned for Linux x86_64 only" >&2; exit 1; }
}

for tool in "$@"; do
  case "$tool" in
    gitleaks)
      linux_x86_64 "$tool"
      fetch "$gh/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" "$GITLEAKS_SHA256" gitleaks.tar.gz
      tar xzf "$tmp/gitleaks.tar.gz" -C "$tmp" gitleaks
      install -m 755 "$tmp/gitleaks" "$bin/gitleaks"
      "$bin/gitleaks" version | grep -qx "$GITLEAKS_VERSION" ;;
    osv-scanner)
      linux_x86_64 "$tool"
      fetch "$gh/google/osv-scanner/releases/download/v$OSV_SCANNER_VERSION/osv-scanner_linux_amd64" "$OSV_SCANNER_SHA256" osv-scanner
      install -m 755 "$tmp/osv-scanner" "$bin/osv-scanner"
      "$bin/osv-scanner" --version | grep -q "$OSV_SCANNER_VERSION" ;;
    zizmor)
      linux_x86_64 "$tool"
      fetch "$gh/zizmorcore/zizmor/releases/download/v$ZIZMOR_VERSION/zizmor-x86_64-unknown-linux-gnu.tar.gz" "$ZIZMOR_SHA256" zizmor.tar.gz
      tar xzf "$tmp/zizmor.tar.gz" -C "$tmp" zizmor
      install -m 755 "$tmp/zizmor" "$bin/zizmor"
      "$bin/zizmor" --version | grep -qx "zizmor $ZIZMOR_VERSION" ;;
    actionlint)
      linux_x86_64 "$tool"
      fetch "$gh/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" "$ACTIONLINT_SHA256" actionlint.tar.gz
      tar xzf "$tmp/actionlint.tar.gz" -C "$tmp" actionlint
      install -m 755 "$tmp/actionlint" "$bin/actionlint"
      "$bin/actionlint" -version | head -1 | grep -qx "$ACTIONLINT_VERSION" ;;
    cppcheck)
      # No release binary for Linux or macOS. FILESDIR is baked in at configure time, so
      # the prefix is the final place: <bin dir>/../cppcheck, which a cache can keep. A
      # cached build of another version is rebuilt.
      prefix=$(dirname "$bin")/cppcheck
      if [ "$("$prefix/bin/cppcheck" --version 2>/dev/null)" != "Cppcheck $CPPCHECK_VERSION" ]; then
        rm -rf "$prefix"
        fetch "$gh/danmar/cppcheck/archive/refs/tags/$CPPCHECK_VERSION.tar.gz" "$CPPCHECK_SHA256" cppcheck.tar.gz
        tar xzf "$tmp/cppcheck.tar.gz" -C "$tmp"
        jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
        cmake -S "$tmp/cppcheck-$CPPCHECK_VERSION" -B "$tmp/cppcheck-build" -DCMAKE_BUILD_TYPE=Release \
          -DUSE_MATCHCOMPILER=On -DBUILD_GUI=Off -DBUILD_TESTS=Off -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
        cmake --build "$tmp/cppcheck-build" -j "$jobs" >/dev/null
        cmake --install "$tmp/cppcheck-build" >/dev/null
      fi
      ln -sf "$prefix/bin/cppcheck" "$bin/cppcheck"
      "$bin/cppcheck" --version | grep -qx "Cppcheck $CPPCHECK_VERSION" ;;
    *) echo "install-security-tools: unknown tool $tool" >&2; exit 2 ;;
  esac
  echo "==> $tool installed in $bin"
done
