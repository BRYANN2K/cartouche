# Memory-safety checks for the C code: sanitizers, static analysis, fuzzing.
# docs/ci/C-SAFETY.md says what each target covers and when CI runs it.

.PHONY: c-asan c-asan-gpu

SAN_FLAGS := -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all -g
SAN_ENV   := ASAN_OPTIONS=halt_on_error=1:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:detect_invalid_pointer_pairs=1 \
             UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1
ASAN_OUT  := $(OUT_DIR)/asan

# The hermetic C suites the CI runs, rebuilt under ASan+UBSan into out/asan. The shell
# suites (envcheck, routecheck, ...) test the run script, not C, and stay out.
ASAN_SUITES := compatcheck compatsvc-check libexport-check services-check webuicheck \
               shortcutcheck launch-shell activatecheck spawn-env peicon-fixtures \
               webpatch-fixtures panel-behavior callscheck unarccheck homecheck

c-asan:
	@mkdir -p $(OUT_DIR); start=$$(date +%s); fail=0; \
	for t in $(ASAN_SUITES); do \
		s=$$(date +%s); \
		env $(SAN_ENV) $(MAKE) -s $$t OUT_DIR=$(ASAN_OUT) COMPATCHECK_CHAIN= \
			TEST_CC='$(TEST_CC) $(SAN_FLAGS)' > $(OUT_DIR)/c-asan-$$t.log 2>&1; rc=$$?; \
		if [ $$rc -ne 0 ]; then \
			echo "  FAIL  $$t (rc=$$rc), log: $(OUT_DIR)/c-asan-$$t.log"; \
			if grep -qE 'ERROR: AddressSanitizer|runtime error:' $(OUT_DIR)/c-asan-$$t.log; then \
				grep -E -A12 'ERROR: AddressSanitizer|runtime error:' $(OUT_DIR)/c-asan-$$t.log | head -40; \
			else tail -20 $(OUT_DIR)/c-asan-$$t.log; fi; \
			fail=1; \
		else echo "  ok    $$t ($$(( $$(date +%s) - s ))s)"; fi; \
	done; \
	$(MAKE) -s c-asan-gpu || fail=1; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "==> c-asan: $(words $(ASAN_SUITES)) suites clean under ASan+UBSan in $$(( $$(date +%s) - start ))s"

# The injected dylibs need a Metal device and a window server; C_ASAN_GPU=0 skips them.
# Host and dylib are both sanitized, so the dylib finds the runtime already loaded.
C_ASAN_GPU   ?= auto
ASAN_GPU_OUT := $(OUT_DIR)/asan-gpu

c-asan-gpu:
	@if [ "$(C_ASAN_GPU)" = 0 ]; then \
		echo "  skip  overlay-shim-tests, fps-counter-tests: C_ASAN_GPU=0"; exit 0; fi; \
	if [ "$(C_ASAN_GPU)" = auto ] && ! system_profiler SPDisplaysDataType 2>/dev/null | grep -q Metal; then \
		echo "  skip  overlay-shim-tests, fps-counter-tests: no Metal device here"; exit 0; fi; \
	mkdir -p $(OUT_DIR); fail=0; \
	for t in overlay-shim-tests fps-counter-tests; do \
		s=$$(date +%s); \
		env $(SAN_ENV) $(MAKE) -s $$t OUT_DIR=$(ASAN_GPU_OUT) \
			OVERLAY_SHIM_FLAGS='$(OVERLAY_SHIM_FLAGS) $(SAN_FLAGS)' \
			OVERLAY_SHIM_TEST_FLAGS='$(OVERLAY_SHIM_TEST_FLAGS) $(SAN_FLAGS)' \
			FPS_COUNTER_FLAGS='$(FPS_COUNTER_FLAGS) $(SAN_FLAGS)' \
			FPS_PRESENT_FLAGS='$(FPS_PRESENT_FLAGS) $(SAN_FLAGS)' > $(OUT_DIR)/c-asan-$$t.log 2>&1; rc=$$?; \
		if [ $$rc -ne 0 ]; then \
			echo "  FAIL  $$t (rc=$$rc), log: $(OUT_DIR)/c-asan-$$t.log"; \
			if grep -qE 'ERROR: AddressSanitizer|runtime error:' $(OUT_DIR)/c-asan-$$t.log; then \
				grep -E -A12 'ERROR: AddressSanitizer|runtime error:' $(OUT_DIR)/c-asan-$$t.log | head -40; \
			else tail -20 $(OUT_DIR)/c-asan-$$t.log; fi; \
			fail=1; \
		else echo "  ok    $$t, arm64 and x86_64 ($$(( $$(date +%s) - s ))s)"; fi; \
	done; \
	exit $$fail

