# Research: speeding up FreeArc/CLS repack unpacking on macOS

**Scope.** Read-only investigation; no code or personal files changed. `/tmp/carx-lab` artifacts were inspected. The active CarX extraction is a single-run, heavily loaded M-series datapoint (22 GB, roughly 1–1.5 h), not a controlled benchmark. Internet search was unavailable in this session, so upstream license/source classifications below are preliminary and must be verified against exact bundled versions before redistribution.

## Executive conclusion

The measured hot path is not the Inno Setup shell: it is CLS worker decoding (`magic2`, `srep`, `xtool`). A native archive reader alone will not remove this cost. First identify actual codec IDs and worker CPU utilization per archive; then test better thread/memory configuration and native SREP/XTool only where source and format compatibility are verified. A hybrid native reader with a Wine CLS worker is possible in principle, but the CLS mapping/event protocol and Windows ABI make it a substantial integration project; it is not a drop-in DLL bridge. Closed codecs remain Wine-bound absent permission/reimplementation.

## Codec/source and licensing map (verify per version)

| Component | Likely status / native arm64 macOS prospects | License and caveat |
|---|---|---|
| FreeArc / `unarc` | FreeArc project has source; core C/C++ portions can be compiled natively in principle. Existing Cartouche `archive_peek` is a reader, not evidence its extraction path supports every CLS codec. | FreeArc is commonly distributed under GPL-2.0-or-later; verify the exact source tree and bundled dependencies/notices. Linking/re-distributing has GPL obligations. |
| SREP | Public source/builds have existed; likely native-buildable (C/C++), and it is active in this sample. | Do not assume a permissive license: inspect the exact SREP source release/header. Obtain/retain license and notices before bundling. |
| XTool | Public source/project versions exist, commonly Delphi/FPC-oriented; native macOS arm64 viability depends on exact version, external libraries, and matching decoder behavior. Treat as experimental until parity-tested. | Exact release license needs source-level verification; do not infer license from “open source” label. |
| LZMA/LZMA2, zstd | Mature native arm64 implementations (e.g. 7-Zip SDK, liblzma, zstd). Useful only when archive/CLS format exposes compatible framing/filters. | 7-Zip SDK has mixed licensing by component; liblzma LGPL/GPL options; zstd BSD-3-Clause. Track the actual implementation and notices. |
| Oodle | RAD proprietary codec/SDK; no general redistributable native decoder. | Proprietary, contractual redistribution limits; use vendor-authorized runtime only. |
| LOLZ (`lolz` / ProFrager) | Treat as closed Windows helper unless a specific authorized source release is found; keep under Wine. | Proprietary/unclear redistribution rights; do not bundle/reimplement based on reverse engineering without legal review. `MaxThreadsUsage`/`MaxMemoryUsage` may be ignored for `mtt=0` per author forum post cited in lab notes. |
| Magic2 / `cls-magic2` | Treat as closed Windows CLS helper; active hot path. No verified native port. | Rights/version unclear; keep under Wine. |
| ZTool / precomp | Names cover multiple tools/versions; some related code may be public, but compatibility and licensing are version-specific. | Do not classify/bundle by name alone; inspect archive's exact helper and license. |

No license conclusions above authorize redistribution. Create a per-file SBOM and pin hashes/version/license before shipping codecs.

## Architecture options

1. **Stay all-Wine and tune** (lowest risk). Keep current 32-bit driver, exact CLS helper versions and mapping setup; collect data before changing settings. Wine 11.18 x86_64 under Rosetta is working. `WINEDEBUG=-all` is already used.
2. **Native open-codec workers** (medium/high effort). Build native FreeArc/SREP/XTool components for verified formats, route by codec identifier, retain Wine for LOLZ/Magic2/unknown CLS. Must reproduce CLS protocol, error behavior, checksums, and temp-file semantics.
3. **Native unarc + Wine-hosted closed-codec worker** (high effort/risk). Technically plausible via a broker: native process parses archive and sends blocks/metadata over an explicit IPC protocol to a Wine process which loads CLS DLLs. But existing CLS API depends on Windows DLL ABI, named file mappings/events and callbacks; a Unix process cannot directly load the DLL, and named mappings are not automatically a portable cross-runtime contract. Easiest bridge may still be a Wine-side worker that owns CLS and maps data through files/sockets/shared memory exposed by a host broker. Avoid trying to make native unarc directly call an in-process Wine DLL across ABIs. Prototype with one codec, measure copy/IPC overhead, and validate out-of-order/multi-thread semantics.

`cellar` is useful prior art for macOS Wine game bottles, installer automation, and a native FreeArc *inspection* reader (`archive_peek`); it does not demonstrate native CLS extraction. Lutris is Linux-focused; Whisky/Heroic are launch/runtime management, not evidence of native FreeArc/CLS decoders. Linux/Wine discussions can establish that Wine runs many repack helpers, but are not reliable performance measurements for Rosetta/macOS. No independently verified Linux-native complete CLS replacement or `isdone`-compatible alternative was found in the available local evidence.

## Ranked optimizations

Gain estimates are hypotheses, not guarantees; decoder-bound single-thread workload can dominate. Benchmark before prioritizing.

