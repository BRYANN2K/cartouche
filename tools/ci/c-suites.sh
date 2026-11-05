#!/bin/sh
# The hermetic C suites, as the CI tests job runs them (docs/ci/CI.md). Each builds its
# own scratch fixtures; none needs the Wine trees, a game or a signing identity.
set -eu
for suite in sigcheck callscheck webpatch-fixtures peicon-fixtures panel-behavior spawn-env \
  activatecheck compatcheck fps-counter-tests compatsvc-check libexport-check services-check \
  webuicheck shortcutcheck launch-shell envcheck buildcheck settingscheck routecheck \
  bridgecheck gamedrivecheck launchercheck seedcheck packagingcheck; do
  echo "::group::make $suite"
  make -s "$suite"
  echo "::endgroup::"
done
echo "==> c-suites: 24 suites passed"
