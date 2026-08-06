# Error paths: case studies and mechanism

This file holds mechanism and case studies only. The rule each section backs is stated in
`AGENTS.md`; if you find yourself wanting to add a new rule here instead of there, put it in
`AGENTS.md` and link back.

## `best_effort`'s escape policy

`Axn::Extensions.best_effort` guards a side channel — a log line, a span update, a metrics block,
an error report — and swallows `StandardError` plus `SWALLOWABLE_BEYOND_STANDARD_ERROR`.
`standard_errors_only: true` lets a non-`StandardError` escape instead of being swallowed, but only
when doing so is genuinely better — both that no side effect is already committed at that point,
and that an executor boundary will settle the escape into a reported result rather than re-raising.

Two contrasting cases:

- Resolving a `model:` record qualifies: it runs inside its own action's validation, so a runaway
  finder surfaces as a reported exception result naming the real stack instead of a misleading
  "can't be blank".
- A post-fan-out `on_enqueue_all` callback does not: jobs are already enqueued and the orchestrator
  is itself an async job whose adapter re-raises an exception outcome, so an escape gets the batch
  enqueued twice.

The flag is applied at exactly one layer per callable — the layer that invokes it
(`Handlers::Invoker` owns the policy for everything it dispatches, so callbacks/matchers/messages
must not re-guard on top of it). Behavior never depends on which error class was raised: if
`StandardError` is swallowed and skipped at some site, a `SystemStackError` must be too.

`SWALLOWABLE_BEYOND_STANDARD_ERROR` is also what `Core::Executor` may settle onto a result (via
`Extensions.swallowable?`) — the single answer to "what will axn ever swallow." It's an allowlist,
widened only for a class that's unambiguously a fault in the code being run: the non-`StandardError`
set is open-ended (any gem can define a direct `Exception` subclass), and members like
`Timeout::ExitException` and `ActiveSupport::ErrorReporter::UnexpectedError` exist precisely so
nothing swallows them. Absorbing one silently breaks whatever it signals, which is far harder to
trace than an unrecognized bug escaping `.call`.

## Don't dispatch to caller methods while reporting a failure

Separate the caller code a walk **requires** from caller code invoked while **reporting** a
failure. The first is unavoidable — rendering a value calls its `to_s`/`as_json`, walking a
container calls its `each` — and a value that lies there changes what we decide, which is the
caller's own problem. The second is different in kind: an `inspect`, a `class`, an `is_a?`, or a
`-@` called to build the message can raise and *replace* the failure with the caller's exception,
and if that exception is outside `StandardError` it escapes the adapter's `rescue` — reinstating
exactly what the error existed to prevent.

So in a serialization or reflection error path, derive what the message needs without dispatching:
describe a value by `Object.instance_method(:class).bind_call(it)` rather than `it.class` or
`it.inspect`, and write type tests as `case`/`when` (`Module#===` is a C-level check) rather than
`is_a?`, which a value can override to route around a guard.

Eight layers hold this property: `Internal::Reflection::Values`, `Internal::Reflection::PropertyNames`,
`Internal::ShapeGraph`, `Internal::NativeMethods`, `Internal::Text`, `Internal::Rendering`,
`Axn::Extensions`, and the contract's declaration walk — including the option-container copy
`Internal::ShapeGraph` owns, where `Kernel#dup` and `Hash#each` are BOUND rather than dispatched, so
simplifying `Hash#each` back to a plain `.each` reopens an aliased contract (a bag is copied
entry-wise whatever its class); the bound `dup` is belt-and-braces, since an Array owning `dup` is
refused before the copy is attempted.

Dispatch on caller *data* (as opposed to error-path/reporting internals) is a different question,
and is fine when the dispatch **is** the work:

- The runtime redaction walk type-tests caller data (`is_a?`, `dup`) on every logged call.
- `Array(klass)` dispatches `to_a` on a caller value.
- `shape_validator` reports `got #{source.class}`.
- `subfield_contradictions` lists declared type branches with `#inspect`.

Two more are the projection's own work, both in `Internal::Reflection::Schema` (deliberately not
one of the eight layers above): `properties[config.field] =` IS the merge rule (one Hash key means
"two routes, one property, legal"), and `required << config.field.to_s` renders the name JSON will
carry — so a declared name whose `eql?` or `to_s` raises has no property map, and the emitter says
so, exactly as a value whose `to_s` raises cannot be rendered. `Internal::Reflection::Values.canonical_wire_key`
reads a String's or Symbol's rendering without dispatching for the same reason the rules do — it is
their input, so a dispatch there is a dispatch inside a verdict — and dispatches `to_s` only for a
name that is neither, where rendering it is the only way to know what property it names.

