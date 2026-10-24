# 0017. Installers with external unpackers

## Status

Accepted, 2026-10-20. 

## Context

Some multi-part installers delegate extraction to helper programs. Running the setup wrapper can fail even when the parts are readable.

## Decision

Add a Cartouche-owned unpacker driver that can extract supported .bin parts directly rather than executing setup.tmp or ISDone. Call this feature “installers with external unpackers”. Keep unknown formats on the normal installer path and report unsupported extraction clearly.

## Alternatives rejected

Do not assume every .bin file has the same format. Do not present setup-wrapper workarounds as direct extraction.

## Consequences

In progress. Main detects external unpackers and prepares Windows 10 and Visual C++ runtimes before setup; it still runs the setup program. The direct driver is not merged. CarX Street is the local test case, not a claim of general format coverage.
