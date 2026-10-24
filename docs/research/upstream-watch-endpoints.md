# P9 upstream watch: machine-readable endpoints

Checked: 2026-10-19 (all with WebFetch, unauthenticated).

## Question
Which unauthenticated endpoints give the latest version of six upstream sources, in what format, and what link goes in an issue? Also: does "create an issue" auto-create missing labels?

## Short answer
- Five of six have working JSON/VDF endpoints (NotProton, Steam, DXMT, Wine macOS, GPTK via Gcenx); CrossOver listing returned 403 to WebFetch, so use the product page or a tarball HEAD instead.
- GPTK: Apple page says "Game Porting Toolkit 4", but Gcenx cask/releases are still 3.0-3, so Apple's page text is the earlier signal, Gcenx is the usable build signal.
- Label auto-creation on issue create is not confirmed by the docs; create the label explicitly first.

## Findings

### 1. NotProton upstream
- Publishes real releases (not only tags). `GET https://api.github.com/repos/NotProtonNot/NotProton/releases` returned:
  `[{"tag_name":"v1.2.0","name":"1.2.0","html_url":"https://github.com/NotProtonNot/NotProton/releases/tag/v1.2.0","published_at":"2026-10-18T17:47:20Z","prerelease":false,"draft":false}, {"tag_name":"v1.1.9", ...}]`
- Version field: `.[0].tag_name` (strip leading `v`); `name` is the bare number. Better: `/releases/latest` (not fetched; standard endpoint, returns one object excluding drafts/prereleases).
- Tags endpoint also works: https://api.github.com/repos/NotProtonNot/NotProton/tags gives `v1.2.0`, `v1.1.9`, `v1.1.8`.
- Issue link: `html_url` of the release.

### 2. Mac Steam client
- Stable: https://client-update.steamstatic.com/steam_client_osx
- Beta: https://client-update.steamstatic.com/steam_client_publicbeta_osx
- Both reachable, content type octet-stream, VDF text. Hostname `client-update.steamstatic.com` confirmed. Mirror `https://cdn.cloudflare.steamstatic.com/client/steam_client_osx` returned the same data. The akamai host was not tested.
- Sample (stable):
  ```
  "osx"
  {
  	"version"		"1791918634"
  	"ostype"		"macos1015"
  	"tenfoot_images_all"
  	{ "file" "tenfoot_images_all.zip.86419c..." "size" "6582204" ... }
  ```
- Beta at check time: `"version" "1792192922"` (newer than stable 1791918634).
- Extract: first top-level `"version"` line, e.g. `grep -m1 '"version"' | sed 's/.*"\([0-9]*\)"$/\1/'`. Keys are tab-separated, so use a tab-tolerant regex. Version is a Unix timestamp (1791918634 = 2026-10-13 UTC).
- Issue link: no release page exists. Use the manifest URL itself, or https://store.steampowered.com/news/app/593110 (not fetched; not confirmed).

### 3. CodeWeavers CrossOver source
- Listing https://media.codeweavers.com/pub/crossover/source/ returned HTTP 403 to WebFetch. Whether it is plain HTML: not confirmed.
- Filename pattern confirmed from the product page https://www.codeweavers.com/crossover/source : `https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz` ("Download FOSS Code for CrossOver 26.3.0").
- The tarball URL exists (fetch started, aborted at the 10 MB limit), so a HEAD request on a guessed next version works as a probe.
- Suggested watch: scrape the product page for `crossover-sources-([0-9.]+)\.tar\.gz`. Fall back to the listing with a browser User-Agent (untested).
- Issue link: https://www.codeweavers.com/crossover/source

### 4. WineHQ macOS builds
- `https://dl.winehq.org/wine-builds/macosx/` today only has `pool/` and `download.html` (modified 2025-04-23). Its download.html still shows examples for Wine 5.x (.pkg and portable tarballs), so it is stale. Older than 12 months; do not use.
- Practical source: Gcenx builds. `GET https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases` returned:
  - `tag_name` `11.18`, published 2026-09-25, prerelease false; then 11.17 (2026-09-11), 11.16, 11.15, 11.14, 11.13.
  - Assets: `wine-devel-11.18-osx64.tar.xz`, `wine-staging-11.18-osx64.tar.xz`.
- Stable: no stable asset in the first 3 releases. Not confirmed where stable builds are published (possibly older release tags such as `10.0`); needs a check of more pages.
- Extract: `.[0].tag_name`; filter assets by `wine-(devel|staging)-<tag>-osx64.tar.xz`.
- Issue link: `https://github.com/Gcenx/macOS_Wine_builds/releases/tag/<tag>`
- "WineHQ links Gcenx" was not verified on the fetched page.

