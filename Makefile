CC       := clang
ARCH     := arm64
MIN_VER  := 15.0
GLASS_SDK := 26.0
AVAIL    := -Werror=unguarded-availability-new

# cartouche_identity.h holds the names the app, the dylib and this file share
IDENTITY_INC := app/Sources/CartoucheIdentity/include
identity = $(shell sed -n 's/^\#define $(1) "\(.*\)"/\1/p' $(IDENTITY_INC)/cartouche_identity.h)
DYLIB_NAME := $(call identity,CARTOUCHE_DYLIB_NAME)
DYLIB_BASE := $(basename $(DYLIB_NAME))

CFLAGS   := -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) $(AVAIL) \
            -std=c17 -O2 -Wall -Wextra -Wno-unused-parameter \
            -fPIC -MMD -MP \
            -Idylib -I$(IDENTITY_INC) -Ivendor -Ivendor/dobby/include
LDFLAGS  := -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) \
            -dynamiclib -install_name @rpath/$(DYLIB_NAME)

FRAMEWORKS := -framework CoreFoundation -framework CoreGraphics

DOBBY_DIR  := build/dobby
DOBBY_LIBS := $(DOBBY_DIR)/libdobby.a \
              $(DOBBY_DIR)/builtin-plugin/SymbolResolver/libdobby_symbol_resolver.a \
              $(DOBBY_DIR)/builtin-plugin/SymbolResolver/libmacho_ctx_kit.a \
              $(DOBBY_DIR)/builtin-plugin/SymbolResolver/libshared_cache_ctx_kit.a \
              $(DOBBY_DIR)/external/osbase/libosbase.a \
              $(DOBBY_DIR)/external/logging/liblogging.a

SRCS := \
	dylib/core/loader.c \
	dylib/core/macho.c \
	dylib/resolver/anchor.c \
	dylib/resolver/aob.c \
	dylib/resolver/resolver.c \
	dylib/resolver/sigdb.c \
	dylib/util/log.c \
	dylib/util/file.c \
	dylib/util/peicon.c \
	dylib/hooks/hooks.c \
	dylib/hooks/hook_compat.c \
	dylib/hooks/hook_shortcut.c \
	dylib/hooks/hook_icon.c \
	dylib/hooks/hook_shortcut_bundle.c \
	dylib/hooks/hook_webui.c \
	dylib/hooks/hook_webpatch.c \
	dylib/hooks/hook_spawn.c \
	dylib/hooks/hook_launch.c \
	dylib/hooks/hook_activate.c \
	dylib/feats/compat.c \
	dylib/feats/webui.c \
	dylib/feats/compatsvc.c \
	dylib/feats/libexport.c \
	dylib/feats/usershortcuts.c \
	dylib/feats/webpatch.c \
	dylib/feats/nativeplatform.c \
	dylib/feats/input_access.c \
	vendor/cJSON.c

OUT_DIR     := out
TEST_CC     := $(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c17 -g \
	-Wall -Wextra -Wno-unused-parameter -Idylib -I$(IDENTITY_INC)

GENERATED_DIR := $(OUT_DIR)/generated
RUN_SCRIPT_H  := $(GENERATED_DIR)/compat_run.h
CFLAGS += -I$(GENERATED_DIR)

ARM64_DYLIB := $(OUT_DIR)/$(DYLIB_BASE).arm64.dylib
X86_STUB    := $(OUT_DIR)/$(DYLIB_BASE).x86_64.dylib
TARGET      := $(OUT_DIR)/$(DYLIB_NAME)

OBJS := $(patsubst %.c,$(OUT_DIR)/%.o,$(SRCS))
DEPS := $(OBJS:.o=.d)

.PHONY: all clean rebuild dobby deploy dylib dylib-install sigcheck fonts fonts-install app-payload app qa-app app-zip \
        anchorcheck callscheck sigdb-fixtures webpatch-fixtures peicon-fixtures panel-behavior app-tests \
        tests-list overlay-shim overlay-shim-install overlay-shim-tests \
        overlay-shim-bench iconmaker icon \
        appinfo helpers-install unarc-driver game-restore ntdll-resolve bridge runcheck compatcheck \
        compatsvc-check libexport-check services-check webuicheck shortcutcheck scriptcheck envcheck buildcheck settingscheck routecheck bridgecheck gamedrivecheck backendcheck launchercheck launchlogcheck launch-shell activatecheck FORCE

APP_PAYLOAD := app/Sources/NotProtonApp/Resources/payload

all: $(TARGET) $(APP_PAYLOAD)

dylib: $(TARGET)

# SwiftPM's `.copy("Resources/payload")` in Package.swift needs this directory
# to exist
$(APP_PAYLOAD):
	@mkdir -p $(APP_PAYLOAD)

TEST_PATHS := dylib/tests overlay-shim/tests app/Tests

tests-list:
	@for p in $(TEST_PATHS); do echo $$p; done

# A check with no inputs left is reported
SKIP = echo "==> $(1): $(2) not present, skipped"

runcheck:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		$(call SKIP,runcheck,shellcheck); exit 0; fi; \
	shellcheck dylib/feats/compat_run.sh && sh -n dylib/feats/compat_run.sh && \
	echo "==> runcheck: the run script lints and parses clean"

.PHONY: seedcheck
seedcheck:
	@if [ ! -f dylib/tests/seedcheck.sh ]; then $(call SKIP,seedcheck,dylib/tests/seedcheck.sh); exit 0; fi; \
	sh dylib/tests/seedcheck.sh dylib/feats/compat_run.sh

envcheck:
	@if [ ! -f dylib/tests/envcheck.sh ]; then $(call SKIP,envcheck,dylib/tests/envcheck.sh); exit 0; fi; \
	sh dylib/tests/envcheck.sh dylib/feats/compat_run.sh

buildcheck:
	@if [ ! -f dylib/tests/buildcheck.sh ]; then $(call SKIP,buildcheck,dylib/tests/buildcheck.sh); exit 0; fi; \
	sh dylib/tests/buildcheck.sh dylib/feats/compat_run.sh

settingscheck:
	@if [ ! -f dylib/tests/settingscheck.sh ]; then $(call SKIP,settingscheck,dylib/tests/settingscheck.sh); exit 0; fi; \
	sh dylib/tests/settingscheck.sh dylib/feats/compat_run.sh

routecheck:
	@if [ ! -f dylib/tests/routecheck.sh ]; then $(call SKIP,routecheck,dylib/tests/routecheck.sh); exit 0; fi; \
	sh dylib/tests/routecheck.sh dylib/feats/compat_run.sh

bridgecheck:
	@if [ ! -f dylib/tests/bridgecheck.sh ]; then $(call SKIP,bridgecheck,dylib/tests/bridgecheck.sh); exit 0; fi; \
	sh dylib/tests/bridgecheck.sh dylib/feats/compat_run.sh

gamedrivecheck:
	@if [ ! -f dylib/tests/gamedrivecheck.sh ]; then $(call SKIP,gamedrivecheck,dylib/tests/gamedrivecheck.sh); exit 0; fi; \
	sh dylib/tests/gamedrivecheck.sh dylib/feats/compat_run.sh

# Run by compatcheck as well, which the CI runs
backendcheck:
	@if [ ! -f dylib/tests/backendcheck.sh ]; then $(call SKIP,backendcheck,dylib/tests/backendcheck.sh); exit 0; fi; \
	sh dylib/tests/backendcheck.sh dylib/feats/compat_run.sh

launchercheck:
	@if [ ! -f dylib/tests/launchercheck.sh ]; then $(call SKIP,launchercheck,dylib/tests/launchercheck.sh); exit 0; fi; \
	sh dylib/tests/launchercheck.sh dylib/feats/compat_run.sh

.PHONY: mincheck
mincheck:
	@sh dylib/tests/mincheck.sh "$(APP_BUNDLE)" "$(MIN_VER)" "$(GLASS_SDK)"

.PHONY: l10ncheck
l10ncheck:
	@bin=$$(swift build --package-path app -c release --show-bin-path); \
	python3 dylib/tests/l10ncheck.py app/Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings \
		"$$bin/../../Intermediates.noindex/NotProtonApp.build/$$(basename "$$bin")" zh-Hans it fr

.PHONY: compat-data-tests
compat-data-tests:
	@python3 -I -m unittest discover -s tools/compat/tests -t tools/compat

# The Python suites of the CI tests job; packaging/tests run under packagingcheck.
# qa/world/test_make_world.py is left out until test_medium_installer agrees with the
# fixture it checks (docs/ci/CI.md)
.PHONY: python-tests
python-tests: compat-data-tests
	@python3 -I -m unittest discover -s tools/ci/tests
	@python3 qa/mocks/test_server.py

# runcheck owns compat_run.sh, whose warnings wait for a change that can move
# the embedded __text baseline; docs/research holds one-off zsh benches, not build scripts
SCRIPTS := $(shell git ls-files '*.sh' 2>/dev/null | grep -v -e '^dylib/feats/compat_run\.sh$$' -e '^docs/research/' -e '/Goldens/')

scriptcheck:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		$(call SKIP,scriptcheck,shellcheck); exit 0; fi; \
	if [ -z "$(strip $(SCRIPTS))" ]; then $(call SKIP,scriptcheck,a git checkout); exit 0; fi; \
	for s in $(SCRIPTS); do \
		shellcheck "$$s" || exit 1; \
		case "$$(head -1 "$$s")" in *bash*) sh=bash;; *zsh*) sh=zsh; command -v zsh >/dev/null || continue;; *) sh=sh;; esac; \
		$$sh -n "$$s" || exit 1; \
	done; \
	echo "==> scriptcheck: $(words $(SCRIPTS)) scripts lint and parse clean"

COMPATCHECK := $(OUT_DIR)/compatcheck
# c-asan clears it to run the C suite alone, the chained checks being shell and Metal
COMPATCHECK_CHAIN ?= 1

