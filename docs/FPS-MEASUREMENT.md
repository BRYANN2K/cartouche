# FPS measurement: accuracy and overhead

The frame counter (`fps-counter/fps_counter.m`, injected into the game process) hooks
`-[CAMetalLayer nextDrawable]`, which D3DMetal, DXMT and DXVK-through-MoltenVK all take
their drawables from, so one hook counts presented frames for every backend. This file
says how the measurement is validated and how its overhead is measured.

## What gets recorded

One line per wall second goes to `samples-<pid>` in the launch's folder, starting one
second after the first presented frame: `<unix time> <frames> <frontmost> <width>
<height>`. Empty seconds (a pause, a stall) still get a line with 0 frames.

`PlayStats` (`app/Sources/NotProtonApp/Performance/PlayStats.swift`) counts a second only
when all of these hold:

- at least 30 s since the first sample (warm-up: shader compiles, asset streaming),
- `frontmost` (the game's NSApp is active, or the process has no NSApp),
- `frames >= 5` (below that is a loading screen or a stall).

A session's average is counted frames / counted seconds; the 1% low is the mean of the
slowest 1% of counted seconds. Because a line always covers a whole second and the first
line only lands after warm-up anyway, partial seconds never enter the numbers.

## Accuracy checks

- `make fps-counter-tests`: the Metal test app (`fps-counter/tests/present.m`) presents a
  scene locked at 60 fps for 6 s with the counter inserted, on both slices. Every whole
  second must count 60 ± 1 and the frame count must match the presented count.
- `make fps-counter-bench` (manual, ~15 min): the same scene for 300 s; averaged the way
  the app averages, it must read 59–61 fps.
- `FrameTimingTests` (Swift): synthetic frame-time series run through bucketing,
  `PlayStats.counted` and `PlayStats.measure` — locked and jittered rates, non-integer
  rates within one frame, warm-up, a mid-run pause, background time, and the 1% low.
- Per-backend run in a real game: **needs maintainer**. Install the counter through
  Steam Play Setup, pick a game with an in-game limiter at 60 fps (V-Sync off, static
  spot), play 5 minutes per backend, then Compare Setups should read 59–61 for each.
  Steps are in `openspec/changes/archive/2026-10-19-p8-performance-tracking/evidence.md`.

## Overhead measurement procedure

Counter work per frame is one atomic increment plus a one-second writer thread, so the
expected cost is under 1%. Two measurements back that:

1. **Synthetic bench** — `make fps-counter-bench` runs `fps-counter/tests/bench.sh`. The
   test app's `bench` mode renders plus does ~8 ms of CPU work per frame so the rate sits
   below display pacing. After one warm-up run, it takes 5 alternating runs of 10 s with
   and without the counter per slice and reports the difference; the check fails if it
   is not under 1%. Latest numbers are in the change's `evidence/fps-counter-bench.txt`
   (+0.00% arm64, +0.02% x86_64 under Rosetta).
2. **Real game** — **needs maintainer**: use a game with a built-in benchmark (e.g.
   Shadow of the Tomb Raider). Run it 3 times with `CARTOUCHE_FPS=0 %command%` in the
   game's launch options, 3 times without, and compare the benchmark's own averages;
   they must differ by less than 1%.

## Limits

- wined3d draws through OpenGL, not CAMetalLayer, so it records play time but no FPS.
- A runner whose loader refuses the injected library is marked `measure=refused`: the
  session keeps its play time, the panel shows "FPS can't be measured with this runner".
- The best-setup tag only applies once a setup has at least 10 minutes of measured play
  across at least 2 sessions; ordering falls to the 1% low, the longer sample and the
  more recent session on a tie.