# ---- Static analysis -------------------------------------------------------------------
.PHONY: c-analyze

c-analyze: $(RUN_SCRIPT_H) $(FRAMEGEN_KERNELS) $(FRAMEGEN_UPSCALE_KERNELS) $(FRAMEGEN_OVERLAY_KERNELS)
	@s=$$(date +%s); \
	DYLIB_SRCS="$(filter-out vendor/%,$(SRCS))" sh tools/c-safety/analyze.sh $(OUT_DIR)/analyze $(GENERATED_DIR) && \
	echo "    in $$(( $$(date +%s) - s ))s"

# ---- Fuzzing ---------------------------------------------------------------------------
# libFuzzer harnesses in fuzz/, built with Xcode's clang against a libFuzzer.a built from
# pinned LLVM sources (fuzz/build-libfuzzer.sh). LIBFUZZER= points at another one, such as
# Homebrew LLVM's libclang_rt.fuzzer_osx.a.

.PHONY: fuzz-build fuzz-smoke fuzz-nightly fuzz-regress fuzz-seeds

FUZZ_OUT        := $(OUT_DIR)/fuzz
LIBFUZZER_DIR   := build/libfuzzer
LIBFUZZER       ?= $(LIBFUZZER_DIR)/libFuzzer.a
FUZZ_SAN        := -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
FUZZ_CFLAGS     := -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -g -O1 $(FUZZ_SAN) \
                   -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -Wno-deprecated-declarations \
                   -Idylib -I$(IDENTITY_INC) -I$(GENERATED_DIR) -Ivendor
FUZZ_SMOKE_SECONDS ?= 60
FUZZ_SECONDS       ?= 3600
FUZZ_RUN_FLAGS     := -rss_limit_mb=0 -timeout=10 -print_final_stats=1

# Each harness, with the units it links beyond the one it includes
FUZZ_HARNESSES := peicon aob sigdb webpatch libexport compat nativeplatform spawn launch \
                  framegen_env
FUZZ_LINK_sigdb          := dylib/util/file.c vendor/cJSON.c
FUZZ_LINK_libexport      := dylib/util/file.c vendor/cJSON.c
FUZZ_LINK_nativeplatform := dylib/util/file.c
FUZZ_LANG_framegen_env   := -x objective-c -fobjc-arc -Ifuzz -Iframegen -I$(OUT_DIR)/framegen
FUZZ_LINK_framegen_env   := framegen/fg_temporal.m framegen/fg_upscale.m framegen/fg_overlay.m
FUZZ_FW_framegen_env     := -framework Foundation -framework Metal -framework MetalFX \
                            -framework QuartzCore -framework AppKit -framework CoreText
FUZZ_DEPS_compat         := $(RUN_SCRIPT_H)
FUZZ_DEPS_framegen_env   := $(FRAMEGEN_UPSCALE_KERNELS) $(FRAMEGEN_OVERLAY_KERNELS)

fuzz_src = $(firstword $(wildcard fuzz/fuzz_$(1).c fuzz/fuzz_$(1).m))

$(LIBFUZZER): fuzz/build-libfuzzer.sh
	sh fuzz/build-libfuzzer.sh $(LIBFUZZER_DIR)

# The libFuzzer build, and a replay build that runs inputs once without libFuzzer, so the
# seeds and the regression inputs can run on every PR without fetching LLVM.
define FUZZ_RULES
$(FUZZ_OUT)/fuzz_$(1): $(call fuzz_src,$(1)) fuzz/fuzz.h $(FUZZ_DEPS_$(1)) $(LIBFUZZER) FORCE
	@mkdir -p $$(dir $$@)
	$(CC) $(FUZZ_CFLAGS) -fsanitize=fuzzer-no-link $(FUZZ_LANG_$(1)) -o $$@ $(call fuzz_src,$(1)) \
		-x none $(FUZZ_LINK_$(1)) $(LIBFUZZER) -lc++ $(FUZZ_FW_$(1))