| Rank | Change | Expected gain | Effort / risk | Licensing |
|---|---|---|---|---|
| 1 | Record per-worker CPU, effective threads and memory; tune archive's supported `arc.ini`/`CLS.ini` settings and codec parameters. Test `MaxThreadsUsage`, `MaxMemoryUsage` only when codec mode honors them (notably mtt=0 caveat). | 0–50%+ where undersubscribed; none if fixed-thread/serial codec. | Low; memory pressure/throughput regressions possible. | No new code/license. |
| 2 | Benchmark native ports for verified open SREP/XTool/standard codecs; dispatch only on known codec IDs. | Potentially substantial if Rosetta translation or Wine overhead is material; unknown until measured. | High; exact bitstream compatibility, maintenance and fallback required. | Must clear each source/dependency license. |
| 3 | Avoid memory pressure: characterize SREP `-mem`/virtual-memory temp mode, page faults and swap; test RAM-backed temp only for bounded workloads. | Could be large if current 1 GB temp/swap bottleneck; can be negative if RAM disk competes with decoder. | Low/medium; disk-space and OOM risk. | None. |
| 4 | Verify actual parallelism and split-independent archive parts. Parallelize only independent volumes/files, not dependent solid blocks. | Near-linear only for genuinely independent data and spare cores; otherwise zero or harmful. | Medium; correctness and memory contention. | None. |
| 5 | Warm up Rosetta/Wine/helper once before timed run; separate cold-start from steady-state. | Saves startup/JIT cost only, likely negligible on a 1 h run. | Low. | None. |
| 6 | Compare temp locations (same APFS volume vs RAM disk), native output volume, free space; test I/O and F_NOCACHE/preallocation only if traces show I/O bottleneck. | Usually small for CPU-bound decode; can help if temp I/O dominates. | Low/medium; RAM pressure/APFS behavior risk. | None. |
| 7 | Test process priority and Wine synchronization options only when supported by this Wine build. | Usually small; avoid starving UI/system. | Low; msync/esync availability varies by Wine fork/macOS and must be confirmed, not assumed. | None. |

### Practical notes

- The lab ran `WINEDEBUG=-all`, so keep that for production runs; compare only if diagnostic logging is needed.
- `TEMP`/`TMP=C:\T` maps temp to the prefix's C: T directory; actual helper temp files and I/O must be measured. Current SREP virtual-memory temp use may consume substantial disk and compete with output.
- A RAM disk is not automatically faster: if data is already cached or decoder is CPU-bound it steals memory from Rosetta/Wine and can induce swap. Set a conservative size and ensure ample physical memory.
- Rosetta translation has warm/cold effects; a 1–1.5 h run amortizes one-time translation. Do not promise a large speedup from “AOT cache warm-up”.
- `F_NOCACHE` and preallocation are platform-specific implementation changes; test with/without and inspect actual I/O. Do not apply blindly to source archives or output.
- macOS Wine synchronization support is fork/version-specific. Confirm `wine --help`/runner documentation and runtime logs before setting `WINEESYNC`/`WINEMSYNC`; do not transplant Linux Proton advice.

## Benchmark protocol (<4 GB, repeatable)

1. Choose a legally usable test set under 4 GB containing representative CLS types (one archive each for SREP, XTool, Magic2/LOLZ if available), with fixed input hashes and known output manifest. Preserve exact helper DLL/EXE versions and configs. Keep source read-only.
2. Use a dedicated clean prefix and fixed Wine build, macOS power mode, output volume, free-space headroom, and no unrelated heavy workload. Record machine/chip, macOS, Rosetta, Wine build, and RAM. Do not compare across changed inputs or helper versions.
3. Separate **cold** (fresh process/prefix where appropriate) from **warm** runs. Run baseline at least 3 times; randomize variant order. Reboot is not required, but note thermal/load state. Verify every output hash after each run.
4. Variants one factor at a time: baseline; thread setting; memory cap; temp on same-volume SSD; bounded RAM disk; warm helper; candidate native open codec. Do not combine changes until individual effects are known.
5. Capture timestamps and per-process/per-thread CPU, RSS/peak memory, process tree, input bytes read, output bytes written, temp-file sizes and read/write bytes, disk throughput/latency, page faults/swap, and Wine logs. On macOS use Activity Monitor/`ps` sampling plus `iostat`/`fs_usage` or Instruments; sampling should include `unarc`, `magic2`, `srep`, `xtool`, wineserver. Track output growth and source read offsets, but recognize solid-block stalls can be normal.
6. Report wall time, CPU-seconds per worker, throughput (input and output MB/s), peak RSS/swap, total temp I/O and hash pass. Compare medians and spread; retain raw timestamped logs. Reject any speedup that fails hashes or changes extracted file list.

## Evidence and limits

Local evidence: `/tmp/carx-lab/RUNNING.md`, `reproduce.sh`, `unarcx-global.c`, `cellar-README.md`, and lab evidence logs. The working reproduction uses a 32-bit Windows driver, a 256-byte `Init_MapFile_` mapping carrying `Global\`, and exact original helpers; this is a compatibility prerequisite, not a speed optimization. The lab notes report four decoder threads in magic2 at an observation point, heavy host swapping, and long flat output periods; one run cannot attribute total time quantitatively. Search service was unavailable, so upstream project/license claims must be checked against exact source releases before implementation or distribution.
