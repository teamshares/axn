# Contributing to Axn

Axn is open source and contributions from the community are encouraged!
No contribution is too small.

Please consider:

* adding a feature
* squashing a bug
* writing documentation
* reporting an issue
* fixing a typo

## How do I contribute?

For the best chance of having your changes merged, please:

1. [Fork](https://github.com/teamshares/axn/fork) the project.
2. [Write](http://en.wikipedia.org/wiki/Test-driven_development) a failing test.
3. [Commit](http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html) changes that fix the tests.
4. [Submit](https://github.com/teamshares/axn/pulls) a pull request with *at least* one animated GIF.
5. Be patient.

## Bug Reports

If you are experiencing unexpected behavior and, after having read [our documentation](https://teamshares.github.io/axn/), are convinced this behavior is a bug, please:

1. [Search](https://github.com/teamshares/axn/issues) existing issues.
2. Collect enough information to reproduce the issue:
  * Axn version
  * Ruby version
  * Rails version (if applicable)
  * Specific setup conditions
  * Description of expected behavior
  * Description of actual behavior
3. [Submit](https://github.com/teamshares/axn/issues/new) an issue.
4. Be patient.

## Releasing

Maintainers only. `rake release` runs `verify` (main specs, RuboCop specs, Rails specs, RuboCop, `verify_async`), builds the gem, runs the allocation gate, then tags, pushes, `gem push`es, and records this version's benchmark baseline.

* **`verify_async` needs a local Redis**, and no CI job covers it — a green PR says nothing about it.
* `gem push` requires MFA; have your OTP to hand.
* The gate (`rake benchmark:check`) exits non-zero when any scenario allocates 3% over the baseline, aborting the release **before** anything is pushed. Baselines live in the gitignored `tmp/benchmark_reports/`, so they are per-machine: a fresh clone has none and the gate no-ops rather than gating on numbers it cannot compare. Release from the machine holding the previous baseline, or the gate tells you nothing.
* **Accepting a known regression:** review it, write it down (a ticket, plus the CHANGELOG when a consumer would notice), then `rake benchmark:accept` to record the current numbers as the baseline, then release. It is not a way to quiet a red gate — whatever you accept is what every later release is measured against, so an unexamined acceptance silently raises the floor for everyone after you.
