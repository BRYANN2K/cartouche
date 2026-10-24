# 0034. A failed direct unpack falls back to the original setup on Try Again

## Status

Accepted, 2026-10-21. Amends 0017. Verification mismatches stay under 0025 and 0026. Merged on 2026-10-21, pending build and live check.

## Context

For supported installers that unpack their data with their own helper programs, Cartouche extracts the parts itself instead of running setup (ADR 0017). Before this decision, a direct unpack that could not run (driver or innoextract missing, helpers not extracted) or that failed (a part, or placing the app section) left the job failed, with no path to the original setup.

## Decision

A direct unpack that cannot run or fails marks the job. Its message says that a retry runs the original setup under Wine, with its own helpers. Try Again, Recreate Prefix, every retry fix and the standard-method retry then drop the unpack plan and run setup in guided mode. The installer folder is never touched.

The fallback is never automatic. The user starts it with one of these actions.

## Alternatives rejected

- Fall back automatically: runs the installer's own programs without the user knowing, after a failure whose cause they have not seen.
- No fallback: the user must start again from Add Games and cannot reach the original setup from the failed job.

## Consequences

A failed direct unpack always has a way forward from the same job. The stopped-attempt cleanup removes the partial folder before the retry. The app end-to-end check of the fallback is still pending.
