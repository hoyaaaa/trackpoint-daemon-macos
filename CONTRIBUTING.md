# Contributing

Thank you for helping improve TrackPointD.

## Tests are required

**Every feature addition and behavior change, including bug fixes, must include
automated test code for the changed behavior. All tests must pass before merge.**

- Add or extend a test that exercises the production behavior. For bug fixes,
  include a regression test that fails before the fix and passes afterward.
- Cover the expected result and relevant failure/boundary cases. Do not weaken,
  remove or skip tests just to get a passing result.
- Run the complete suite on macOS before submitting or updating the PR:

  ```bash
  bash scripts/test.sh
  ```

- In the PR, list the test files/cases and report the command's result. The
  required GitHub Actions `macOS tests` check must pass on the latest changes,
  and the branch must be up to date with main. The CI requirement applies to
  everyone, including the maintainer.

A feature or bug-fix PR without test code is not ready to merge, even if the
existing CI suite passes. Passing existing tests alone does not prove the new
behavior is tested. Documentation-only changes do not require behavior tests.

Use the existing dependency-free test setup. See [the coverage matrix and test
boundaries](tests/README.md). Tests must not inject input, change real device or
system settings, or modify the user's app/preferences. Intercept system effects
and use isolated temporary state.

## Hardware verification

Automated tests do not replace physical-device checks. For device-specific
changes, report the keyboard model/VID:PID, connection type, macOS version and
manual test results. Clearly mark anything not tested on physical hardware;
Compact support remains experimental until verified.

## Review and merge

`@hoyaaaa` owns review of all files. Contributor PRs need owner approval; the
owner may directly merge their own PR after CI passes. New commits dismiss stale
approvals. No one may bypass the required test check.
