# Tasks

- [x] Publish the Wine release using the existing CI-built archive; preserve build provenance.
- [x] Pin the release URL, size and SHA-256 in runners.json and verify downloads. (implementation merged in 95b4e47).
- [x] Default new games to Cartouche Wine without changing explicit existing choices. (implementation merged in 95b4e47).
- [x] Original reason-line UI merged in 95b4e47; superseded by ADR 0027.
- [x] Hide unavailable backends and remove all panel/menu reason lines. (ADR 0027; 522d4fa.)
- [x] Show one Get More Graphics Backends… only when something is missing; lead to installing Cartouche Wine. (GraphicsMenu.swift.)
- [x] Preselect Cartouche Wine in onboarding and verify the amended UI scenarios. (d7b3404; OnboardingFlowTests.)
- [x] Serialize first boot per prefix; await boot and Wine-server success before launch. (implementation merged in 95b4e47).
- [x] Show setup status and logs; support cancellation, failure and retry (implementation merged in 95b4e47; real-hardware recovery check pending).
- [ ] Test every runner-sources delta scenario and record fresh evidence.
- [ ] Validate the published runner, first boot and backend choices on real hardware before marking integration complete.
