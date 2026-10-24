# Wine-side fix for ISDone/unarc installers (external unpackers): research

Date: 2026-10-21. Target: cartouche-wine 26.3.0-3 (CodeWeavers crossover-sources-26.3.0, SHA-256 ac99c8ca..., new WoW64 i386+x86_64, Rosetta 2).
Builds on: wine-build:docs/research/compat-isdone-dep-wow64.md and the CarX trace in .claude/night-report.md (lines 135-147).
Note: bugs.winehq.org / list.winehq.org did not resolve from this sandbox. WineHQ bug 60494 is only known through the third-party reports below (unverified).

## Short answer
The crash is not DEP. It matches a known Rosetta + new-WoW64 fault in wow64cpu.dll's 32->64 syscall thunk (WineHQ 60494), which CodeWeavers works around with "CW HACK 20760".
That hack appears to already be in the CrossOver 26.3 sources we build, so our runner probably avoids the crash. The CarX trace only came from stock WineHQ 11.0 and 11.18.
Recommendation: (c), with no new Wine patch. Check on hardware that CarX setup runs on our 26.3.0-2 build, keep the direct unpack path, and add a Rosetta thunk stress test.

## 1. DEP/NX or a WoW64 thunk problem?
- Our trace (night-report, 2026-10-20): the first fault is an AV reading 0x4ECD at eip 7bf21139 inside wow64cpu.dll, on the NtResetEvent syscall (eax 0xd7 on Wine 11.0, 0xdd on 11.18). The jump to 0x00020002 is a later bogus SEH handler, a secondary cascade. The ProcessExecuteFlags query comes before it but does not cause it. Runners: WineHQ 11.0 and Wine Devel 11.18 (Gcenx stock).
- Same signature reported independently:
  - Gcenx/macOS_Wine_builds#172 (opened 2026-10-14, closed "not planned" 2026-10-20): AV at wow64cpu+0x123D reading 0x4DC9. The instruction is `mov edx,[rip+0x4dc9]` right after `xchg r14,rsp` in `syscall_32to64`. 64-bit thunk code decoded in 32-bit mode turns the RIP-relative displacement into an absolute address. https://github.com/Gcenx/macOS_Wine_builds/issues/172
  - A second report in #172 (2026-10-20, a 32-bit Inno Setup installer on Gcenx Staging 11.18): AV at wow64cpu+0x1135 reading 0x2EC5, bytes `8B 15 C5 2E 00 00`. This is the same offset as our 11.18 crash (7BF21135).
