# shellcheck shell=sh disable=SC2034 # the reasons are read by the suites that source this
# Sourced by the frame counter suites. A hosted CI runner (CARTOUCHE_CI_HOSTED=1) is a
# virtual Mac: frames are not paced exactly, and SIP is off, so dyld may load an inserted
# library into a hardened binary. Each condition is probed, and the assertions that need
# it are skipped by name with the reason. Off a hosted runner nothing is ever skipped.
skips=0
skip() { printf '  SKIP  %s\n         why  %s\n' "$1" "$2"; skips=$((skips + 1)); }
on_hosted() { [ "${CARTOUCHE_CI_HOSTED:-}" = 1 ]; }

pacing_exact() {
  on_hosted || return 0
  [ "$(sysctl -n kern.hv_vmm_present 2> /dev/null)" != 1 ]
}
pacing_why="hosted runner is a virtual machine, frame pacing is not exact there"

# Usage: frames <name> <want> <got>. Off exact pacing, the game must still present frames.
frames() {
  if pacing_exact; then is "$1" "$2" "$3"; return; fi
  if [ "$3" -gt 0 ] 2> /dev/null; then skip "$1: exactly $2 (got $3)" "$pacing_why"
  else bad "$1" "presented frames" "$3"; fi
}

# Usage: hardened_refuses <hardened binary> <library>. True when dyld keeps the library
# out of the hardened binary, which the refusal assertions rely on.
hardened_refuses() {
  on_hosted || return 0
  probe_marker=$(mktemp -u)
  DYLD_INSERT_LIBRARIES="$2" CARTOUCHE_FPS_PROBE="$probe_marker" "$1" locked 60 0 > /dev/null 2>&1
  if [ -f "$probe_marker" ]; then rm -f "$probe_marker"; return 1; fi
  return 0
}
hardened_why="dyld loads inserted libraries into hardened binaries on this hosted runner (SIP off)"

skipped_note() { [ "$skips" -eq 0 ] || printf ' (%s skipped on this hosted runner, reasons above)' "$skips"; }
