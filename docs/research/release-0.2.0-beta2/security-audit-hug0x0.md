# Independent audit by Hug0x0 (v0.1.2, 632437d) — triage

Source: https://github.com/Hug0x0/security-audits/tree/main/cartouche (README.md, DISCLOSURE.md), read 2026-11-05. Static review, nothing run. Private vulnerability reporting enabled on 2026-11-05 (#9).

| ID | Severity | Status | Plan |
|---|---|---|---|
| H-1 / FS-01 (#8) | High | Fixed in beta (c674a120) | Shipped with 0.2.0 |
| CI-01, STEAM-01, STEAM-02, NATIVE-01 | High / Medium | Withheld, to arrive privately | Triage on receipt |
| M-1 run_in_prefix argv hidden, cmd.exe reachable | Medium | Fixed (a437303d); Z: kept, residual risk in SECURITY.md | Before beta: show argv, refuse cmd/start/winebrowser |
| M-2 no hardened runtime | Medium | Open | After beta: `-o runtime` + entitlements, test injection paths |
| M-3 one Sparkle key in three CI systems | Medium | Mostly obsolete (local releases) | Verify no CI secret remains, document |
| M-4 self-hosted runner on PRs (dormant) | Medium | CI branch pending | Never self-hosted for pull_request |
| L-1 errors skip scrubber | Low | Fixed (b9500fb5) | Before beta |
| L-2 action log drops nested args | Low | Fixed (a098e42e) | Before beta |
| L-3 approval prompt gaps | Low | Fixed (886e0d28) | Before beta: sanitize, cap, rate-limit |
| L-4 retry_install without approval | Low | Fixed (301af29a) | Before beta |
| L-5 file-existence oracle | Low | Fixed (46667d1d) | Before beta: containment first |
| L-6 HTTP/socket DoS | Low | Open | Later |
| L-7 RetroArch UDP command port | Low | Open | Later |
| L-8 winetricks verb paths | Low | Fixed (bb232b84) | Before beta: `^[a-z0-9_=.]+$` |
| L-9 uninstall trusts game.json id | Low | Fixed (b6312069) | Before beta: validate id = folder name |
| L-10 CrossOver clone quarantine | Low | Open | Later |
| L-11 netplay lobby over HTTP | Low | Open | Later |
| L-12 tag bypass (Woodpecker) | Low | Obsolete (Woodpecker stopped) | Document |
| L-13 unpinned build tools | Low | Open | Later |
| L-14 Int traps, staging check | Low | Fixed (4d0cf942); 1 TiB extraction cap unchanged | Before beta |
| I-1..I-9 | Info | I-1, I-2, I-3 fixed in SECURITY.md; I-4..I-9 open | SECURITY.md accuracy (I-1, I-2, I-3) before beta; rest later |