$(FUZZ_OUT)/replay_$(1): $(call fuzz_src,$(1)) fuzz/fuzz.h fuzz/replay.c $(FUZZ_DEPS_$(1)) FORCE
	@mkdir -p $$(dir $$@)
	$(CC) $(FUZZ_CFLAGS) $(FUZZ_LANG_$(1)) -o $$@ $(call fuzz_src,$(1)) \
		-x c fuzz/replay.c $(if $(FUZZ_LINK_$(1)),-x none $(FUZZ_LINK_$(1))) $(FUZZ_FW_$(1))
endef
$(foreach h,$(FUZZ_HARNESSES),$(eval $(call FUZZ_RULES,$(h))))

fuzz-build: $(foreach h,$(FUZZ_HARNESSES),$(FUZZ_OUT)/fuzz_$(h))

# Runs every harness for $(1) seconds from its seeds and the corpus grown so far. A crash
# leaves its input in out/fuzz/artifacts/<harness>/: minimise it and add it to
# fuzz/regressions/<harness>/ with the fix.
define FUZZ_RUN
	@fail=0; \
	for h in $(FUZZ_HARNESSES); do \
		mkdir -p $(FUZZ_OUT)/corpus/$$h $(FUZZ_OUT)/artifacts/$$h; \
		s=$$(date +%s); \
		env $(SAN_ENV) $(FUZZ_OUT)/fuzz_$$h $(FUZZ_RUN_FLAGS) -max_total_time=$(1) \
			-artifact_prefix=$(FUZZ_OUT)/artifacts/$$h/ \
			$(FUZZ_OUT)/corpus/$$h fuzz/corpus/$$h $$(ls -d fuzz/regressions/$$h 2>/dev/null) \
			> $(FUZZ_OUT)/$$h.log 2>&1; rc=$$?; \
		runs=$$(sed -n 's/^stat::number_of_executed_units: *//p' $(FUZZ_OUT)/$$h.log); \
		cov=$$(grep -o 'cov: [0-9]*' $(FUZZ_OUT)/$$h.log | tail -1); \
		if [ $$rc -ne 0 ]; then \
			echo "  FAIL  $$h (rc=$$rc), log: $(FUZZ_OUT)/$$h.log"; \
			grep -E -A15 'ERROR: |runtime error:|deadly signal' $(FUZZ_OUT)/$$h.log | head -30; \
			fail=1; \
		else echo "  ok    $$h, $$(( $$(date +%s) - s ))s, $$runs runs, $$cov"; fi; \
	done; \
	exit $$fail
endef

fuzz-smoke: fuzz-build
	$(call FUZZ_RUN,$(FUZZ_SMOKE_SECONDS))

fuzz-nightly: fuzz-build
	$(call FUZZ_RUN,$(FUZZ_SECONDS))

# Every seed and every past crash, once each, under ASan+UBSan. No libFuzzer needed.
fuzz-regress: $(foreach h,$(FUZZ_HARNESSES),$(FUZZ_OUT)/replay_$(h))
	@fail=0; n=0; \
	for h in $(FUZZ_HARNESSES); do \
		files=$$(find fuzz/corpus/$$h fuzz/regressions/$$h -type f 2>/dev/null); \
		[ -n "$$files" ] || { echo "  FAIL  $$h has no seeds"; fail=1; continue; }; \
		n=$$((n + $$(echo "$$files" | wc -l))); \
		env $(SAN_ENV) $(FUZZ_OUT)/replay_$$h $$files || { echo "  FAIL  $$h"; fail=1; }; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "==> fuzz-regress: $$n seed and regression inputs replay clean"

# Rewrites the webpatch seeds from the gate table, after the table changes
fuzz-seeds:
	@mkdir -p $(FUZZ_OUT) fuzz/corpus/webpatch
	$(CC) $(FUZZ_CFLAGS) -DFZ_SEED_MAIN -o $(FUZZ_OUT)/seed_webpatch fuzz/fuzz_webpatch.c
	$(FUZZ_OUT)/seed_webpatch fuzz/corpus/webpatch
