# 0044. What frame generation may learn from, and what it may ship

## Status

Accepted, 2026-10-27.

## Context

The research drew on several kinds of sources:
- a local static analysis of a commercial Windows frame generator;
- AMD FidelityFX SDK sources (MIT);
- DXMT sources (MIT up to v0.80, LGPL after);
- Practical-RIFE (MIT, weights declared MIT);
- public documents on DLSS, XeSS and others.

D3DMetal is under the Game Porting Toolkit licence, which forbids reverse engineering.

## Decision

- **The static analysis** guides architecture ideas only: flow at reduced resolution, confidence-weighted hypotheses, separate capture and present queues. Its content stays out of the public repository, and no code, shader, weight or constant from it is used.
- **FidelityFX** code may be read and adapted. Any file derived from it keeps AMD's notice.
- **DXMT** v0.80 headers may be read to learn interfaces (NGX parameter layout). No DXMT code is copied.
- **D3DMetal and other GPTK binaries** are never inspected. Only public API calls made in the game process are observed.
- **Practical-RIFE 4.25.lite** may ship as the first network, with its MIT notice. Its training data is undocumented: noted as a risk, and removed by a Cartouche-trained network.
- Strings read from the D3DMetal binary during research were removed from the research notes.

## Alternatives rejected

- Publishing the static analysis or deriving code from it.
- Learning the NGX parameter layout of D3DMetal's shim from its binary.

## Consequences

Contributors know which sources are safe. THIRD-PARTY-LICENSES must list RIFE, and FidelityFX if code is ever derived from it, before any release that ships them.
