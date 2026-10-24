#!/bin/sh
# qa/launch.sh <profile> [--port <n>]
#
# Builds out/Cartouche-QA.app (make qa-app — the debug build that honours
# CARTOUCHE_QA_BASE_URL), mints a throwaway HOME inside the worktree with
# qa/world/make_world.py, starts qa/mocks/server.py, then launches the app
# with HOME, CFFIXED_USER_HOME and CARTOUCHE_QA_BASE_URL pointed at the fakes.
# Nothing outside the scratch dir is touched. See qa/README.md.

set -eu

PROFILES="clean steam stores retro full offline broken"

fail() { echo "qa/launch.sh: $*" >&2; exit 1; }
usage() {
    cat >&2 <<EOF
usage: qa/launch.sh <profile> [--port <n>]
profiles: $PROFILES
EOF
    exit 2
}

[ $# -ge 1 ] || usage
PROFILE="$1"; shift

PORT="${QA_PORT:-8890}"
while [ $# -gt 0 ]; do
    case "$1" in
        --port) [ $# -ge 2 ] || usage; PORT="$2"; shift 2 ;;
        *) usage ;;
    esac
done
case "$PORT" in *[!0-9]* | "") fail "--port needs a number" ;; esac

# Scenario profile -> world profile + pre-armed mock scenarios
# (qa/scenarios.md). stores' sign-in state lives in the Keychain and cannot be
# planted, so it gets the Steam world.
case "$PROFILE" in
    clean)   WORLD_PROFILE=empty;  WORLD_FLAGS="";         ARM="" ;;
    steam|stores) WORLD_PROFILE=medium; WORLD_FLAGS="";    ARM="" ;;
    retro)   WORLD_PROFILE=retro;  WORLD_FLAGS="";         ARM="" ;;
    full)    WORLD_PROFILE=senior; WORLD_FLAGS="";         ARM="controller-dualsense" ;;
    offline) WORLD_PROFILE=senior; WORLD_FLAGS="--stale";  ARM="net-down controller-dualsense" ;;
    broken)  WORLD_PROFILE=senior; WORLD_FLAGS="--damage";
             ARM="controller-dualsense store-token-expired:epic crash-missing-dll installer-fail-unarc" ;;
    *) echo "qa/launch.sh: unknown profile '$PROFILE'" >&2; usage ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MAKE_WORLD="$ROOT/qa/world/make_world.py"
SERVER="$ROOT/qa/mocks/server.py"
[ -f "$MAKE_WORLD" ] || fail "qa/world/make_world.py is missing (the world generator has not landed in this checkout)"
[ -f "$SERVER" ] || fail "qa/mocks/server.py is missing (the mock server has not landed in this checkout)"

# Remember the real home before anything could reassign it.
REAL_HOME="$(cd "$HOME" && pwd -P)"

APP="$ROOT/out/Cartouche-QA.app"
if [ "${QA_NO_BUILD:-}" != 1 ]; then
    echo "==> Building out/Cartouche-QA.app (payload skipped: make -s -o app-payload qa-app)"
    make -C "$ROOT" -s -o app-payload qa-app SWIFT_FLAGS="${SWIFT_FLAGS:-}"
fi
[ -x "$APP/Contents/MacOS/Cartouche" ] || fail "the build did not produce $APP"

# The scratch HOME lives inside the worktree: a fresh dir under scratch/ that
# only this run owns. mktemp -d cannot collide with anything real.
SCRATCH_DIR="$ROOT/scratch"
mkdir -p "$SCRATCH_DIR"
QA_HOME="$(mktemp -d "$SCRATCH_DIR/qa-home-$PROFILE.XXXXXX")" || fail "mktemp failed"
QA_HOME="$(cd "$QA_HOME" && pwd -P)"

# The point of the harness is that the app never sees the real home; check the
# scratch dir both ways, resolved, before handing it to anything.
case "$QA_HOME" in
    "" | "/" | "$REAL_HOME" | "$HOME" | "$ROOT" | "$SCRATCH_DIR")
        fail "refusing to run: scratch HOME $QA_HOME is not a dedicated dir" ;;
esac
case "$QA_HOME" in
    "$SCRATCH_DIR"/qa-home-*) ;;
    *) fail "refusing to run: $QA_HOME is outside $SCRATCH_DIR" ;;
esac

echo "==> Building a $WORLD_PROFILE world at $QA_HOME"
# shellcheck disable=SC2086
python3 "$MAKE_WORLD" "$QA_HOME" --profile "$WORLD_PROFILE" $WORLD_FLAGS

BASE="http://127.0.0.1:$PORT"
python3 "$SERVER" --port "$PORT" >"$QA_HOME/qa-server.log" 2>&1 &
MOCK_PID=$!

tries=0
until curl -fsS -o /dev/null "$BASE/__control" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ] || ! kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null || true
        fail "mock server did not come up — see $QA_HOME/qa-server.log"
    fi
    sleep 0.1
done
echo "==> Mock server on $BASE (pid $MOCK_PID)"

# The profile's built-in mock scenarios (the machine state a session starts
# from); the checklist can arm more live through /__control.
for name in $ARM; do
    curl -fsS -X POST "$BASE/__control/$name" >/dev/null \
        || fail "could not arm mock scenario $name"
    echo "==> Armed mock scenario $name"
done

env HOME="$QA_HOME" CFFIXED_USER_HOME="$QA_HOME" CARTOUCHE_QA_BASE_URL="$BASE" \
    "$APP/Contents/MacOS/Cartouche" >"$QA_HOME/qa-app.log" 2>&1 &
APP_PID=$!

cat <<EOF

QA is up.
  profile:     $PROFILE (world: $WORLD_PROFILE${WORLD_FLAGS:+ $WORLD_FLAGS})
  home:        $QA_HOME
  app:         pid $APP_PID — log $QA_HOME/qa-app.log
  mock:        pid $MOCK_PID — log $QA_HOME/qa-server.log
  QA control:  http://127.0.0.1:$PORT/__control

Stop it with:  kill $APP_PID $MOCK_PID
The scratch home can be deleted afterwards: rm -rf "$QA_HOME"
EOF