## Don't build a guard that depends on foreign behaviour being honest

Verifying that a caller's object BEHAVES is unbounded — the body is arbitrary code, so every round
of verification is defeated by the next case. Two on one PR:

- An option container was copied and the copy compared, first by elements (defeated by a
  duplication hook that dropped a derived membership index) and then by asking the copy `include?`
  about each element (defeated by a hook that dropped only the index of accepted non-elements, since
  membership is not enumerable from outside).
- A contract failure was renamed and re-raised on the argument that having been raised once made a
  redispatch safe (defeated by an `#exception` answering itself the first time and raising the
  second, because renaming CLONES and `raise` then asks the clone).

Ask ownership instead — `Internal::NativeMethods`, reading owners out of the method table rather
than running the object — and take a simple honest fallback when the object is not native: refuse
the container (`freeze` it is the documented escape), report axn's own error with the original as
`cause`. A bounded rule that over-rejects slightly beats an unbounded verification.

But a bounded rule can still be scoped WRONG, and the container half was, twice over: owning the
duplication hooks is not what makes a copy faithful (the copy's answers must be determined by the
state `dup` copies faithfully — the elements — which holds only where the answers are Ruby's own),
and the lookup has to go where the answer will be read. So `own_array_methods` asks for everything
the container answers with, through its SINGLETON CLASS's ancestry (one walk over singleton
methods, extended modules and the class's own), because a consumer asks the ORIGINAL and a copy
carries no singleton. The exception half keeps a named set and an object lookup for a different
question — what raising will DISPATCH: `clone` copies the singleton class and `raise` asks the
object it is handed, while `dup` looks its hooks up on the copy's class.

## Rendering declared names and composed messages

Every layer that writes a declared NAME into prose routes it through
`PropertyNames.inspect_field_name`/`renderable_label` — the contract's declaration errors,
`shape_validator`, `subfield_contradictions`, `call_logger` — so no message renders a name by
running the name's own code.

Not running the offender's code is only half of what prose needs, because the bytes it hands back
are foreign too: a message axn builds is UTF-8, so joining a String that has no UTF-8-compatible
rendering to one raises `Encoding::CompatibilityError` from the reporting itself — which is why
those layers RENDER what they write (`renderable_label`: an ASCII string is byte-identical, another
encoding reads as its text, unrenderable bytes come back escaped), and why a CLASS written into a
message goes through the one seam that composes both halves
(`PropertyNames.renderable_class_name`/`renderable_module_name` over `Internal::ClassName`) — a
constant may hold non-UTF-8 bytes, so naming a class destroyed the report from inside the "a name of
class …" fallback the name rules escape TO, and from `Axn::Tools.validate_contracts!` naming a tool.

A guarded dispatch and a rendered result are two obligations, and every site that met one of them by
hand met only that one. The byte primitive lives at the BOTTOM of the gem (`Internal::Text`, zero
requires) for exactly this reason: `Internal::Reflection::Values`' colliding-key report and both
`UnserializableValue#message` and `Axn::Async::UnserializableArgument#message` sit in the files the
renderer is itself built on, so a primitive any higher is out of their reach, and one at the bottom
is what lets them compose both halves like every other layer — as `Axn::Extensions.best_effort`
does, from a file that requires none of the reflection stack.

That property is not a property of the guard AROUND one step: `PropertyNames.attributions` rescues
the provenance WALK, so everything the failure path then does with the walk's result — the path
lookup, the wording choice, each name written into the message — has to dispatch nothing itself,
which is why `same_declared_name?` (identity, or a bound `String#==`) replaced `Array#==` in the
lookup and `==` in the contract's wording choice, and why the collision walk canonicalizes each
emitted name ONCE and reuses it wherever the path is written. Nor is a guard that only counts
exempt: the size budget keys a wire key by `wire_key_segment` (a plain copy) and a member name by
`property_segment` (a bound intern), never by handing the name to a Hash and letting its own
`hash`/`eql?` answer axn's question.

Where a dispatch to reach the unrenderable check is unavoidable, ask ONCE: canonicalizing a name to
reach the check and canonicalizing again inside it let a second, different answer overturn a
verdict already reached, and the schema then advertised a property the contract does not have — the
same bytes being REJECTED under a name that renders them honestly, since `JSON.generate` asks a
key's own `to_s` as well and emits whatever the name last claimed. A guard defeated by exactly the
object it exists to catch is the shape to watch for.

The specific regression: a subclass holding `"other"` and rendering `"dup"` passed the collision
rules beside a `:dup` field and then emitted `"dup"` twice, and a plain String carrying a singleton
`to_s` needed no second declaration at all, since the emitter's `required` list named a property its
`properties` map does not define — because `JSON.generate` renders a Hash key through its `to_s`, so
a name whose rendering disagrees with its bytes is judged as one property and emitted as another. So
a declared name that renders through code of its own is REFUSED (`NativeMethods.native_name_rendering?`
— a Symbol can carry no override, a String must not own `to_s`), which is what makes judging the
bytes sound rather than arbitrary, and every artifact reads the one name one way
(`Schema.required_key`). Where three readers pick between two candidate renderings, no choice of
candidate is a fix; only removing the second candidate is.

Caller data is a different category from an error path: there the dispatch IS the work (rendering a
value requires its `to_s`), and a value that lies degrades a log line or masks more than necessary.
But being inside a guard is not what makes that safe, and `best_effort` is the counterexample: it
built its warning from the exception it had just caught — that exception's class name, its message,
its backtrace — so an exception whose `#message` raises, or an ordinary one whose STORED message
holds bytes with no UTF-8 rendering, escaped through the very code meant to contain it, was absorbed
one layer out, and replaced the settled outcome, leaving `result.exception` naming the reporting
failure instead of the caller's `InboundValidationError`. A guard has to hold the property in the
code that REPORTS, not only in the code it wraps, which is why every fact the warning names is read
through `Internal::Rendering` and the emit itself is backstopped.

### Render at the join, not operand by operand

Half-rendering is strictly worse than rendering nothing: an `Encoding::CompatibilityError` needs
INCOMPATIBLE operands, and two ISO-8859-1 Strings concatenate fine — so transcoding one of them and
leaving its neighbour raw converts a composition that worked into a raise. That is not hypothetical;
it broke three separate paths this way:

- A Latin-1 `fail!` reason beside a Latin-1 `join:` separator (`result.error` raised).
- A Latin-1 field name beside a Latin-1 `default:` failure (`Encoding::CompatibilityError` in place
  of `DefaultAssignmentError` — a reporting failure replacing the real error, the exact defect the
  funnel exists to prevent).
- A Latin-1 declared name beside a `Date` whose registered `:inspect` format returned Latin-1.

The reason it kept recurring is that per-operand rendering requires ENUMERATING the operands, and
each enumeration missed a branch the next one found — the third case was a regression introduced by
the fix for the second. Normalization belongs at the one point every operand flows through, the way
`MessageResolver#body_for` owns it for handler returns: per-branch rendering is sound only where the
dispatch is an exhaustive type test whose every branch ends in the funnel, which is what a funnel
IS. A fix whose correctness depends on six call sites each remembering to render is not a fix; it is
six chances to be wrong, and the audit that found that one had already been wrong twice.

## Hostile-object-only findings: audit, don't chase

A finding reachable only by an object built to defeat the guard does not earn an exhaustive fix —
that pursuit is unbounded, since a worse object can always be invented — but it does earn an AUDIT
of the area, because such a report is evidence the area was written without the hazard in mind.

Three reasons that have held up to justify acting on one:

- It removes a duplicate policy for one question (a method owner was resolved in three places with
  three different absence policies, and closing that also closed a second caller the report never
  mentioned).
- It is the last unguarded instance in a module whose whole purpose is the guard (once `first_frame`
  read the backtrace container through a bound `Array#first`, every remaining dispatch in
  `Internal::Rendering` was deliberate, guarded and documented, so the file's stated promise became
  true rather than nearly true).
- It fails safe at the same cost as the dispatch it replaces.

What does NOT justify one is that the scenario is imaginable. The audit is the deliverable even when
the patch is declined — say what you examined and what you left, because "I found nothing else of
this shape" is the useful answer and is only worth anything if you looked.

## Cycle guards

Any code that recurses through caller-supplied Hash/Array values must cycle-guard with
`Axn::Internal::CycleGuard.guard` (a self-referential value is a `SystemStackError`, which is
outside `StandardError` and so escapes the whole result path).

A walk that descends a caller value **in lockstep with a shape graph** guards on the PAIR instead
(`CycleGuard.guard_pair`), because neither half alone is the walk's position: the same value
legitimately reappears under a different shape node with members still to validate, so keying on
the value stops a walk that is not looping and drops real verdicts, while keying on the shape stops
descending a value that still has members. Pairs only repeat while the graph does, so such a walk
needs `ShapeGraph::MAX_NESTING` as well — a graph that mints a fresh nested shape per read is
endless rather than cyclic and repeats nothing at all.

For third-party code that recurses and can't be guarded from inside — `ActiveSupport::ParameterFilter`
— rescue `SystemStackError` and retry on `CycleGuard.decycle(data)`, so acyclic data pays for
neither the extra walk nor the copy.
