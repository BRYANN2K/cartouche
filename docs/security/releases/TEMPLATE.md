# Security review: <version>

Copy to `docs/security/releases/<version>.md` before running `make release-gate`. The gate fails while an item is unchecked or a sign-off line is empty.

## Diff review (security/out/<version>-<sha>/sensitive-changes.txt)
- [ ] Every changed file under Agent/, MCP/, Stores/, Installer/, Runners/, dylib/, the shims, packaging/ and .github/ read by a human.
- [ ] New agent tools: access level set, destructive ones need an approval that shows every argument.
- [ ] New file deletions stay inside Cartouche-owned folders or go to the Trash; no `$HOME`, standard folder or volume root.
- [ ] New downloads pinned by size and SHA-256, or signed, and https only.
- [ ] New processes start with an argv array, never a shell string.
- [ ] No new secret, token or path in logs or agent replies.
- [ ] New C in the Steam dylib: bounds-checked, ran under ASan/UBSan, fuzzed if it parses input.
- [ ] Workflow changes: no secret on hosted runners, no self-hosted runner on pull_request, actions pinned.

## AI review
Run Claude Code's security review on the release diff (`git diff <last tag>..HEAD`), paste the summary and how each finding was handled.

AI review: 

## Accepted findings (each with a reason and a date to revisit)

## Sign-off
Sign-off: 
