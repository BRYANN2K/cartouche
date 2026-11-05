# CodeQL triage, 0.2.0-beta.1 (PR #10)

31 open alerts on `refs/pull/10/merge`, triaged 2026-11-05.

## Threat model

- `dylib/` runs inside the user's own Steam client, as that user. It is not setuid and crosses no privilege boundary.
- Its environment (`HOME`, `CARTOUCHE_SIG`) is set by the same user or by Cartouche. Anyone who controls it already runs code as that user.
- The files it reads sit in that user's home and are written by Cartouche or Steam as that user.
- `fuzz/` harnesses run on a developer's machine or a CI runner. `qa/mocks/` is a local test server.

## Fixed in code

| # | Rule | Location | Source | Verdict | Fix |
|---|------|----------|--------|---------|-----|
| 5, 6, 7 | cpp/suspicious-pointer-scaling | dylib/core/macho.c:182, 217, 314 | Load commands of a loaded Mach-O image | False positive (`sc + 1` on a `segment_command_64 *` is the intended step to its sections), hardened | Sections located as `(const uint8_t *)sc + sizeof(*sc)`. Same address, no type confusion for the checker. |
| 10 | cpp/uncontrolled-allocation-size | dylib/util/peicon.c:233 | Sizes read with `fread` from a game's PE file | Already bounded (`payload` capped at `NP_PE_MAX_ICO`, at most 64 images), hardened | `malloc` guarded by an explicit `total` ceiling the checker can see. |
| 8, 9 | cpp/world-writable-file-creation | fuzz/fuzz.h:38, fuzz/fuzz_libexport.c:51 | Fuzz scratch files | True positive (default `fopen` mode 0666 before umask) | New `fz_create`: `open(..., O_CREAT, 0600)` + `fdopen`. |
| 28 | cpp/path-injection | dylib/util/log.c:82 | `HOME` | False positive for `HOME`. Real weakness in the fallback: with no home it logged to `/tmp/Library/Logs/...`, a shared directory another local user could pre-seed with a symlink | No home now means no log file. |
| 1, 2 | py/path-injection | qa/mocks/fixtures.py:639-640 | Store name from the mock server's request path | Already allowlisted by `server.py` (`STORES`), hardened | `store_games` checks the same allowlist itself. |

## False positives

| # | Rule | Location | Source | Justification |
|---|------|----------|--------|---------------|
| 27 | cpp/path-injection | dylib/core/loader.c:179 | `CARTOUCHE_SIG` or `HOME` | Signature DB path chosen by the same user who launches Steam with the dylib. No privilege boundary. |
| 26 | cpp/path-injection | dylib/feats/libexport.c:150 | `HOME` | Reads the user's own `~/Library/Application Support/Steam/config/loginusers.vdf`. |
| 25 | cpp/path-injection | dylib/feats/libexport.c:347 | `HOME` | Writes under the user's own support dir, via `mkstemp` + `rename`, mode 0600, symlinked target refused. |
| 24 | cpp/path-injection | dylib/feats/steaminstall.inc:7 | `HOME` | Fixed file names under the user's support dir, opened `O_NOFOLLOW`, owner and size checked. |
| 20, 21, 22, 23 | cpp/path-injection | dylib/feats/compat.c:698, 709 | `HOME` | Tool list paths are fixed names under the user's own support dir. |
| 14-19 | cpp/path-injection | dylib/feats/compat.c:747-771 | `HOME` + tool names read with `fgets` from the tool list | Names pass `is_tool_name` (Cartouche prefix, `[A-Za-z0-9._-]` only), so each is one path component under `compatibilitytools.d`. |
| 13 | cpp/path-injection | dylib/feats/compat.c:790 | `HOME` + validated tool name | Same validated single component under the user's own Steam tools dir. |
| 11, 12 | cpp/path-injection | dylib/feats/compat.c:1057, 1059 | `HOME` | Requests file is a fixed name in the user's support dir. Its lines are validated (numeric appid, `is_tool_name`). |
| 3, 4 | cpp/system-data-exposure | dylib/feats/compat.c:107 | `getenv("HOME")`, via field-insensitive taint on `tool_entry_t` | The bytes written are tool list fields and fixed text, not env data, into the user's own 0644 files. Nothing leaves the user. |
| 32, 33 (were 29, 30) | cpp/path-injection | fuzz/fuzz_libexport.c:51, fuzz/fuzz.h:46 | `TMPDIR` | Scratch path inside a fresh `mkdtemp` dir under the developer's own temp dir. Test-only code. |
| 31 | cpp/path-injection | fuzz/replay.c:10 | `argv` | The replay tool's job is to read the files named on its command line. Test-only code. |

All the false positives above, and the HOME part of 28, were dismissed on GitHub on 2026-11-05 as "false positive", each with its one-line reason.
