# Positional tolerance in an `of:` bag — execution record

PRO-3225. Companion to `2026-08-27-positional-tolerance-in-an-of-bag-design.md` and `../plans/2026-08-27-positional-tolerance-in-an-of-bag.md`. What the spec got wrong, what the measurements changed, and the two methods worth reusing.

## What the spec got wrong

**Two writers into the `of:` bag, not one.** The spec framed the obstacle as the tolerance push in `_parse_field_validations`. `_apply_nil_skip_to_non_type_validators!` is a second writer: it merges `allow_nil: true` into every non-`type:` entry whenever the field's `type:` rejects nil — which is every *required* container field. Measured on the merge base, a required `expects :f, type: Array, of: Integer` stored `of: {klass: Integer, container: Array, allow_nil: true}`. Left alone, the runtime task would have made every required `of:` position silently tolerate nil elements. `:of` is now exempt from that pass, which is free: `OfValidator` has no nil verdict to suppress, because `validate_elements`/`validate_entries` both `return unless value.is_a?(…)` and no-op on a nil field structurally.

**Relocating the record does not stop it reaching the bag.** Moving the pair to the top level of `validations` puts it in exactly the tier `validates` hands every validator: ActiveModel builds a validator's options as `declaration_defaults.merge(entry)`. So a field's `optional:` arrived back inside the bag `OfValidator` reads, and `of: String, optional: true` accepted `[nil]` — the invariant inverted, with a green suite. The stored bag was clean, which is what the relocation's own tests checked; the validator never sees the stored bag. The fix is that `_canonicalize_bag_tolerance!` states both tolerance keys explicitly, `false` included, so AM's per-key merge is always overridden by the position's own answer. That explicit `false` is the anti-leak device, and it is why every `of:` entry now carries two keys no author wrote.

**A bag's `allow_blank: false` does not mean "rejects blank".** At a field, an explicit `allow_blank: false` sits beside a default `presence:` check, so it does imply the empty value is rejected. A bag has no default presence check. Reading the normalized `false` as a signal made an untolerant bag carrying `length: { maximum: N }` emit `minLength: 1` while the runtime accepts `""`. Only a *true* tolerance is a signal.

**`except_on:` is version-dependent, and a design-phase probe missed it.** The probe ran `ruby -e 'require "active_model"'` outside bundler and resolved activemodel 8.1.3.1 from system gems rather than the locked 7.2.2.2. `except_on` joined AM's shared-option list after 7.2, and the gemspec allows `>= 7.2`, so both are supported configurations and the hole's shape differs between them. **Always `bundle exec`.**

**Four of five positions is not "every position".** The `except_on:` guard was landed at a field entry, an element bag, both map axes and a nested bag — and missed a raw shape member, the one position whose admission set varies by ActiveModel version. Three shipped statements said "every position" while one was open. A guard claiming to mirror `strict:` has to be structurally identical to it, not merely agree with it in the cases someone thought to test.

## Two methods worth reusing

**The differential matrix.** To prove a canonicalization change is behaviour-preserving, do not read the diff and do not trust a green suite. Build a matrix of declarations — every validator in both its scalar and hash spelling, gated entries, `allow_empty:`, the option under change at every position, shape members, subfields, exposures — and capture, for each: the input schema, the output schema, every config's `optional?`, and the runtime verdict over a fixed payload list. Run it on the merge base in a throwaway worktree and on HEAD, and diff. Here 34 declarations × 14 payloads diffed in *nothing* but two intended message changes. That is evidence; "the suite passes" is not, because the suite only covers what someone already thought to pin.

**The cross-version probe.** Where a gem supports a version range but CI pins one version, a guard derived from that dependency's internals can be correct on one version and a no-op on another with no test signalling it. Write a throwaway `Gemfile.<variant>` pinning the other end of the range, `bundle install`, re-run the specific probes under `BUNDLE_GEMFILE=`, then delete it. Cheap, and the only way to see this class of defect.

## What was deferred, and on what grounds

"It predates the branch" is not a reason to leave a bug — it says who introduced it, not whether it is worth fixing. Each deferral below rests on a stated reason that is not provenance:

| deferred | ticket | why not here |
| -- | -- | -- |
| `presence:` beside an `allow_nil:`-only tolerance is refused, though `allow_nil:` excuses only nil | PRO-3263 | This branch made that rule SHARED across four positions. Narrowing it belongs in one place, applying to all four at once; doing it at the bag alone would break the consistency this work establishes. |
| A keys axis whose class is not its own wire form emits no `propertyNames`, so the document accepts keys the runtime rejects | PRO-3264 | Needs a decision about what an input schema means for a map serving both JSON and Ruby callers. Untracked before this — none of PRO-3240's children cover it. |
| `allow_blank:` beside `format:`/`inclusion:` — outbound, the document refuses the blank the runtime accepts | PRO-3244 | One central decision with three costed options; it lands at every position at once because the bag projects through the field's own emitters. A version keyed to `of:` would be a second rule for one fact. |
| A class whose `blank?` contradicts its own contents skips a field's validators | — | Does not reproduce at a position. At a field it is ActiveModel's own preflight, and the value is lying about itself; defending against that means not reading `blank?` at all. |

The line the branch actually held: fix every divergence it INTRODUCED, plus every one its own feature made newly REACHABLE — the nil-key wire form is the second kind, which is why `admit_empty_wire_key!` exists and is scoped to exactly it.

Note for future citations: PRO-3240 was split and closed. The blank-tolerance class is PRO-3244, `numericality:` on a String position is PRO-3245, and the broad-token fallback is PRO-3246. Three replies on PR #257 cited PRO-3240 for something it no longer carries.

## Follow-ups this branch did not take

- **An ActiveModel dimension in the CI matrix.** The matrix varies Ruby 3.2/3.3/3.4 and pins one ActiveModel. `except_on:` is the proof that AM minor versions change the shared-option list, so a contract guard can be right on one and inert on another silently. Two defects on this branch were in that class; one was found only by hand.
- **A shared predicate behind the two `key == :of` sites.** `nil_tolerant_validation?`'s case and the nil-skip exemption cite the identical fact — `OfValidator` structurally never renders a verdict on a nil field — so they would have to co-change. Something like `Base.of_entry_never_verdicts_on_nil?` would make their agreement a property of the code rather than a coincidence.
- **`shape:`'s identical bag contamination.** A `shape:` bag also receives `allow_nil: true` from the nil-skip, and `ShapeValidator#validate_each` reads it as a field-level skip — the same structure as the `OfValidator` line this branch removed. Inert today, because `shape:` gains no positional tolerance here. Any future ticket giving `shape:` positional tolerance must close it first.
