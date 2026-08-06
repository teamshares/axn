# A/B-testing a guard change: procedure and pitfalls

This file holds mechanism and case studies only. The rule each section backs is stated in
`AGENTS.md`; if you find yourself wanting to add a new rule here instead of there, put it in
`AGENTS.md` and link back.

## Why this exists

A spec suite can only tell you the current tree is self-consistent; running today's assertions
against yesterday's `lib/` tells you which behaviours a change actually moved.

## Procedure

```sh
git worktree add -f --detach /tmp/axn-ab <OLDER_SHA>
cp spec/axn/core/validations/<the_spec>.rb /tmp/axn-ab/spec/axn/core/validations/
(cd /tmp/axn-ab && bundle exec rspec spec/axn/core/validations/<the_spec>.rb)
git worktree remove --force /tmp/axn-ab
```

Read the differences one by one: an example that fails THERE and passes here is a behaviour this
change moved, and an unexpected one is a regression. **An example that fails in BOTH is a broken
fixture, not a finding** — that distinction is the one that repeatedly mattered, because a stale
fixture reads exactly like a regression until you check the other side. A mixed result is normal
and is the useful case: only the examples whose behaviour the change actually moved flip.

## Pitfalls

`bundle exec` needs no `bundle install` in the worktree while `Gemfile.lock` is unchanged between
the two commits — the gems are already resolved. If the older commit's lockfile DOES differ,
install there first; otherwise every example fails for the same uninteresting reason, which is the
commonest cause of a fails-in-both reading.

**Run each side from inside its own checkout**, as above — never require the other tree's files
from this one. axn's internal requires are non-relative (`require "axn/…"`), so they resolve
against `$LOAD_PATH`, which under this checkout's bundle points back here: only the outermost
`require_relative` lands in the other tree and everything beneath it is silently THIS tree's code.
Between nearby refs that succeeds and reports today's behaviour for both sides — a zero delta that
looks like "the change had no effect" — while between distant ones it surfaces as a confusing
`LoadError` for a file the other tree never had. The benchmark harness hard-fails on the mismatch
(`benchmark/support/axn_scenarios.rb` compares `Object.const_source_location("Axn::VERSION")`
against its own root), so a profiling A/B cannot make this mistake quietly; a hand-rolled script
that loads `lib/axn` some other way still can.
