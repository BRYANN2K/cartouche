#!/bin/sh
# qa/run-codex.sh — run one QA persona, or all of them in order.
#
#   qa/run-codex.sh <beginner|medium|senior|all> [extra codex exec args...]
#
# Assembles the prompt (persona + scenarios + report template), runs
# `codex exec -m gpt-6.1-sol -c model_reasoning_effort="medium"`, and saves the
# report to qa/reports/<persona>-<date>.md plus a raw transcript next to it.
# Personas run strictly one after another: they share the screen, so never run
# two instances of this script at once.
set -eu

QA_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
    echo "usage: $0 <beginner|medium|senior|all> [extra codex exec args...]" >&2
    exit 2
}

[ $# -ge 1 ] || usage
PERSONA=$1
shift || true

case $PERSONA in
    beginner|medium|senior) LIST=$PERSONA ;;
    all)                  LIST="beginner medium senior" ;;
    *)                    usage ;;
esac

REPORTS="$QA_DIR/reports"
mkdir -p "$REPORTS" "$REPORTS/shots/beginner" "$REPORTS/shots/medium" "$REPORTS/shots/senior"

command -v codex >/dev/null 2>&1 || {
    echo "run-codex.sh: 'codex' CLI not found in PATH" >&2
    exit 1
}

run_one() {
    persona=$1
    shift
    stamp=$(date +%Y-%m-%d-%H%M)
    report="$REPORTS/$persona-$stamp.md"
    transcript="$REPORTS/$persona-$stamp.transcript.txt"
    prompt="$REPORTS/.prompt-$persona-$$.md"

    {
        cat "$QA_DIR/personas/$persona.md"
        printf '\n\n---\n\n# Appendix A: scenario checklist\n\n'
        cat "$QA_DIR/scenarios.md"
        printf '\n\n---\n\n# Appendix B: report template\n\n'
        cat "$QA_DIR/report-template.md"
        printf '\n\n---\n\n# Output\n\n'
        printf 'Write your report to `%s` (overwrite if it exists).\n' "$report"
        printf 'Screenshots go under `%s`.\n' "$REPORTS/shots/$persona/"
        printf 'Work from the repository root: `%s`.\n' "$(CDPATH= cd -- "$QA_DIR/.." && pwd)"
    } > "$prompt"

    echo "run-codex.sh: persona=$persona report=$report"
    # tee streams the transcript; a marker file preserves codex's exit status,
    # which the pipe would otherwise mask.
    # shellcheck disable=SC2086
    { codex exec -m gpt-6.1-sol -c model_reasoning_effort="medium" "$@" \
        "$(cat "$prompt")" || touch "$transcript.failed"; } 2>&1 | tee "$transcript"
    rm -f "$prompt"

    ok=1
    if [ -f "$transcript.failed" ]; then
        rm -f "$transcript.failed"
        echo "run-codex.sh: codex exited nonzero for $persona; transcript kept" >&2
        ok=0
    fi
    if [ ! -s "$report" ]; then
        echo "run-codex.sh: persona did not write $report; keeping transcript" >&2
        ok=0
    fi
    [ "$ok" -eq 1 ]
}

make -C "$QA_DIR/.." -s -o app-payload qa-app || { echo "run-codex.sh: QA build failed" >&2; exit 1; }
export QA_NO_BUILD=1

# Personas run one after another — they share the screen. A failing persona
# does not stop the later ones, but the script still reports it at the end.
status=0
for p in $LIST; do
    run_one "$p" "$@" || status=1
done
exit "$status"
