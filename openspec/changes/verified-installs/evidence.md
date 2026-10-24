# Verification implementation evidence

Main 7f8773b merges phase/verify-ui. Library/Verification/GameVerification.swift defines GameVerificationPresenting and the full/sizes/notVerified presentation states. GameVerificationViews supplies badge/panel status, progress with Stop and the mismatch actions. Game actions expose Verify Files….

phase/verify-engine adds the live backend: GameVerificationCenter implements GameVerificationPresenting and is injected in App.swift with .environment(\.gameVerification, verification). InstallCenter.onVerificationMismatch surfaces a job's failed output check to the presenter.

Engine (Installer/OutputVerification.swift): VerificationOutcome and VerificationRecord keep verification state separate from installed state on the install record (InstalledGame.verification). verifyOutput gates setup, direct-unpack and import flows in InstallEngine before a game may be marked installed: a shipped manifest usable against the output is full, a clean unarc exit without a manifest is full-by-CRC, the script's --list-sizes file list is partial (verified sizes), no evidence is "Installed, not verified".

Fallback (ADR 0025/0026): InstallCenter.retryStandard reruns the shipped helpers with the original inputs (direct-unpack plan kept, externalUnpacker on), then drops the plan for the guided real installer under Wine as last resort; imports re-copy in place. InstallCenter.keepAnyway resumes via InstallEngine.resumeAfterMismatch, which keeps the not-verified outcome and writes verification-mismatch.log naming the files. Cancel leaves the job failed and unverified.

Later verification: Verify Files… reuses the recorded manifest path and file list after the installer folder is gone; a dropped .md5 file verifies the game against its own dir. Stop cancels the task and persists not verified. Hashing runs off the main actor with per-file progress.

Helper allowlist: InstallerKit/HelperAllowlist is the sha256 scaffold called from prepareUnpack; the list is empty, so every helper runs shipped under Wine. No corpus or verification data leaves the Mac; the byte-identical corpus regression stays a precondition for any future native replacement.

Tests: OutputVerificationTests (levels, supplied lists, unusable manifests, Stop), GameVerificationCenterTests (status, persistence, mismatch choices, fallback order, record retry), VerificationGateTests (direct-unpack manifest/CRC, sizes via --list-sizes, unavailable, import verify/retry) and InstallerKitTests VerificationKitTests (parseSizes, allowlist). The detection decision tree is approved by ADR 0028.
