#!/bin/sh
# Runs the script of ci.yml's "required" job against sample job results.
# Evidence for "Red check blocks merge".
for RESULTS in "success success success success" "success failure success success" \
    "success skipped success success" "cancelled success success success"; do
    (
        for r in $RESULTS; do
            [ "$r" = success ] || exit 1
        done
    )
    echo "$RESULTS -> exit $?"
done