### 5. DXMT
- `GET https://api.github.com/repos/3Shain/dxmt/releases`: tags `v0.80` (2026-04-23), `v0.74` (2026-03-10), `v0.73` (2026-01-21). `name` is "Version 0.80". Asset: `dxmt-v0.80-builtin.tar.gz`.
- Tag format: `v<major>.<minor>` (two parts, minor numeric compare: 0.80 > 0.74).
- Extract `.[0].tag_name`. Issue link: `https://github.com/3Shain/dxmt/releases/tag/v0.80`.
- Latest release is about 6 months old.

### 6. Apple Game Porting Toolkit
- Apple page https://developer.apple.com/games/game-porting-toolkit/ (fetched 2026-10-19) says "Game Porting Toolkit 4" and mentions Metal 4 and a WWDC 2026 video. No release date on the page; copyright 2026.
- Gcenx cask raw URL `https://raw.githubusercontent.com/Gcenx/homebrew-wine/master/Casks/game-porting-toolkit.rb` works. Line: `version "3.0-3"`, url `https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-#{version}/game-porting-toolkit-#{version}.tar.xz`. It is Apple GPTK 3 repackaged, not 4.
- Gcenx releases: https://api.github.com/repos/Gcenx/game-porting-toolkit/releases : `Game-Porting-Toolkit-3.0-3` (2026-03-03), `-3.0-2`, `-3.0-1`, `-3.0` (2025-12-05). Asset `game-porting-toolkit-3.0-3.tar.xz`.
- `https://api.github.com/repos/apple/game-porting-toolkit/releases` returned `[]` (no releases). The repo is linked from the Apple page.
- Most reliable: for "is there a usable build", the Gcenx releases JSON (tag `Game-Porting-Toolkit-X-Y`; cask `version` is the same value, one raw-file fetch). For "Apple shipped a new major", grep the Apple page for `Game Porting Toolkit (\d+)`; this is fragile HTML text but is the earliest signal. Use both: alert on Apple page number change, track Gcenx for the build.
- Issue link: Apple page, plus the Gcenx release tag URL.

### 7. GitHub "create an issue" and labels
- Docs (https://docs.github.com/en/rest/issues/issues#create-an-issue) say only: `labels` = "Labels to associate with this issue." and "Only users with push access can set labels for new issues. Labels are silently dropped otherwise." They say nothing about creating missing labels.
- The labels docs (https://docs.github.com/en/rest/issues/labels) describe creation only via the separate "Create a label" endpoint.
- Not confirmed that missing labels are auto-created. A secondhand, old commit message (triagebot mirror) claims implicit creation; treat as unverified. Safe plan: `POST /repos/{owner}/{repo}/labels` first (a 422 `already_exists` is fine), or `gh label create --force`, then create the issue.
- Also: the workflow token needs `issues: write`.

## Open points
- CrossOver listing format (403 to WebFetch).
- Wine stable channel for macOS: where published.
- Steam akamai hostname untested; steamstatic confirmed.
- Real label-creation behavior needs a throwaway-repo test.
- Unauthenticated GitHub API is limited to 60 requests/hour per IP; in Actions use `GITHUB_TOKEN`.

## Sources
- https://api.github.com/repos/NotProtonNot/NotProton/releases (2026-10-19)
- https://api.github.com/repos/NotProtonNot/NotProton/tags (2026-10-19)
- https://client-update.steamstatic.com/steam_client_osx (2026-10-19)
- https://client-update.steamstatic.com/steam_client_publicbeta_osx (2026-10-19)
- https://cdn.cloudflare.steamstatic.com/client/steam_client_osx (2026-10-19)
- https://www.codeweavers.com/crossover/source (2026-10-19)
- https://media.codeweavers.com/pub/crossover/source/ (403, 2026-10-19)
- https://dl.winehq.org/wine-builds/macosx/ and https://dl.winehq.org/wine-builds/macosx/download.html (2026-10-19; content dated 2025-04, stale)
- https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases (2026-10-19)
- https://api.github.com/repos/3Shain/dxmt/releases (2026-10-19)
- https://developer.apple.com/games/game-porting-toolkit/ (2026-10-19)
- https://raw.githubusercontent.com/Gcenx/homebrew-wine/master/Casks/game-porting-toolkit.rb (2026-10-19)
- https://api.github.com/repos/Gcenx/game-porting-toolkit/releases (2026-10-19)
- https://api.github.com/repos/apple/game-porting-toolkit/releases (2026-10-19)
- https://docs.github.com/en/rest/issues/issues#create-an-issue (2026-10-19)
- https://docs.github.com/en/rest/issues/labels (2026-10-19)