compatcheck: $(RUN_SCRIPT_H)
	@if [ ! -f dylib/tests/compatcheck.c ]; then $(call SKIP,compatcheck,dylib/tests/compatcheck.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -I$(GENERATED_DIR) \
	  -o $(COMPATCHECK) dylib/tests/compatcheck.c && \
	$(COMPATCHECK) && \
	{ [ -z "$(COMPATCHECK_CHAIN)" ] || { \
	$(MAKE) -s backendcheck && \
	$(MAKE) -s fpscheck && \
	$(MAKE) -s framegencheck; }; }

COMPATSVC_CHECK := $(OUT_DIR)/compatsvc-check

compatsvc-check:
	@if [ ! -f dylib/tests/compatsvc-check.c ]; then $(call SKIP,compatsvc-check,dylib/tests/compatsvc-check.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(COMPATSVC_CHECK) dylib/tests/compatsvc-check.c && \
	$(COMPATSVC_CHECK)

LIBEXPORT_CHECK := $(OUT_DIR)/libexport-check

libexport-check:
	@if [ ! -f dylib/tests/libexport-check.c ]; then $(call SKIP,libexport-check,dylib/tests/libexport-check.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(LIBEXPORT_CHECK) dylib/tests/libexport-check.c dylib/util/file.c vendor/cJSON.c && \
	$(LIBEXPORT_CHECK)

WEBUICHECK := $(OUT_DIR)/webuicheck

webuicheck:
	@if [ ! -f dylib/tests/webuicheck.c ]; then $(call SKIP,webuicheck,dylib/tests/webuicheck.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(WEBUICHECK) dylib/tests/webuicheck.c && \
	$(WEBUICHECK)

SERVICES_CHECK := $(OUT_DIR)/services-check

services-check:
	@if [ ! -f dylib/tests/services-check.c ]; then $(call SKIP,services-check,dylib/tests/services-check.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(SERVICES_CHECK) dylib/tests/services-check.c dylib/feats/compatsvc.c dylib/feats/libexport.c dylib/util/file.c vendor/cJSON.c && \
	$(SERVICES_CHECK)

SHORTCUT_BUNDLE_CHECK := $(OUT_DIR)/shortcut-bundle-check
SHORTCUTCHECK         := $(OUT_DIR)/shortcutcheck

shortcutcheck: $(OUT_DIR)/iconmaker
	@if [ ! -f dylib/tests/shortcutcheck.c ]; then $(call SKIP,shortcutcheck,dylib/tests/shortcutcheck.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(SHORTCUT_BUNDLE_CHECK) dylib/tests/shortcut-bundle-check.c && \
	$(SHORTCUT_BUNDLE_CHECK) && \
	$(TEST_CC) -o $(SHORTCUTCHECK) dylib/tests/shortcutcheck.c && \
	$(SHORTCUTCHECK) && \
	python3 dylib/tests/shortcut-launch.py $(OUT_DIR)/iconmaker

sigcheck:
	@if [ ! -f dylib/tests/sigcheck.py ]; then $(call SKIP,sigcheck,dylib/tests/sigcheck.py); exit 0; fi; \
	python3 dylib/tests/sigcheck.py

# Validates anchors against a real dlopen'd steamclient.dylib
ANCHORCHECK := $(OUT_DIR)/anchorcheck
ANCHORCHECK_SRCS := dylib/tests/anchorcheck.c \
	dylib/core/macho.c dylib/resolver/aob.c dylib/resolver/anchor.c \
	dylib/resolver/resolver.c dylib/resolver/sigdb.c \
	dylib/util/log.c dylib/util/file.c vendor/cJSON.c

$(ANCHORCHECK): $(ANCHORCHECK_SRCS) FORCE
	@mkdir -p $(dir $@)
	$(TEST_CC) -O1 -Ivendor \
	  -o $@ $(ANCHORCHECK_SRCS)

anchorcheck:
	@if [ ! -f dylib/tests/anchorcheck.c ]; then $(call SKIP,anchorcheck,dylib/tests/anchorcheck.c); exit 0; fi; \
	$(MAKE) -s $(ANCHORCHECK) && $(ANCHORCHECK)

CALLSCHECK := $(OUT_DIR)/callscheck
CALLSCHECK_SRCS := dylib/tests/callscheck.c $(filter-out dylib/tests/anchorcheck.c,$(ANCHORCHECK_SRCS))

$(CALLSCHECK): $(CALLSCHECK_SRCS)
	@mkdir -p $(dir $@)
	$(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c17 -g -O1 \
	  -Wall -Wextra -Wno-unused-parameter -Idylib -I$(IDENTITY_INC) -Ivendor \
	  -fsanitize=address,undefined -fno-sanitize-recover=all \
	  -o $@ $(CALLSCHECK_SRCS)

callscheck:
	@if [ ! -f dylib/tests/callscheck.c ]; then $(call SKIP,callscheck,dylib/tests/callscheck.c); exit 0; fi; \
	$(MAKE) -s $(CALLSCHECK) && $(CALLSCHECK)

SIGDB_FIXTURES := dylib/tests/sigdb-fixtures

sigdb-fixtures:
	@if [ ! -d $(SIGDB_FIXTURES) ] || [ ! -f dylib/tests/anchorcheck.c ]; then \
		$(call SKIP,sigdb-fixtures,$(SIGDB_FIXTURES)); exit 0; fi; \
	$(MAKE) -s $(ANCHORCHECK) || exit 1; \
	fail=0; n=0; \
	for f in $(SIGDB_FIXTURES)/*.json; do \
		n=$$((n+1)); \
		want=$$(awk -v name="$${f##*/}" '$$2 == name { print $$1 }' $(SIGDB_FIXTURES)/EXPECTED); \
		out=$$($(ANCHORCHECK) "$$f" 2>&1); rc=$$?; \
		if [ $$rc -ge 128 ]; then echo "crashed (rc=$$rc): $$f"; fail=1; continue; fi; \
		if [ $$rc -eq 3 ]; then \
			echo "anchorcheck cannot run here, so none of these fixtures were checked:"; \
			echo "$$out" | tail -1; fail=1; break; fi; \
		if [ -z "$$want" ]; then \
			echo "no expected status in $(SIGDB_FIXTURES)/EXPECTED: $$f"; fail=1; continue; fi; \
		if [ "$$rc" != "$$want" ]; then \
			echo "expected $$want, got $$rc: $$f"; fail=1; fi; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "==> $$n sigdb fixtures: none crashed, each exited as $(SIGDB_FIXTURES)/EXPECTED records"

PEICON_CHECK := $(OUT_DIR)/peicon-check

$(PEICON_CHECK): dylib/tests/peicon-check.c dylib/util/peicon.c dylib/util/peicon.h
	@mkdir -p $(dir $@)
	$(TEST_CC) -O1 -o $@ dylib/tests/peicon-check.c dylib/util/peicon.c

peicon-fixtures:
	@if [ ! -f dylib/tests/peicon-check.c ]; then \
		$(call SKIP,peicon-fixtures,dylib/tests/peicon-check.c); exit 0; fi; \
	$(MAKE) -s $(PEICON_CHECK) || exit 1; \
	tmp=$$(mktemp -d); \
	$(PEICON_CHECK) "$$tmp"; rc=$$?; \
	rm -rf "$$tmp"; \
	if [ $$rc -eq 9 ]; then \
		echo "peicon-check ran out of time, so a hostile resource tree is unbounded"; fi; \
	exit $$rc

GATECHECK         := $(OUT_DIR)/gatecheck
WEBPATCH_FIXTURES := dylib/tests/webpatch-fixtures

$(GATECHECK): dylib/tests/gatecheck.c dylib/feats/webpatch.c dylib/feats/webpatch.h
	@mkdir -p $(dir $@)
	$(TEST_CC) -O1 -o $@ dylib/tests/gatecheck.c

NATIVEPLATFORMCHECK := $(OUT_DIR)/nativeplatformcheck

$(NATIVEPLATFORMCHECK): dylib/tests/nativeplatformcheck.c dylib/feats/nativeplatform.c dylib/feats/nativeplatform.h dylib/util/file.c
	@mkdir -p $(dir $@)
	$(TEST_CC) -O1 -DHELPER_TIMEOUT_MS=1000 -o $@ dylib/tests/nativeplatformcheck.c dylib/feats/nativeplatform.c dylib/util/file.c

webpatch-fixtures:
	@if [ ! -d $(WEBPATCH_FIXTURES) ] || [ ! -f dylib/tests/gatecheck.c ]; then \
		$(call SKIP,webpatch-fixtures,$(WEBPATCH_FIXTURES)); exit 0; fi; \
	$(MAKE) -s $(GATECHECK) || exit 1; \
	$(GATECHECK) || exit 1; \
	fail=0; tmp=$$(mktemp -d); n=0; \
	for good in $(WEBPATCH_FIXTURES)/gates.*.js; do \
		n=$$(( $$n + 1 )); base=$$(basename $$good .js); \
		cat $$good $$good > $$tmp/$$base.doubled.js; \
		head -c $$(( $$(stat -f %z $$good) / 2 )) $$good > $$tmp/$$base.truncated.js; \
		for spec in "$$good:APPLIED" "$$tmp/$$base.doubled.js:REJECTED" \
		            "$$tmp/$$base.truncated.js:REJECTED"; do \
			f=$${spec%:*}; want=$${spec##*:}; \
			out=$$($(GATECHECK) "$$f" 2>&1); rc=$$?; \
			case "$$out" in *WRONG*) echo "$$out"; fail=1 ;; esac; \
			case "$$out" in *$$want*) ;; *) echo "expected $$want: $$out"; fail=1 ;; esac; \
			if [ $$rc -ne 0 ]; then fail=1; fi; \
		done; \
	done; \
	for f in $(WEBPATCH_FIXTURES)/library.*.js; do \
		out=$$($(GATECHECK) --library "$$f" $$tmp/$$(basename $$f .js).out.js 2>&1) || { echo "$$out"; fail=1; }; \
		out=$$($(GATECHECK) --library-literal "$$f" $$tmp/$$(basename $$f .js).literal.out.js 2>&1) || { echo "$$out"; fail=1; }; \
	done; \
	out=$$($(GATECHECK) --older-filter $$tmp/library.older.out.js 2>&1) || { echo "$$out"; fail=1; }; \
	if [ $$fail -eq 0 ]; then \
		if command -v node >/dev/null 2>&1; then \
			node dylib/tests/library-filter/behavior.js $$tmp/library.*.out.js || fail=1; \
		else echo "==> library filter: node not found, skipped"; fi; \
	fi; \
	rm -rf $$tmp; \
	$(MAKE) -s $(NATIVEPLATFORMCHECK) && $(NATIVEPLATFORMCHECK) || fail=1; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "==> gate table and $$n webpatch fixtures: anchors intact, drift refused"

LAUNCH_SHELL := $(OUT_DIR)/launch-shell

launch-shell:
	@if [ ! -f dylib/tests/launch-shell.c ]; then $(call SKIP,launch-shell,dylib/tests/launch-shell.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -O1 -o $(LAUNCH_SHELL) dylib/tests/launch-shell.c && \
	$(LAUNCH_SHELL)

ACTIVATECHECK := $(OUT_DIR)/activatecheck

activatecheck:
	@if [ ! -f dylib/tests/activatecheck.c ]; then $(call SKIP,activatecheck,dylib/tests/activatecheck.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -O1 -o $(ACTIVATECHECK) dylib/tests/activatecheck.c -framework AppKit -lobjc && \
	$(ACTIVATECHECK)

SPAWN_ENV := $(OUT_DIR)/spawn-env

spawn-env:
	@if [ ! -f dylib/tests/spawn-env.c ]; then $(call SKIP,spawn-env,dylib/tests/spawn-env.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -O1 -o $(SPAWN_ENV) dylib/tests/spawn-env.c && \
	$(SPAWN_ENV)

SPAWN_LIVE := dylib/tests/spawn-live

spawn-live: $(TARGET)
	@if [ ! -d $(SPAWN_LIVE) ]; then $(call SKIP,spawn-live,$(SPAWN_LIVE)); exit 0; fi; \
	tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; mkdir -p $$tmp/sub; \
	$(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c17 -O1 -Wall -Wextra \
	  -o $$tmp/child $(SPAWN_LIVE)/child.c || exit 1; \
	$(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c17 -O1 -Wall -Wextra \
	  -o $$tmp/steam_osx $(SPAWN_LIVE)/driver.c || exit 1; \
	cp $$tmp/steam_osx $$tmp/inert; cp $$tmp/child $$tmp/steam_osx_child; \
	cp $$tmp/child $$tmp/sub/steam_osx; \
	cp $$tmp/steam_osx "$$tmp/Steam Helper"; cp $$tmp/child "$$tmp/sub/Steam Helper"; \
	fail=0; \
	for spec in "inert:child:1" "steam_osx:child:0" \
	            "steam_osx:steam_osx_child:0" "steam_osx:sub/steam_osx:1" \
	            "steam_osx:sub/Steam Helper:1" "Steam Helper:child:0" \
	            "Steam Helper:sub/Steam Helper:1" "Steam Helper:child:1:--type=renderer"; do \
		drv=$${spec%%:*}; rest=$${spec#*:}; kid=$${rest%%:*}; rest=$${rest#*:}; \
		want=$${rest%%:*}; arg=$${rest#*:}; [ "$$arg" = "$$rest" ] && arg=""; \
		got=$$(DYLD_INSERT_LIBRARIES=$$PWD/$(TARGET) "$$tmp/$$drv" "$$tmp/$$kid" $$arg 2>/dev/null \
		       | grep -c "/$(DYLIB_NAME)$$") || true; \
		if [ "$$got" != "$$want" ]; then \
			echo "$$drv $$arg -> $$kid: insert present $$got, wanted $$want"; fail=1; fi; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "==> spawn live: the hook lands, steam_osx and Steam Helper keep the insert, other children do not"

APP_TESTS := app/Tests

app-tests:
	@if [ ! -d $(APP_TESTS) ]; then $(call SKIP,app-tests,$(APP_TESTS)); exit 0; fi; \
	touch app/Package.swift; cd app && swift test --no-parallel

PANEL_TESTS := dylib/tests/panel-behavior

panel-behavior:
	@if [ ! -d $(PANEL_TESTS) ]; then $(call SKIP,panel-behavior,$(PANEL_TESTS)); exit 0; fi; \
	if ! command -v node >/dev/null 2>&1; then \
		echo "==> panel-behavior: node not found, skipped"; exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -O1 -o $(OUT_DIR)/panel-emit \
	  $(PANEL_TESTS)/emit.c && \
	node $(PANEL_TESTS)/behavior.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/switching.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/launch-options.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/shell.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/migration.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/downloads.js $(OUT_DIR)/panel-emit && \
	$(TEST_CC) -o $(LIBEXPORT_CHECK) dylib/tests/libexport-check.c dylib/util/file.c vendor/cJSON.c && \
	node $(PANEL_TESTS)/library-export.js $(OUT_DIR)/panel-emit $(LIBEXPORT_CHECK) && \
	node $(PANEL_TESTS)/localization.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/fex.js $(OUT_DIR)/panel-emit && \
	echo "==> panel behavior: renders as expected, no stale arguments"

CX_ROOT ?= /Applications/CrossOver Preview.app

ntdll-resolve:
	@if [ ! -f ntdll-patch/resolve.py ]; then \
		$(call SKIP,ntdll-resolve,ntdll-patch/resolve.py); exit 0; fi; \
	if ! python3 -c 'import capstone' >/dev/null 2>&1; then \
		echo "==> ntdll-resolve: capstone not found, skipped (pip3 install capstone)"; exit 0; fi; \
	if [ ! -d "$(CX_ROOT)" ]; then \
		echo "==> ntdll-resolve: $(CX_ROOT) not present, skipped (set CX_ROOT)"; exit 0; fi; \
	python3 ntdll-patch/resolve.py "$(CX_ROOT)"

$(ARM64_DYLIB): $(OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) -o $@ $^ $(DOBBY_LIBS) $(FRAMEWORKS) -lc++

$(X86_STUB): dylib/stub_x86_64.c
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 -mmacosx-version-min=$(MIN_VER) $(AVAIL) \
		-dynamiclib -install_name @rpath/$(DYLIB_NAME) \
		-o $@ $<

$(TARGET): $(ARM64_DYLIB) $(X86_STUB)
	lipo -create $^ -output $@
	codesign -fs - $@
	@echo "==> Built: $@"

$(OUT_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(RUN_SCRIPT_H): dylib/feats/compat_run.sh dylib/embed_script.py
	@mkdir -p $(GENERATED_DIR)
	python3 dylib/embed_script.py $< $@ RUN_SCRIPT

dylib/feats/steaminstall.h: dylib/feats/steaminstall.js dylib/tests/embed-steaminstall.py
	python3 dylib/tests/embed-steaminstall.py

$(OUT_DIR)/dylib/feats/webpatch.o: dylib/feats/steaminstall.h
$(OUT_DIR)/dylib/feats/libexport.o: dylib/feats/steaminstall.inc

$(OUT_DIR)/dylib/feats/compat.o: $(RUN_SCRIPT_H)

SUPPORT_DIR        := $(HOME)/Library/Application Support/$(call identity,CARTOUCHE_DIR_NAME)
OVERLAY_SHIM_SRC   := overlay-shim/overlay_shim.m
OVERLAY_SHIM_ARM   := $(OUT_DIR)/overlay-shim.arm64.dylib
OVERLAY_SHIM_X86   := $(OUT_DIR)/overlay-shim.x86_64.dylib
OVERLAY_SHIM       := $(OUT_DIR)/overlay-shim.dylib
OVERLAY_SHIM_FLAGS := -mmacosx-version-min=$(MIN_VER) $(AVAIL) -dynamiclib -O2 -Wall -Wextra \
                      -install_name @rpath/overlay-shim.dylib \
                      -framework Metal -framework QuartzCore \
                      -framework CoreGraphics -framework CoreFoundation -framework Foundation
OVERLAY_SHIM_TESTS := overlay-shim/tests
OVERLAY_SHIM_TEST_FLAGS := -mmacosx-version-min=$(MIN_VER) -O2 -Wall -Wextra \
                      -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics

overlay-shim: $(OVERLAY_SHIM)

$(OVERLAY_SHIM): $(OVERLAY_SHIM_SRC)
	@mkdir -p $(OUT_DIR)
	$(CC) -arch arm64 $(OVERLAY_SHIM_FLAGS) -o $(OVERLAY_SHIM_ARM) $<
	$(CC) -arch x86_64 $(OVERLAY_SHIM_FLAGS) -o $(OVERLAY_SHIM_X86) $<
	lipo -create $(OVERLAY_SHIM_ARM) $(OVERLAY_SHIM_X86) -output $@
	codesign -fs - $@
	@lipo -info $@

define install_atomically
	@mkdir -p "$$(dirname "$(2)")"
	cp -f "$(1)" "$(2).new"
	mv -f "$(2).new" "$(2)"
endef

overlay-shim-install: $(OVERLAY_SHIM)
	$(call install_atomically,$(OVERLAY_SHIM),$(SUPPORT_DIR)/overlay-shim.dylib)
	@echo "==> Installed: $(SUPPORT_DIR)/overlay-shim.dylib"

overlay-shim-tests: $(OVERLAY_SHIM)
	@if [ ! -d $(OVERLAY_SHIM_TESTS) ]; then \
		$(call SKIP,overlay-shim-tests,$(OVERLAY_SHIM_TESTS)); exit 0; fi; \
	mkdir -p $(OUT_DIR); \
	fail=0; ran=0; skipped=0; \
	for t in device bridge delivery ownership; do \
		for a in arm64 x86_64; do \
			$(CC) -arch $$a $(OVERLAY_SHIM_TEST_FLAGS) -o $(OUT_DIR)/$$t.$$a \
				$(OVERLAY_SHIM_TESTS)/$$t.m || exit 1; \
			out=$$(CARTOUCHE_OVERLAY_SHIM=$(OVERLAY_SHIM) $(OUT_DIR)/$$t.$$a 2>&1); rc=$$?; \
			case "$$rc" in \
			0) ran=$$((ran+1)); echo "$$out" | sed "s/^/  $$t.$$a /" ;; \
			3|126) skipped=$$((skipped+1)); \
			   echo "  $$t.$$a skipped: $$(echo "$$out" | tail -1)" ;; \
			*) echo "  $$t.$$a exited $$rc:"; echo "$$out" | sed "s/^/    /"; fail=1 ;; \
			esac; \
		done; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	if [ $$ran -eq 0 ]; then \
		echo "overlay shim tests: all $$skipped skipped, so nothing was checked"; exit 1; fi; \
	echo "==> overlay shim tests: $$ran passed, $$skipped skipped"

overlay-shim-bench:
	@if [ ! -f $(OVERLAY_SHIM_TESTS)/passbench.m ]; then \
		$(call SKIP,overlay-shim-bench,$(OVERLAY_SHIM_TESTS)/passbench.m); exit 0; fi; \
	mkdir -p $(OUT_DIR); \
	for a in arm64 x86_64; do \
		$(CC) -arch $$a $(OVERLAY_SHIM_TEST_FLAGS) -o $(OUT_DIR)/passbench.$$a \
			$(OVERLAY_SHIM_TESTS)/passbench.m || exit 1; \
		printf '  %-8s ' "$$a"; $(OUT_DIR)/passbench.$$a || exit 1; \
	done

# Frame counter injected into Windows games (P8), both slices like the overlay shim
FPS_COUNTER_SRC   := fps-counter/fps_counter.m
FPS_COUNTER       := $(OUT_DIR)/$(call identity,CARTOUCHE_FPS_COUNTER_NAME)
FPS_COUNTER_FLAGS := -mmacosx-version-min=$(MIN_VER) $(AVAIL) -dynamiclib -O2 -Wall -Wextra \
                     -install_name @rpath/$(notdir $(FPS_COUNTER)) \
                     -framework QuartzCore -framework Foundation
FPS_COUNTER_TESTS := fps-counter/tests
FPS_PRESENT_FLAGS := -mmacosx-version-min=$(MIN_VER) -O2 -Wall -Wextra \
                     -framework Metal -framework QuartzCore -framework Foundation

.PHONY: fps-counter fps-counter-tests fps-counter-bench fpscheck

fps-counter: $(FPS_COUNTER)

$(FPS_COUNTER): $(FPS_COUNTER_SRC)
	@mkdir -p $(OUT_DIR)
	$(CC) -arch arm64 $(FPS_COUNTER_FLAGS) -o $(OUT_DIR)/fps-counter.arm64.dylib $<
	$(CC) -arch x86_64 $(FPS_COUNTER_FLAGS) -o $(OUT_DIR)/fps-counter.x86_64.dylib $<
	lipo -create $(OUT_DIR)/fps-counter.arm64.dylib $(OUT_DIR)/fps-counter.x86_64.dylib -output $@
	codesign -fs - $@
	@lipo -info $@

$(OUT_DIR)/fps-present.%: $(FPS_COUNTER_TESTS)/present.m
	@mkdir -p $(OUT_DIR)
	$(CC) -arch $* $(FPS_PRESENT_FLAGS) -o $@ $<

fps-counter-tests: $(FPS_COUNTER) $(OUT_DIR)/fps-present.arm64 $(OUT_DIR)/fps-present.x86_64
	@sh $(FPS_COUNTER_TESTS)/counter.sh $(FPS_COUNTER) $(OUT_DIR)

fps-counter-bench: $(FPS_COUNTER) $(OUT_DIR)/fps-present.arm64 $(OUT_DIR)/fps-present.x86_64
	@sh $(FPS_COUNTER_TESTS)/bench.sh $(FPS_COUNTER) $(OUT_DIR)

# Frame rate of a game window from outside its process (ScreenCaptureKit, IOKit), for games
# with an anti-cheat; prototype
.PHONY: extfps extfps-tests
extfps: $(OUT_DIR)/extfps

$(OUT_DIR)/extfps: fps-counter/extfps.swift
	@mkdir -p $(OUT_DIR)
	swiftc -O -target arm64-apple-macos14 -o $@ $<

extfps-tests: $(OUT_DIR)/extfps $(OUT_DIR)/framegen/game
	@sh $(FPS_COUNTER_TESTS)/extfps.sh

# Run by compatcheck as well, which the CI runs
fpscheck: $(FPS_COUNTER) $(OUT_DIR)/fps-present.arm64
	@if [ ! -f dylib/tests/fpscheck.sh ]; then $(call SKIP,fpscheck,dylib/tests/fpscheck.sh); exit 0; fi; \
	sh dylib/tests/fpscheck.sh dylib/feats/compat_run.sh $(FPS_COUNTER) $(OUT_DIR)

# Experimental frame generation (spike). x86_64 only: Wine games run under Rosetta.
# The kernels are compiled when a game starts, from source embedded in the library.
FRAMEGEN          := $(OUT_DIR)/$(call identity,CARTOUCHE_FRAMEGEN_NAME)
FRAMEGEN_SRC      := framegen/framegen.m framegen/fg_pipeline.m framegen/fg_ane.m framegen/fg_bridge.m \
                     framegen/fg_upscale.m framegen/fg_temporal.m framegen/fg_metal.m framegen/fg_proxy.m \
                     framegen/fg_metrics.m framegen/fg_overlay.m
FRAMEGEN_KERNELS  := $(OUT_DIR)/framegen/framegen_kernels.h
FRAMEGEN_UPSCALE_KERNELS := $(OUT_DIR)/framegen/framegen_upscale.h
FRAMEGEN_OVERLAY_KERNELS := $(OUT_DIR)/framegen/framegen_overlay.h
FRAMEGEN_OBJC     := -mmacosx-version-min=$(MIN_VER) $(AVAIL) -fobjc-arc -O2 -Wall -Wextra \
                     -I$(dir $(FRAMEGEN_KERNELS))
FRAMEGEN_FLAGS    := $(FRAMEGEN_OBJC) -dynamiclib -install_name @rpath/$(notdir $(FRAMEGEN)) \
                     -framework Metal -framework MetalFX -framework QuartzCore -framework AppKit -framework Foundation \
                     -framework CoreVideo -framework IOSurface -framework CoreText -framework IOKit
FRAMEGEN_TESTS    := framegen/tests

.PHONY: framegen framegen-tests framegencheck framegen-test framegen-tune framegen-wine framegen-ane framegen-mfx \
        framegen-latency framegen-watts framegen-bridge
.PHONY: framegen-upscale framegen-upbench framegen-fxboth
.PHONY: framegen-temporal framegen-temporal4
.PHONY: framegen-dxmt
.PHONY: framegen-proxy framegen-ffx
.PHONY: framegen-overlay

# The Neural Engine helper: arm64, since Core ML uses the ANE only in native processes. Its
# network, framegen-flow.mlmodelc, is converted from Practical-RIFE (MIT) by
# framegen/ane/convert_rife.py, with coremltools and torch in FRAMEGEN_PYTHON.
FRAMEGEN_ANE      := $(OUT_DIR)/framegen-ane
FRAMEGEN_PYTHON  ?= python3
RIFE_DIR         ?= $(HOME)/Downloads/fg-tests/rife-425lite/train_log
RIFE_REPO        ?= $(HOME)/Downloads/fg-tests/rife-src/repo

framegen-ane: $(FRAMEGEN_ANE)

$(FRAMEGEN_ANE): framegen/ane/helper.m framegen/ane/fg_ane_protocol.h
	@mkdir -p $(OUT_DIR)
	$(CC) -arch arm64 -mmacosx-version-min=$(MIN_VER) -fobjc-arc -O2 -Wall -Wextra -framework Foundation \
		-framework CoreML -framework CoreVideo -framework IOSurface -o $@ $<
	codesign -fs - $@

$(OUT_DIR)/framegen-flow.mlmodelc: framegen/ane/convert_rife.py
	@mkdir -p $(OUT_DIR)/framegen
	$(FRAMEGEN_PYTHON) -I $< $(RIFE_DIR) $(RIFE_REPO) 512 256 $(OUT_DIR)/framegen/flow.mlpackage lean
	xcrun coremlcompiler compile $(OUT_DIR)/framegen/flow.mlpackage $(OUT_DIR)/framegen
	rm -rf $@ && mv $(OUT_DIR)/framegen/flow.mlmodelc $@

# Cartouche FG 1, our own network (CARTOUCHE_FRAMEGEN_ANE=fg1), trained by framegen/ane/a6/train.py
FG1_CHECKPOINT   ?= $(HOME)/Downloads/fg-tests/a6/run1/best.pt

$(OUT_DIR)/framegen-flow-fg1.mlmodelc: framegen/ane/a6/convert.py framegen/ane/a6/model.py
	@test -f $(FG1_CHECKPOINT) || { echo "no FG 1 checkpoint at $(FG1_CHECKPOINT) (FG1_CHECKPOINT=...)"; exit 1; }
	@mkdir -p $(OUT_DIR)/framegen
	$(FRAMEGEN_PYTHON) $< $(FG1_CHECKPOINT) $(OUT_DIR)/framegen/flow-fg1.mlpackage
	xcrun coremlcompiler compile $(OUT_DIR)/framegen/flow-fg1.mlpackage $(OUT_DIR)/framegen
	rm -rf $@ && mv $(OUT_DIR)/framegen/flow-fg1.mlmodelc $@

framegen: $(FRAMEGEN)

$(FRAMEGEN_KERNELS): framegen/kernels.metal
	@mkdir -p $(dir $@)
	cd framegen && xxd -i kernels.metal > $(abspath $@)

$(FRAMEGEN_UPSCALE_KERNELS): framegen/upscale.metal
	@mkdir -p $(dir $@)
	cd framegen && xxd -i upscale.metal > $(abspath $@)

$(FRAMEGEN_OVERLAY_KERNELS): framegen/overlay.metal
	@mkdir -p $(dir $@)
	cd framegen && xxd -i overlay.metal > $(abspath $@)

$(FRAMEGEN): $(FRAMEGEN_SRC) framegen/fg_pipeline.h framegen/fg_ane.h framegen/ane/fg_ane_protocol.h \
		framegen/bridge/fg_bridge.h framegen/fg_upscale.h framegen/fg_temporal.h framegen/fg_formats.h \
		framegen/proxy/fg_proxy.h framegen/fg_metrics.h framegen/fg_metrics_shm.h framegen/fg_control_shm.h framegen/fg_overlay.h \
		$(FRAMEGEN_KERNELS) $(FRAMEGEN_UPSCALE_KERNELS) $(FRAMEGEN_OVERLAY_KERNELS)
	@mkdir -p $(OUT_DIR)
	$(CC) -arch x86_64 $(FRAMEGEN_FLAGS) -o $@ $(FRAMEGEN_SRC)
	codesign -fs - $@
	@lipo -info $@

$(OUT_DIR)/framegen/pipeline: $(FRAMEGEN_TESTS)/pipeline.m framegen/fg_pipeline.m framegen/fg_pipeline.h $(FRAMEGEN_KERNELS)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework Metal -framework MetalFX -framework Foundation \
		-o $@ $(FRAMEGEN_TESTS)/pipeline.m framegen/fg_pipeline.m

# Settings search on the test window's scene, scored against the true half-way frame
$(OUT_DIR)/framegen/tune: $(FRAMEGEN_TESTS)/tune.m $(FRAMEGEN_TESTS)/scene.h framegen/fg_pipeline.m framegen/fg_pipeline.h framegen/fg_ane.m \
		$(FRAMEGEN_KERNELS)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework Metal -framework MetalFX -framework MetalKit \
		-framework CoreVideo -framework IOSurface -o $@ $(FRAMEGEN_TESTS)/tune.m framegen/fg_pipeline.m framegen/fg_ane.m

framegen-tune: $(OUT_DIR)/framegen/tune
	@$(OUT_DIR)/framegen/tune mockup/brand/cartouche-icon-default.svg $(FRAMEGEN_TUNE_SPEEDS)

# MetalFX's interpolator alone on a square moving a known distance: implicit instant, scaled
# vectors, descriptor options
$(OUT_DIR)/framegen/mfx: $(FRAMEGEN_TESTS)/mfx.m
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework Metal -framework MetalFX -framework Foundation -o $@ $<

framegen-mfx: $(OUT_DIR)/framegen/mfx
	@$(OUT_DIR)/framegen/mfx 48 16 96

# The GPU cost of our chain around a temporal scaler as DXMT makes one for DLSS
$(OUT_DIR)/framegen/temporal: $(FRAMEGEN_TESTS)/temporal.m framegen/fg_temporal.m framegen/fg_temporal.h \
		framegen/fg_upscale.m framegen/fg_upscale.h framegen/fg_formats.h $(FRAMEGEN_UPSCALE_KERNELS)
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework Metal -framework MetalFX -framework QuartzCore \
		-framework Foundation -o $@ $(FRAMEGEN_TESTS)/temporal.m framegen/fg_temporal.m framegen/fg_upscale.m

framegen-temporal: $(OUT_DIR)/framegen/temporal
	@$(OUT_DIR)/framegen/temporal 300

# The same chain on an MTL4FX temporal scaler in MTL4 command buffers, as D3DMetal may drive one:
# image against the scene at full size, cost, and the kill switch's output byte for byte
$(OUT_DIR)/framegen/temporal4: $(FRAMEGEN_TESTS)/temporal4.m $(FRAMEGEN_TESTS)/scene.h framegen/fg_temporal.m \
		framegen/fg_temporal.h framegen/fg_upscale.m framegen/fg_upscale.h framegen/fg_formats.h $(FRAMEGEN_UPSCALE_KERNELS)
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework Metal -framework MetalFX -framework MetalKit \
		-framework QuartzCore -framework Foundation -o $@ $(FRAMEGEN_TESTS)/temporal4.m framegen/fg_temporal.m \
		framegen/fg_upscale.m

framegen-temporal4: $(OUT_DIR)/framegen/temporal4 $(OUT_DIR)/framegen/score
	@sh $(FRAMEGEN_TESTS)/temporal4.sh $(OUT_DIR)/framegen/temporal4 $(OUT_DIR)/framegen/score \
		mockup/brand/cartouche-icon-default.svg

$(OUT_DIR)/framegen/game: $(FRAMEGEN_TESTS)/game.m $(FRAMEGEN_TESTS)/screen.h
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework Metal -framework MetalFX -framework QuartzCore -o $@ $<

# Stands in for DXMT's winemetal.so, which the library looks for to name the backend
$(OUT_DIR)/framegen/winemetal.so: dylib/stub_x86_64.c
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 -dynamiclib -o $@ $<

framegen-tests: $(FRAMEGEN) $(OUT_DIR)/framegen/pipeline $(OUT_DIR)/framegen/game $(OUT_DIR)/framegen/winemetal.so
	@$(OUT_DIR)/framegen/pipeline 1920 1080
	@sh $(FRAMEGEN_TESTS)/framegen.sh $(FRAMEGEN) $(OUT_DIR)/framegen

# The in-game overlay: offscreen pixels, cost and generation inputs, then in the stand-in game with
# generation on, and the shared metrics block read by a native arm64 process
$(OUT_DIR)/framegen/overlay: $(FRAMEGEN_TESTS)/overlay.m framegen/fg_overlay.m framegen/fg_overlay.h framegen/fg_metrics.m \
		framegen/fg_metrics.h framegen/fg_metrics_shm.h framegen/fg_control_shm.h framegen/fg_pipeline.m framegen/fg_pipeline.h \
		$(FRAMEGEN_KERNELS) $(FRAMEGEN_OVERLAY_KERNELS)
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework Metal -framework MetalFX -framework QuartzCore -framework CoreText \
		-framework IOKit -o $@ $(FRAMEGEN_TESTS)/overlay.m framegen/fg_overlay.m framegen/fg_metrics.m framegen/fg_pipeline.m

$(OUT_DIR)/framegen/metrics-read: $(FRAMEGEN_TESTS)/metrics_read.c framegen/fg_metrics_shm.h
	@mkdir -p $(dir $@)
	$(CC) -arch arm64 -O2 -Wall -Wextra -o $@ $<

framegen-overlay: $(FRAMEGEN) $(OUT_DIR)/framegen/overlay $(OUT_DIR)/framegen/metrics-read $(OUT_DIR)/framegen/game \
		$(OUT_DIR)/framegen/winemetal.so
	@$(OUT_DIR)/framegen/overlay $(OUT_DIR)/framegen
	@sh $(FRAMEGEN_TESTS)/overlay.sh $(abspath $(FRAMEGEN)) $(abspath $(OUT_DIR)/framegen)

$(OUT_DIR)/framegen/mouse: $(FRAMEGEN_TESTS)/mouse.m
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework ApplicationServices -o $@ $<

# Upscaling (CARTOUCHE_FRAMEGEN_UPSCALE): clicks against the marks the game draws, layer sizes,
# frame generation on top, failures; natively, then in Wine on DXMT and D3DMetal
framegen-upscale: $(FRAMEGEN) $(OUT_DIR)/framegen/game $(OUT_DIR)/framegen/winemetal.so $(OUT_DIR)/framegen/mouse \
		$(OUT_DIR)/framegen/scene.exe
	@sh $(FRAMEGEN_TESTS)/upscale.sh $(abspath $(FRAMEGEN)) $(abspath $(OUT_DIR)/framegen)

# The spatial chain against bilinear and MetalFX alone, scored against a supersampled render
$(OUT_DIR)/framegen/upbench: $(FRAMEGEN_TESTS)/upbench.m $(FRAMEGEN_TESTS)/scene.h framegen/fg_upscale.m framegen/fg_upscale.h \
		framegen/fg_formats.h $(FRAMEGEN_UPSCALE_KERNELS)
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework Metal -framework MetalFX -framework MetalKit \
		-framework QuartzCore -o $@ $(FRAMEGEN_TESTS)/upbench.m framegen/fg_upscale.m

framegen-upbench: $(OUT_DIR)/framegen/upbench
	@$(OUT_DIR)/framegen/upbench mockup/brand/cartouche-icon-default.svg

# A game's temporal scaler and an interpolator: apart, and with the interpolator made on the scaler
$(OUT_DIR)/framegen/fxboth: $(FRAMEGEN_TESTS)/fxboth.m $(FRAMEGEN_TESTS)/scene.h
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework Metal -framework MetalFX -framework MetalKit -o $@ $<

framegen-fxboth: $(OUT_DIR)/framegen/fxboth
	@$(OUT_DIR)/framegen/fxboth mockup/brand/cartouche-icon-default.svg

# Relative click-to-photon latency on the stand-in game, off, capped, hooks only and 2x:
# FRAMEGEN_CLICKS clicks per configuration, at each of FRAMEGEN_BASES
FRAMEGEN_CLICKS ?= 100
FRAMEGEN_BASES  ?= 40 60

framegen-latency: $(FRAMEGEN) $(OUT_DIR)/framegen/game $(OUT_DIR)/framegen/winemetal.so
	@sh $(FRAMEGEN_TESTS)/latency.sh $(abspath $(FRAMEGEN)) $(abspath $(OUT_DIR)/framegen) $(FRAMEGEN_CLICKS) $(FRAMEGEN_BASES)

# Energy per shown frame from powermetrics (root: run "sudo -v" first), off, native and 2x;
# WATTS_THROTTLE=1 adds 20 minutes with generation on
FRAMEGEN_WATTS_SECONDS ?= 60

framegen-watts: $(FRAMEGEN) $(OUT_DIR)/framegen/game $(OUT_DIR)/framegen/winemetal.so
	@sh $(FRAMEGEN_TESTS)/watts.sh $(abspath $(FRAMEGEN)) $(abspath $(OUT_DIR)/framegen) $(FRAMEGEN_WATTS_SECONDS) $(FRAMEGEN_BASES)

# A Direct3D 11 stand-in game, cross-built with mingw-w64, run in Cartouche's own Wine on
# DXMT and D3DMetal. Needs Cartouche's runners installed on this Mac.
$(OUT_DIR)/framegen/scene.exe: $(FRAMEGEN_TESTS)/d3d11/scene.c framegen/bridge/fg_bridge.h
	@mkdir -p $(dir $@)
	x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o $@ $< -ld3d11 -ld3dcompiler -ldxgi -luuid

framegen-wine: $(FRAMEGEN) $(OUT_DIR)/framegen/scene.exe $(OUT_DIR)/framegen/game $(OUT_DIR)/framegen/score $(OUT_DIR)/framegen/temporal
	@sh $(FRAMEGEN_TESTS)/d3d11/check.sh $(abspath $(OUT_DIR)/framegen/scene.exe) $(abspath $(FRAMEGEN))

# The Wine bridge: a PE DLL and its unix half, built outside Wine's tree as DXMT builds
# winemetal, and found through WINEDLLPATH. Marked builtin as winebuild --builtin does, with
# Wine's signature right after the DOS header. CrossOver's ntdll looks for the unix half next
# to the DLL. The unmarked copy stands for a game's own DLL.
FRAMEGEN_BRIDGE   := $(OUT_DIR)/framegen/bridge
FRAMEGEN_BRIDGE_PARTS := $(FRAMEGEN_BRIDGE)/builtin/cartouche_bridge.dll $(FRAMEGEN_BRIDGE)/builtin/cartouche_bridge.so \
                     $(FRAMEGEN_BRIDGE)/native/cartouche_bridge.dll

$(FRAMEGEN_BRIDGE)/builtin/cartouche_bridge.dll: framegen/bridge/cartouche_bridge.c framegen/bridge/fg_bridge.h
	@mkdir -p $(dir $@)
	x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -shared -o $@ $<
	@test "$$(od -An -t u4 -j 60 -N 4 $@ | tr -d ' ')" -ge 81 || { echo "$@: no room for Wine's signature"; rm -f $@; exit 1; }
	printf 'Wine builtin DLL\000' | dd of=$@ bs=1 seek=64 conv=notrunc 2> /dev/null

$(FRAMEGEN_BRIDGE)/native/cartouche_bridge.dll: framegen/bridge/cartouche_bridge.c framegen/bridge/fg_bridge.h
	@mkdir -p $(dir $@)
	x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -shared -DCARTOUCHE_BRIDGE_KIND='"native"' -o $@ $<

$(FRAMEGEN_BRIDGE)/builtin/cartouche_bridge.so: framegen/bridge/cartouche_bridge_unix.c framegen/bridge/fg_bridge.h
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 -mmacosx-version-min=$(MIN_VER) -O2 -Wall -Wextra -dynamiclib -o $@ $<
	codesign -fs - $@

# 10 000 frames through the bridge in the D3D11 scene on DXMT, then which DLL Wine loads when
# the game's folder holds one of the same name
framegen-bridge: $(FRAMEGEN) $(OUT_DIR)/framegen/scene.exe $(FRAMEGEN_BRIDGE_PARTS)
	@sh $(FRAMEGEN_TESTS)/d3d11/bridge.sh $(abspath $(OUT_DIR)/framegen/scene.exe) $(abspath $(FRAMEGEN)) \
		$(abspath $(FRAMEGEN_BRIDGE))

# The zero-copy D3D11 path: DXMT with framegen/dxmt/0001-GetMetalTexture.patch, built in a
# scratch dir (the user's DXMT is untouched), then the scene's textures checked through it and
# our MetalFX chain in place of its upscale
FRAMEGEN_DXMT    ?= $(HOME)/Library/Caches/cartouche-fg-dxmt

$(OUT_DIR)/framegen/score: $(FRAMEGEN_TESTS)/d3d11/score.c
	@mkdir -p $(dir $@)
	$(CC) -O2 -Wall -Wextra -o $@ $<

framegen-dxmt: $(FRAMEGEN) $(OUT_DIR)/framegen/scene.exe $(FRAMEGEN_BRIDGE_PARTS) $(OUT_DIR)/framegen/score
	@sh framegen/dxmt/build.sh $(FRAMEGEN_DXMT) > /dev/null
	@sh $(FRAMEGEN_TESTS)/d3d11/dxmt.sh $(abspath $(OUT_DIR)/framegen/scene.exe) $(abspath $(FRAMEGEN)) \
		$(abspath $(FRAMEGEN_BRIDGE))/builtin $(abspath $(OUT_DIR)/framegen/score) $(FRAMEGEN_DXMT)/root

# The FFX proxy: AMD's FFX DLL names as Wine builtins with their unix halves, in one folder for
# WINEDLLPATH. Written from AMD's MIT headers (framegen/proxy/ffx). FRAMEGEN_FFX_SAMPLE is AMD's
# prebuilt FSR sample (FidelityFX SDK v2.3.0, MIT), with its media unpacked beside it.
FRAMEGEN_PROXY    := $(OUT_DIR)/framegen/proxy
FRAMEGEN_PROXY_NAMES := amd_fidelityfx_loader_dx12 amd_fidelityfx_dx12
FRAMEGEN_PROXY_PARTS := $(foreach n,$(FRAMEGEN_PROXY_NAMES),$(FRAMEGEN_PROXY)/$(n).dll $(FRAMEGEN_PROXY)/$(n).so)
FRAMEGEN_FFX_SAMPLE ?= $(HOME)/Downloads/fg-tests/ffx/Samples/Upscalers/FidelityFX_FSR/dx12/x64/Release

$(FRAMEGEN_PROXY)/%.dll: framegen/proxy/ffx_proxy.c framegen/proxy/fg_proxy.h $(shell find framegen/proxy/ffx -name '*.h')
	@mkdir -p $(dir $@)
	x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Wno-unknown-pragmas -shared -o $@ $<
	@test "$$(od -An -t u4 -j 60 -N 4 $@ | tr -d ' ')" -ge 81 || { echo "$@: no room for Wine's signature"; rm -f $@; exit 1; }
	printf 'Wine builtin DLL\000' | dd of=$@ bs=1 seek=64 conv=notrunc 2> /dev/null

$(FRAMEGEN_PROXY)/%.so: framegen/proxy/ffx_proxy_unix.c framegen/proxy/fg_proxy.h
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 -mmacosx-version-min=$(MIN_VER) -O2 -Wall -Wextra -dynamiclib -o $@ $<
	codesign -fs - $@

$(OUT_DIR)/framegen/quiet.dylib: $(FRAMEGEN_TESTS)/ffx/quiet.m
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -dynamiclib -framework AppKit -o $@ $<
	codesign -fs - $@

framegen-proxy: $(FRAMEGEN_PROXY_PARTS)

# Frame generation scored on the sample's own frames, from the proxy's copies
$(OUT_DIR)/framegen/ffx-score: $(FRAMEGEN_TESTS)/ffx/score.m framegen/fg_pipeline.m framegen/fg_pipeline.h $(FRAMEGEN_KERNELS)
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework Metal -framework MetalFX -framework Foundation \
		-o $@ $(FRAMEGEN_TESTS)/ffx/score.m framegen/fg_pipeline.m

# AMD's FSR sample on D3DMetal, without then with the proxy: same run, the sample's folder
# untouched; then the proxy's copies of depth and motion reaching the library
framegen-ffx: $(FRAMEGEN) $(FRAMEGEN_PROXY_PARTS) $(OUT_DIR)/framegen/quiet.dylib $(OUT_DIR)/framegen/ffx-score
	@sh $(FRAMEGEN_TESTS)/ffx/sample.sh $(FRAMEGEN_FFX_SAMPLE) $(abspath $(FRAMEGEN)) $(abspath $(FRAMEGEN_PROXY)) \
		$(abspath $(OUT_DIR)/framegen/quiet.dylib)

# Cartouche Frame Gen Test: top lane off, bottom lane on, and a settings window that tunes
# the library live and shows both lanes' numbers
$(OUT_DIR)/framegen/framegen_test: $(FRAMEGEN_TESTS)/framegen_test.m $(FRAMEGEN_TESTS)/scene.h $(FRAMEGEN_TESTS)/screen.h
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 $(FRAMEGEN_OBJC) -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
		-o $@ $<

framegen-test: $(FRAMEGEN) $(OUT_DIR)/framegen/framegen_test $(OUT_DIR)/framegen/winemetal.so
	DYLD_INSERT_LIBRARIES=$(abspath $(OUT_DIR)/framegen/winemetal.so):$(abspath $(FRAMEGEN)) CARTOUCHE_FRAMEGEN=1 \
		$(OUT_DIR)/framegen/framegen_test mockup/brand/cartouche-icon-default.svg

# The run script's side, without a window: run by compatcheck as well
framegencheck: $(FRAMEGEN) $(OUT_DIR)/framegen/game
	@sh dylib/tests/framegencheck.sh dylib/feats/compat_run.sh $(FRAMEGEN) $(OUT_DIR)/framegen

ICONMAKER := $(OUT_DIR)/iconmaker

iconmaker: $(ICONMAKER)

$(ICONMAKER): helpers/iconmaker.swift helpers/iconmaker.h dylib/util/peicon.c dylib/util/peicon.h helpers/shortcuts.h helpers/shortcuts.c
	@mkdir -p $(OUT_DIR)
	$(CC) -c -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) $(AVAIL) -std=c17 -O2 \
		-Wall -Wextra -o $(OUT_DIR)/peicon-host.o dylib/util/peicon.c
	$(CC) -c -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) $(AVAIL) -std=c17 -O2 \
		-Wall -Wextra -o $(OUT_DIR)/shortcuts-host.o helpers/shortcuts.c
	swiftc -O -target $(ARCH)-apple-macos$(MIN_VER) \
		-framework AppKit -import-objc-header helpers/iconmaker.h \
		-o $@ helpers/iconmaker.swift $(OUT_DIR)/peicon-host.o $(OUT_DIR)/shortcuts-host.o
	@echo "==> Built $@"

APPINFO := $(OUT_DIR)/appinfo

appinfo: $(APPINFO)

$(APPINFO): helpers/appinfo/main.swift app/Sources/NotProtonApp/Setup/AppInfoVDF.swift
	@mkdir -p $(OUT_DIR)
	swiftc -O -target $(ARCH)-apple-macos$(MIN_VER) -o $@ $^
	@echo "==> Built $@"

helpers-install: $(ICONMAKER) $(APPINFO)
	$(call install_atomically,$(ICONMAKER),$(SUPPORT_DIR)/iconmaker)
	$(call install_atomically,$(APPINFO),$(SUPPORT_DIR)/appinfo)
	@echo "==> Installed: $(SUPPORT_DIR)/{iconmaker,appinfo}"

# The Win32 driver that unpacks FreeArc .bin parts through the installer's own
# unarc.dll, without running the installer. It is a 32-bit PE: unarc.dll is x86.
MINGW32     ?= i686-w64-mingw32-gcc
UNARC_DRIVER := $(OUT_DIR)/unarc-driver.exe

unarc-driver: $(UNARC_DRIVER)

$(UNARC_DRIVER): helpers/unarc-driver.c helpers/unarc-password.h
	@mkdir -p $(OUT_DIR)
	$(MINGW32) -O2 -Wall -static-libgcc -o $@ $<
	@echo "==> Built $@"

.PHONY: homecheck
homecheck:
	@mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(OUT_DIR)/homecheck dylib/tests/homecheck.c dylib/util/file.c && \
	$(OUT_DIR)/homecheck

.PHONY: unarccheck
unarccheck:
	@mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(OUT_DIR)/unarc-password-check dylib/tests/unarc-password-check.c && \
	$(OUT_DIR)/unarc-password-check

# Restores a fullscreen game minimized by the in-game menu, run inside the game's own Wine
MINGW64     ?= x86_64-w64-mingw32-gcc
GAME_RESTORE := $(OUT_DIR)/game-restore.exe

game-restore: $(GAME_RESTORE)

$(GAME_RESTORE): helpers/game-restore.c
	@mkdir -p $(OUT_DIR)
	$(MINGW64) -O2 -Wall -Wextra -static-libgcc -o $@ $<
	@echo "==> Built $@"

dobby:
	@mkdir -p $(DOBBY_DIR)
	cd $(DOBBY_DIR) && cmake $(CURDIR)/vendor/dobby \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=$(MIN_VER) \
		-DDOBBY_DEBUG=OFF \
		-DDOBBY_GENERATE_SHARED=OFF \
		-G "Unix Makefiles"
	$(MAKE) -C $(DOBBY_DIR) -j$(shell sysctl -n hw.ncpu)

STEAM_APP    ?= $$(p=$$(defaults read dev.bryann2k.cartouche steamAppPath 2>/dev/null); printf '%s' "$${p:-/Applications/Steam.app}")
DEPLOY_DST    = $(STEAM_APP)/Contents/MacOS/$(DYLIB_NAME)
INSTALL_DST  := $(SUPPORT_DIR)/$(DYLIB_NAME)

dylib-install: $(TARGET)
	$(call install_atomically,$(TARGET),$(INSTALL_DST))
	@echo "==> Installed: $(INSTALL_DST)"

sigdb-install:
	@mkdir -p "$(SUPPORT_DIR)/signatures/macos.arm64"
	cp -f signatures/macos.arm64/*.json "$(SUPPORT_DIR)/signatures/macos.arm64/"
	@echo "==> Installed: $(SUPPORT_DIR)/signatures/macos.arm64"

LAUNCHABLE_BUNDLES := $(HOME)/Desktop/Cartouche.app /Applications/Cartouche.app

FONT_FILES := --include='*/' --include='*.ttf' --include='*.ttc' --exclude='*'

fonts-install:
	@if [ ! -d build/fonts ]; then echo "build/fonts is missing, run: $(MAKE) fonts" >&2; exit 1; fi
	@mkdir -p "$(SUPPORT_DIR)/fonts"
	@rsync -a --delete $(FONT_FILES) build/fonts/ "$(SUPPORT_DIR)/fonts/"
	@echo "==> Installed: $(SUPPORT_DIR)/fonts"

deploy: $(TARGET) dylib-install sigdb-install fonts-install helpers-install
	@if [ ! -d "$(STEAM_APP)" ]; then \
		echo "==> deploy: $(STEAM_APP) not found"; exit 1; fi
	$(call install_atomically,$(TARGET),$(DEPLOY_DST))
	@echo "==> Deployed: $(DEPLOY_DST) (restart Steam to load)"
	@for b in $(LAUNCHABLE_BUNDLES); do \
		p=$$(find "$$b" -name $(DYLIB_NAME) -type f 2>/dev/null | head -1); \
		[ -n "$$p" ] || continue; \
		cmp -s "$$p" "$(DEPLOY_DST)" && continue; \
		echo "==> warning: $$b carries a different $(DYLIB_NAME)"; \
		echo "==> warning: launching it reverts this deploy, so rebuild it with 'make app'"; \
	done

WINE_BUILD := scratch/wine-build-dual

WINE_BUILD_ARM64 := scratch/wine-build-arm64

BRIDGE_FILES := \
	$(WINE_BUILD)/programs/steam.exe/x86_64-windows/steam.exe:steam.exe \
	$(WINE_BUILD)/dlls/lsteamclient/x86_64-windows/lsteamclient.dll:x86_64-windows-lsteamclient.dll \
	$(WINE_BUILD)/dlls/lsteamclient/lsteamclient.so:x86_64-unix-lsteamclient.so \
	$(WINE_BUILD_ARM64)/dlls/lsteamclient/lsteamclient.so:aarch64-unix-lsteamclient.so \
	$(WINE_BUILD)/dlls/lsteamclient/i386-windows/lsteamclient.dll:i386-windows-lsteamclient.dll

bridge:
	bridge/setup-wine-tree.sh
	WINE_BUILD="$(CURDIR)/$(WINE_BUILD_ARM64)" HOST=aarch64-apple-darwin \
		HOST_CC="clang -arch arm64" HOST_CXX="clang++ -arch arm64" bridge/setup-wine-tree.sh
	lsteamclient/build.sh
	UNIX_ARCH=arm64 WINE_BUILD="$(CURDIR)/$(WINE_BUILD_ARM64)" lsteamclient/build.sh --unix
	steam-shim/build.sh
	@echo "==> Built the bridge, now run: $(MAKE) app-payload"

fonts:
	fonts/build.sh

app-payload: $(TARGET) $(OVERLAY_SHIM) $(FPS_COUNTER) $(FRAMEGEN) $(ICONMAKER) $(APPINFO)
	@mkdir -p "$(APP_PAYLOAD)/signatures/macos.arm64"
	@mkdir -p "$(APP_PAYLOAD)/bridge"
	cp -f $(TARGET) "$(APP_PAYLOAD)/$(DYLIB_NAME)"
	cp -f $(OVERLAY_SHIM) "$(APP_PAYLOAD)/overlay-shim.dylib"
	cp -f $(FPS_COUNTER) "$(APP_PAYLOAD)/$(notdir $(FPS_COUNTER))"
	cp -f $(FRAMEGEN) "$(APP_PAYLOAD)/$(notdir $(FRAMEGEN))"
	cp -f $(ICONMAKER) "$(APP_PAYLOAD)/iconmaker"
	cp -f $(APPINFO) "$(APP_PAYLOAD)/appinfo"
	cp -f dylib/feats/compat_run.sh "$(APP_PAYLOAD)/run"
	cp -f signatures/macos.arm64/*.json "$(APP_PAYLOAD)/signatures/macos.arm64/"
	@set -e; for spec in $(BRIDGE_FILES); do \
		src="$${spec%%:*}"; dst="$(APP_PAYLOAD)/bridge/$${spec##*:}"; \
		if [ -f "$$src" ]; then cp -f "$$src" "$$dst"; \
		elif [ -f "$$dst" ]; then echo "==> keeping staged $${spec##*:}"; \
		else echo "$$src is missing and nothing is staged at $$dst, run: $(MAKE) bridge" >&2; exit 1; fi; \
	done
	@if command -v "$(MINGW32)" >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory $(UNARC_DRIVER) && \
		cp -f "$(UNARC_DRIVER)" "$(APP_PAYLOAD)/unarc-driver.exe"; \
	elif [ -f "$(APP_PAYLOAD)/unarc-driver.exe" ]; then echo "==> keeping staged unarc-driver.exe"; \
	else echo "$(UNARC_DRIVER) needs $(MINGW32) (brew install mingw-w64) or a staged $(APP_PAYLOAD)/unarc-driver.exe" >&2; exit 1; fi
	@if command -v "$(MINGW64)" >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory $(GAME_RESTORE) && \
		cp -f "$(GAME_RESTORE)" "$(APP_PAYLOAD)/game-restore.exe"; \
	elif [ -f "$(APP_PAYLOAD)/game-restore.exe" ]; then echo "==> keeping staged game-restore.exe"; \
	else echo "$(GAME_RESTORE) needs $(MINGW64) (brew install mingw-w64) or a staged $(APP_PAYLOAD)/game-restore.exe" >&2; exit 1; fi
	@if [ ! -d build/fonts ]; then echo "build/fonts is missing, run: $(MAKE) fonts" >&2; exit 1; fi
	@mkdir -p "$(APP_PAYLOAD)/fonts"
	@rsync -a --delete build/fonts/ "$(APP_PAYLOAD)/fonts/"
	@stamp="$$(git log -1 --format=%ct 2>/dev/null)"; \
	if [ -z "$$stamp" ]; then echo "build-time needs a git checkout" >&2; exit 1; fi; \
	echo "$$stamp" > "$(APP_PAYLOAD)/build-time"
	@echo "==> Staged app payload in $(APP_PAYLOAD)"

APP_BUNDLE  := $(OUT_DIR)/Cartouche.app
APP_ZIP     := $(OUT_DIR)/Cartouche.zip
APP_VERSION := $(shell sed -n 's/^\#define CARTOUCHE_VERSION "\(.*\)"/\1/p' dylib/version.h)

# Sparkle compares CFBundleVersion and reads 0.2.0-beta1 as equal to 0.2.0, so a
# pre-release carries 0.2.0b1 there (packaging/release.py bundle-version)
APP_BUNDLE_VERSION := $(shell echo '$(APP_VERSION)' | sed -E 's/-(b)eta\.?([0-9]+)$$/\1\2/; s/-(t)est\.([0-9]+)$$/\1\2/')

# The stable local release identity when this Mac has it and trusts it for
# code signing (docs/RELEASE.md); ad hoc otherwise, as on CI, on machines
# without the certificate and with an untrusted copy, which would prompt.
APP_SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Cartouche Local Signing"' && echo 'Cartouche Local Signing' || echo '-')

ICONGEN   := $(OUT_DIR)/make-icon
ICON_SRC  := $(OUT_DIR)/icon-src
ICON_DIR  := $(OUT_DIR)/icon
ICON_CAR  := $(ICON_DIR)/Assets.car
BRAND_DIR := mockup/brand

icon: $(ICON_CAR)

$(ICONGEN): tools/make-icon.swift
	@mkdir -p $(OUT_DIR)
	swiftc -O -o $@ $<
	@echo "==> Built $@"

# Assets.car carries the Default and Dark icons and the menu bar glyph, the icns
# is the same icon for Finder views that read CFBundleIconFile
$(ICON_CAR): $(ICONGEN) $(wildcard $(BRAND_DIR)/*.svg)
	rm -rf "$(ICON_SRC)" "$(ICON_DIR)"
	$(ICONGEN) "$(BRAND_DIR)" "$(ICON_SRC)"
	@mkdir -p "$(ICON_DIR)"
	xcrun actool "$(ICON_SRC)/Cartouche.icon" "$(ICON_SRC)/Glyphs.xcassets" app/Assets/App.xcassets --compile "$(ICON_DIR)" \
		--platform macosx --minimum-deployment-target 15.0 --app-icon Cartouche \
		--output-partial-info-plist "$(ICON_DIR)/partial.plist" >/dev/null
	iconutil -c icns -o "$(ICON_DIR)/Cartouche.icns" "$(ICON_SRC)/Cartouche.iconset"
	@echo "==> Built $@"

# Extra flags for the swift build inside the bundle recipe (e.g.
# `make qa-app SWIFT_FLAGS="--disable-sandbox ..."` inside a sandboxed shell).
SWIFT_FLAGS ?=

# Bundle assembly shared by `app` (release) and `qa-app` (debug):
# $(1) is the swift build configuration, $(2) the bundle path.
define BUNDLE_APP
	swift build --package-path app -c $(1) $(SWIFT_FLAGS)
	rm -rf "$(2)"
	@mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources"
	cp app/Info.plist "$(2)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c \
		"Set :CFBundleShortVersionString $(APP_VERSION)" -c \
		"Set :CFBundleVersion $(APP_BUNDLE_VERSION)" \
		"$(2)/Contents/Info.plist"
	cp "$$(swift build --package-path app -c $(1) $(SWIFT_FLAGS) --show-bin-path)/NotProtonApp" \
		"$(2)/Contents/MacOS/Cartouche"
	@mkdir -p "$(2)/Contents/Frameworks"
	ditto "$$(swift build --package-path app -c $(1) $(SWIFT_FLAGS) --show-bin-path)/Sparkle.framework" \
		"$(2)/Contents/Frameworks/Sparkle.framework"
	install_name_tool -add_rpath @executable_path/../Frameworks \
		-add_rpath @executable_path/../Helpers \
		"$(2)/Contents/MacOS/Cartouche"
	xcrun vtool -set-build-version macos $(MIN_VER) "$$(xcrun --sdk macosx --show-sdk-version)" \
		-replace -output "$(2)/Contents/MacOS/Cartouche" \
		"$(2)/Contents/MacOS/Cartouche"
	cp -R "$$(swift build --package-path app -c $(1) $(SWIFT_FLAGS) --show-bin-path)/NotProtonApp_NotProtonApp.bundle" \
		"$(2)/Contents/Resources/"
	ditto "$(APP_PAYLOAD)" \
		"$(2)/Contents/Resources/NotProtonApp_NotProtonApp.bundle/Contents/Resources/payload"
	cp -R "$$(swift build --package-path app -c $(1) $(SWIFT_FLAGS) --show-bin-path)/RetroArchKit_RetroArchKit.bundle" \
		"$(2)/Contents/Resources/"
	cp -R "$(2)/Contents/Resources/NotProtonApp_NotProtonApp.bundle/Contents/Resources/"*.lproj \
		"$(2)/Contents/Resources/"
	@mkdir -p "$(2)/Contents/Helpers"
	# The stdio face of the app's MCP server; MCP clients run it from the bundle
	cp -f "$$(swift build --package-path app -c $(1) $(SWIFT_FLAGS) --show-bin-path)/cartouche-mcp" \
		"$(2)/Contents/Helpers/cartouche-mcp"
	codesign -f -s "$(APP_SIGN_ID)" -o runtime "$(2)/Contents/Helpers/cartouche-mcp"
	cp "$(ICON_DIR)/Assets.car" "$(ICON_DIR)/Cartouche.icns" \
		"$(2)/Contents/Resources/"
	@missing=$$(cd "$(APP_PAYLOAD)" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' \
		| while read -r rel; do \
			cmp -s "$$rel" "$(CURDIR)/$(2)/Contents/Resources/NotProtonApp_NotProtonApp.bundle/Contents/Resources/payload/$$rel" || echo "$$rel"; \
		done); \
	if [ -n "$$missing" ]; then \
		echo "==> the bundle has missing or changed staged payload:" >&2; \
		echo "$$missing" | sed 's/^/        /' >&2; \
		echo "==> rm -rf app/.build/out and build again" >&2; \
		exit 1; \
	fi
	@echo "==> Payload complete in the bundle"
	@if [ -x "$(INNOEXTRACT)" ] && file -b "$(INNOEXTRACT)" | grep -q 'Mach-O'; then \
		mkdir -p "$(2)/Contents/Helpers" && \
		cp -f "$(INNOEXTRACT)" "$(2)/Contents/Helpers/innoextract" && \
		codesign -f -s "$(APP_SIGN_ID)" -o runtime "$(2)/Contents/Helpers/innoextract"; \
	elif [ "$(1)" = release ]; then \
		echo "==> $(INNOEXTRACT) is missing, the release app cannot read installers without it (run: $(MAKE) innoextract)" >&2; exit 1; \
	else echo "==> $(INNOEXTRACT) not built, installer analysis needs a Homebrew innoextract (run: $(MAKE) innoextract)"; fi
	@if ! file -b "$(LIBARCHIVE)" 2>/dev/null | grep -q 'Mach-O'; then \
		echo "==> $(LIBARCHIVE) is missing or not a library, the app would ship without archive extraction (run: rm -rf build/libarchive && $(MAKE) libarchive)" >&2; exit 1; \
	fi
	@mkdir -p "$(2)/Contents/Helpers"
	cp -f "$(LIBARCHIVE)" "$(2)/Contents/Helpers/libarchive.dylib"
	codesign -f -s "$(APP_SIGN_ID)" "$(2)/Contents/Helpers/libarchive.dylib"
	# Payload dylibs and tools are resources of the inner bundle: --deep seals
	# them as data instead of signing them, so they are signed by hand first.
	@find "$(2)/Contents/Resources/NotProtonApp_NotProtonApp.bundle/Contents/Resources/payload" -type f \
		| while IFS= read -r f; do \
			case "$$(od -An -tx1 -N4 "$$f" | tr -d ' ')" in \
			cffaedfe|feedfacf|feedface|cefaedfe|cafebabe|bebafeca) \
				if file -b "$$f" | grep -q executable; then codesign -f -s "$(APP_SIGN_ID)" -o runtime "$$f"; \
				else codesign -f -s "$(APP_SIGN_ID)" "$$f"; fi ;; \
			esac; \
		done
	# Hardened runtime everywhere; only the app itself may load our own frameworks (no Team ID on a local certificate)
	codesign -f -s "$(APP_SIGN_ID)" --deep -o runtime "$(2)"
	codesign -f -s "$(APP_SIGN_ID)" -o runtime --entitlements app/Cartouche.entitlements "$(2)"
	codesign --verify --deep --strict "$(2)"
	@echo "==> Built $(2) ($(APP_VERSION), $(1))"
endef

app: app-payload $(ICON_CAR)
	$(call BUNDLE_APP,release,$(APP_BUNDLE))

# The QA app is a debug build on purpose: QAEnvironment honours
# CARTOUCHE_QA_BASE_URL only when DEBUG is defined, so the release app ignores
# it. qa/launch.sh launches this bundle.
qa-app: app-payload $(ICON_CAR)
	$(call BUNDLE_APP,debug,$(OUT_DIR)/Cartouche-QA.app)

app-zip: app
	rm -f "$(APP_ZIP)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(APP_ZIP)"
	@echo "==> Wrote $(APP_ZIP)"

# innoextract for the Windows installer analysis, built from pinned sources
INNOEXTRACT := $(OUT_DIR)/innoextract
.PHONY: innoextract libarchive installer-tests
innoextract: $(INNOEXTRACT)

$(INNOEXTRACT): installer/innoextract/pins installer/innoextract/build.sh
	sh installer/innoextract/build.sh build/innoextract "$@"

# libarchive for the built-in decompressor, universal, built from pinned sources
LIBARCHIVE := $(OUT_DIR)/libarchive.dylib
libarchive: $(LIBARCHIVE)
$(LIBARCHIVE): installer/libarchive/build.sh installer/libarchive/pins
	sh installer/libarchive/build.sh build/libarchive "$(LIBARCHIVE)"

# The app bundles the dylib in Contents/Helpers and loads it by @rpath; build it
# rather than ship a bundle whose archive drops can only report detection is off.
# These prerequisites sit below the definitions: make expands them when it reads
# the rule, so naming them above would add an empty prerequisite.
app qa-app: $(LIBARCHIVE)
app: $(INNOEXTRACT)

installer-tests:
	@cd installer && swift test

# Release tooling in packaging/
.PHONY: redistscan packagingcheck
redistscan:
	@sh packaging/redist-scan.sh .

packagingcheck:
	@sh packaging/tests/redist-scan-test.sh
	@python3 packaging/tests/workflow_check.py
	@sh packaging/tests/signing-test.sh
	@sh packaging/tests/install-test.sh
	@sh packaging/tests/dmg-test.sh
	@python3 -m unittest discover -s packaging/tests -p 'test_*.py'

clean:
	rm -rf $(OUT_DIR)

rebuild: clean all

-include $(DEPS)

FORCE:

include retroarch/retroarch.mk
include tools/c-safety/c-safety.mk

.PHONY: launchlogcheck
launchlogcheck:
	sh dylib/tests/launchlogcheck.sh dylib/feats/compat_run.sh

# Every security check on the exact app that ships (security/gate.sh); see docs/ci/CI-ARCHITECTURE.md
release-gate: app
	@bash security/gate.sh --app out/Cartouche.app

# The gate catches every planted defect (secrets, workflows, Keychain, unsafe C, code rules)
release-gate-selftest:
	@bash security/tests/planted-defects.sh

.PHONY: release-gate release-gate-selftest
