## Change

What problem does this solve, and what behavior changes?

## Tests

- Test files and cases added or extended:
- Result of `bash scripts/test.sh`:
- Hardware/manual results, including model/VID:PID, transport and macOS version (or explicitly state not tested):

## Required before merge

- [ ] Every feature addition or behavior change includes automated test code.
- [ ] Bug fixes include a regression test that fails before the fix and passes afterward (if applicable).
- [ ] The complete local test suite passes; no tests were weakened or skipped to pass.
- [ ] The latest `macOS tests` CI check passes and the branch is up to date with main.
- [ ] Tests do not change real devices, system settings or user data.
- [ ] Hardware verification limits and remaining risks are stated.

Feature/fix PRs without test code are not ready to merge, even when existing CI passes.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the requirements.