- Neutron PR #62 (2026-10-11), a stress test of 32-bit D3D9 setup: Wine 11.18 32-bit fails 4/8, 64-bit 0/4, CrossOver 24 (Wine 9) 0/8. https://github.com/codeWonderland/neutron/pull/62
- Gcenx (2026-10-20, in #172): WineHQ macOS packages may no longer carry extra patches, so stock WineHQ builds lack the CrossOver Rosetta hacks.
- **CW HACK 20760** in `dlls/wow64cpu/cpu.c`, as seen in athei/wine `cx-26-patched` (that branch imports "crossover 26.3.0 changes", dated 2026-08-18):
  - `BTCpuProcessInit` sets `use_rosetta2_workaround = is_rosetta2()`. `is_rosetta2()` checks `SystemProcessorBrandString` for "VirtualApple".
  - `syscall_32to64` and `unix_call_32to64` then return to 32-bit code with `lretq` instead of `ljmp *(%r14)`. The code comment says this works around "a SIGUSR1 race condition" under Rosetta 2.
  - Source: https://raw.githubusercontent.com/athei/wine/cx-26-patched/dlls/wow64cpu/cpu.c (LGPL-2.1+, header "Copyright 2021 Alexandre Julliard").
  - Not one of athei's own commits: https://github.com/athei/wine/commits/cx-26-patched
  - VERIFY LOCALLY: `grep -n "CW HACK 20760" sources/wine/dlls/wow64cpu/cpu.c` in our extracted tarball.
- Inference (unverified): ISDone/setup.tmp has threads that suspend each other or read thread context. Wine delivers those requests with SIGUSR1, which hits the ljmp window. This would explain why the crash is right after ISDone loads, why it varies with timing, and why unarc never loads.
- The "null call" with CrossOver 23.7.1 in the prior research used the old wine32on64 path, not new WoW64. It may be a different failure (not confirmed).
- Workarounds found: none specific to ISDone. The DEP knobs (WINE_DISABLE_NX_COMPAT / WINE_FORCE_NX / AppCompat) do not target this fault. renderer=vulkan only helped the D3D9 trigger in #172, and it did not help the installer report there. No WINEDLLOVERRIDES or isdone replacement found with sources. The only proven path remains extracting outside setup.tmp (prior research).

## 2. The two candidate patches
**athei/wine-build "decide no-exec from main exe" / WINE_FORCE_NX**
- Origin: athei/wine-build#3 (rdbell, 2026-09-04). Loading one DLL without NX_COMPAT turns DEP off for the whole process. That makes all readable memory RWX, and first touches under Rosetta became about 190x slower (12 ms to 2,260 ms per frame). https://github.com/athei/wine-build/issues/3
- 7310bd8 (about 2026-09-06), "ntdll: Decide no-exec from the main executable only". Changes only `dlls/ntdll/loader.c` `alloc_module()`: the check runs only when hModule == PEB ImageBaseAddress, and WINE_DISABLE_NX_COMPAT keeps DEP on. https://github.com/athei/wine/commit/7310bd8
- 539aa62 / 4327e70 / 49817a1 (Sept 25 to Oct 16, 2026, re-based versions of one change). Files: `loader.c` `alloc_module()` and `dlls/ntdll/unix/process.c`.
  - New `get_execute_flags()` with a cached result. It reads the env variable and `sysctl.proc_translated`.
  - Under Rosetta it adds MEM_EXECUTE_OPTION_PERMANENT, so `NtSetInformationProcess(ProcessExecuteFlags)` and SetProcessDEPPolicy return STATUS_ACCESS_DENIED.
  - The final variable is WINE_FORCE_NX: unset means DEP is always on under Rosetta, `0` means Windows behaviour, any other value means always on.
  - https://github.com/athei/wine/commit/49817a1 , release https://github.com/athei/wine-build/releases/tag/cx-26.3.0-6 (2026-09-25)
- License: fork of Wine, LGPL-2.1+. It should apply with fuzz to CX 26.3 because athei's base is the 26.3 import (not tested).
- Regressions: no documented regressions. By design, programs that run code from data pages break unless WINE_FORCE_NX=0 (release notes). Perf was confirmed only on DEP flags. rdbell could not re-measure FPS on -5 (issue #3, 2026-09-12).
- Relevance here: none. It makes DEP stricter, and it does not touch wow64cpu.

**LuidgiAlt/crossover-rosetta-patches 0004 rosetta-lazy-exec**
- Targets exactly our tarball (same SHA-256 ac99c8ca...). Applies with `patch -p1` after 0001-0003.
- It changes ntdll.so: the `loader.c` DEP-off path, `force_exec_prot`, the `virtual_mutex` fault path, and CrossOver's "CW Hack 24945" mprotect fault handler.
- Mechanism: when DEP is off, PROT_EXEC is added on a page's first instruction fetch and dropped on write. It is opt-in with WINE_ROSETTA_LAZY_EXEC=1 and stock behaviour otherwise.
- License LGPL-2.1-or-later. Perf: removed 1-41 s upload stalls in one game (BO2, about 13M faults in 6 min).
- Known limits: tested in depth on one game. Code that writes and then runs code (emulators, .NET, script engines) takes more faults. No commit dates on the page (unverified age). https://github.com/LuidgiAlt/crossover-rosetta-patches
- Relevance here: none. It fixes slowness, not the wow64cpu fault.

## 3. Recommendation for 26.3.0-3: (c) no Wine change
- Do not carry athei's patch. It makes DEP permanent under Rosetta, which can only hurt installers that rely on DEP-off, and it does not fix this crash.
- Do not carry lazy-exec for this problem. Consider it later only as a performance item, opt-in.
- No env or registry toggle for external-unpacker installers: no DEP knob addresses the thunk fault.
- Action 1: run CarX setup.exe on the 26.3.0-2 runner (fresh prefix, after full wineboot, which can take over 5 min according to the night report) with `+seh,+virtual`.
  - If wow64cpu faults stop, the fix is choosing the runner. Never use stock WineHQ/Gcenx runners for 32-bit installers.
  - If it still fails, the crash is not the 20760 race. Report it with the trace and keep the direct unpack path.
- Action 2: the direct unpack path stays the default for these installers either way. It avoids setup.tmp entirely.

## CI test without a real installer (small 32-bit program, `i686-w64-mingw32-clang`)
- Test A (DEP guard, as requested). Steps:
  - Call `NtQueryInformationProcess(GetCurrentProcess(), 0x22, &f, 4, 0)` and print f.
  - VirtualAlloc a PAGE_READWRITE page, write `B8 2A 00 00 00 C3` (mov eax,42; ret), and call it under __try/SEH.
  - Then VirtualProtect the page to PAGE_EXECUTE_READ and call again.
  - Expected: the second call returns 42. Record whether the first call AVs (DEP on) or returns 42 (DEP off), and fail CI if it changes between builds.
- Test B (the real regression, more important). Steps:
  - Thread W loops `ResetEvent`/`SetEvent` (NtResetEvent syscall) 1e6 times.
  - Thread M loops `SuspendThread(W); GetThreadContext(W); ResumeThread(W)` meanwhile. This is the hypothesized SIGUSR1 trigger.
  - Pass means no AV with eip in wow64cpu after N iterations.
  - Also run Neutron's d3dprobe-style D3D9 adapter loop as a second trigger.
- Runner caveat: our build runner (macOS 15 x64) is Intel. There `is_rosetta2()` is false and the race cannot occur.
  - Test B needs an Apple-silicon runner (macos-14/15 arm64) with Rosetta installed (`softwareupdate --install-rosetta --agree-to-license`, not verified on hosted images).
  - Run it on stock WineHQ 11.0 as a positive control: it should fail there. If it cannot be reproduced in CI, keep it as a manual gate.

## Open points
- Confirm CW HACK 20760 is in our extracted tarball (grep above). It is inferred from athei's 26.3 import.
- WineHQ 60494 text not read (DNS failure). Its root cause and status are unverified.
- Whether 20760 fully closes the race: CrossOver 24 shows 0/8, but that is a small sample.
- Whether the 23.7.1 "null call" is the same bug.

## Sources (accessed 2026-10-21)
- https://github.com/Gcenx/macOS_Wine_builds/issues/172 (2026-10-14..20)
- https://github.com/codeWonderland/neutron/pull/62 (2026-10-11)
- https://raw.githubusercontent.com/athei/wine/cx-26-patched/dlls/wow64cpu/cpu.c (branch as of 2026-10-16)
- https://github.com/athei/wine/commits/cx-26-patched
- https://github.com/athei/wine-build/issues/3 (2026-09-04..12)
- https://github.com/athei/wine/commit/7310bd8 , /539aa62 , /4327e70 , /49817a1
- https://github.com/athei/wine-build/releases/tag/cx-26.3.0-6 (2026-09-25); README https://github.com/athei/wine-build
- https://github.com/LuidgiAlt/crossover-rosetta-patches (undated, page cites 2026-09-04)
- https://github.com/Alien4042x/WineForge (lists CW patch 20760, no description)

## Verified 2026-10-21 (orchestrator)
`crossover-sources-26.3.0.tar.gz` (sha256 ac99c8ca…6872, same as pins.env) contains `CW HACK 20760` in `sources/wine/dlls/wow64cpu/cpu.c` (lines 253, 327, 405, 435). So Cartouche Wine already carries the Rosetta wow64cpu workaround; the crash traces came from stock WineHQ builds.
