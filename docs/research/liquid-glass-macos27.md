# Liquid Glass refinement — macOS 27

Reviewed 2026-10-23 against the installed Xcode 27 SDK and Apple documentation.

- [Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/): system sidebar, scroll-edge, toolbar and interactive-glass refinements.
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials): reserve glass for controls/navigation; use standard materials for content.
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views): interactive custom controls and performance guidance.

The selected artwork remains the window's color source. Its saturation is reduced to 0.65 and its dark-mode opacity from 0.90 to 0.55. Search and the sidebar use untinted regular glass. The game inspector uses standard regular material. Panel shadows are smaller; secondary labels use system colors.

Round actions and Play/Install use interactive glass; solid/material fallbacks remain for older systems, reduced transparency and increased contrast. Custom action borders follow the system Show Borders setting. The bright Play glow and custom glass-button scale animation are removed.

Recent systems use native scroll-edge effects without the additional gradient mask. The older rendering path retains its fade. Column widths, grid gaps and panel placement are preserved.

This pass changes surfaces and controls. The sidebar remains Cartouche's existing custom column; adopting NavigationSplitView and the native toolbar is a separate structural step, not claimed by these changes.

## User correction and next proposal

The user rejected changing the library backdrop and the top fade. Original artwork saturation, dark/light opacity (0.90/0.28), the manual scroll fade and soft system edges were restored. Keep this appearance in subsequent work. The Settings update button and title-background fix remain.

Focus the next proposal on the actual navigation and inspector structure: native split-view sidebar plus inspector, with artwork extended behind their system glass; content cards retain a quiet hierarchy. Include the upper search/action area in the proposal, retaining the requested fade. Apple Landmarks is the primary implementation reference; macOS 27's sidebar behavior should be obtained from the system rather than recreated with fixed corner radii or painted highlights. This is a proposal, not an implemented native-column migration.

## Approved native scroll edge

The user selected Apple's glass fade and requested native macOS behavior. The first implementation registered the entire header, including alerts, with `safeAreaBar`. The user rejected its large blurred rectangle and abrupt lower edge.

The replacement uses a real window toolbar inside a NavigationStack. The title/count stays on the left; a flexible toolbar spacer pushes Add Games and an AppKit NSSearchField to the right. The search field uses the same width calculation as the game panel, with Add immediately to its left. Toolbar background visibility is left to macOS. Notices belong to the library's scroll content and no longer enlarge the toolbar's effect region.

After inspecting this version, the user specifically requested the earlier progressive cover fade. The scroll-position-driven opacity mask is therefore restored on recent macOS as well, with reduced-motion handling. The system soft edge remains enabled for Liquid Glass when transparency is allowed. The artwork backdrop remains at its restored settings. The custom sidebar and game panel have not been migrated to native split-view columns.

An attempted material overlay in the upper 72 points was rejected: its top edge was visible below the window toolbar. It has been removed. Add and Search retain their glass surfaces. Search uses the native rounded bezel and large control metrics inside its glass capsule; removing its bezel had caused a rectangular focus ring and overlapping search icon/text and was reversed.

## Final continuous fade, 2026-10-23

Apple's [scroll-view guidance](https://developer.apple.com/design/human-interface-guidelines/scroll-views) calls for one edge effect per view. The [WWDC26 AppKit session](https://developer.apple.com/videos/play/wwdc2026/289/) describes macOS 27 resolving automatic toolbar effects to a hard edge around free-floating text. A small standalone SwiftUI probe reproduced the sharp boundary with a real toolbar and with a controls-only safeAreaBar, despite requesting `.soft`. This is a finding for the installed SDK/OS combination, not a claim about every macOS release.

For the user's requested earlier appearance, Cartouche now uses a single scroll-driven opacity fade. The native toolbar backdrop and generated scroll-edge effects are hidden; there is no material rectangle over the covers. This is an explicit visual fallback, not Apple's variable-blur implementation. Native toolbar controls and their glass remain, and the original artwork backdrop is unchanged. Reduced Motion disables fade animation. The prototype shows a continuous transition into the same artwork-colored background.

The focused native search field was checked in the running app: typing CarX produces one result, the native clear action restores the library, the icon and text are separated, and the focus ring is rounded (`search-rounded-focus.png`). `continuous-fade-tests.log` passed 21 tests in three suites covering library states, Settings rendering, and integration actions. Settings Steam now uses one content heading and a separate compact integration group; update versions replace redundant explanatory copy, while explicit quit/update actions and confirmations remain.
