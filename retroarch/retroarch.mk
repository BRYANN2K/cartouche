# RetroArch targets, included by the top-level Makefile

RETROARCH_OUT     := $(OUT_DIR)/retroarch
RETROARCH_DERIVED := build/retroarch-derived
RETROARCH_RIG     := build/retroarch-rig

.PHONY: retroarch retroarch-embed retroarch-rig retroarch-scancheck retroarch-tests

# RetroArch.app from vendor/RetroArch, with the Xcode project
retroarch:
	sh retroarch/scripts/build-retroarch.sh "$(RETROARCH_DERIVED)" "$(RETROARCH_OUT)"

# Into Cartouche.app/Contents/Helpers, after make app and make retroarch
retroarch-embed:
	sh retroarch/scripts/embed-retroarch.sh "$(RETROARCH_OUT)/RetroArch.app" "$(APP_BUNDLE)" "$(APP_SIGN_ID)"

# A command-line RetroArch for the MCP tests
retroarch-rig:
	sh retroarch/scripts/build-test-rig.sh "$(RETROARCH_RIG)"

# Git holds no RetroArch binary and no core, and the scan catches a planted one
retroarch-scancheck:
	@sh retroarch/scripts/scan-binaries.sh .
	@sh retroarch/Tests/scancheck.sh

# RetroArchKit. With CARTOUCHE_RETROARCH set, also the tests that run it
retroarch-tests:
	swift test --package-path retroarch --no-parallel

.PHONY: retroarch-testcore

# The libretro core the session tests load, built from source, never shipped
retroarch-testcore: $(RETROARCH_RIG)/cartouche_test_libretro.dylib

$(RETROARCH_RIG)/cartouche_test_libretro.dylib: retroarch/Tests/testcore/testcore.c
	@mkdir -p $(RETROARCH_RIG)
	$(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c99 -O2 -Wall -dynamiclib \
		-Ivendor/RetroArch/libretro-common/include -o $@ $<

.PHONY: retroarch-l10ncheck

# Every RetroArchKit string is in its catalog and translated, as l10ncheck does for the app
retroarch-l10ncheck:
	@swift build --package-path retroarch -c release >/dev/null
	@bin=$$(swift build --package-path retroarch -c release --show-bin-path); \
	python3 dylib/tests/l10ncheck.py retroarch/Sources/RetroArchKit/Resources/Localizable.xcstrings \
		"$$bin/../../Intermediates.noindex/RetroArchKit.build/$$(basename "$$bin")/RetroArchKit-t.build" zh-Hans it
