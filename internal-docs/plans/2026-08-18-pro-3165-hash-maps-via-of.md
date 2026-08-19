# Hash maps via `of:` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `type: Hash, of: { keys:, values: }` declare an open-ended map for both validation and schema reflection, and close the hole that silently ignores every unrecognized key inside an `of:` bag.

**Architecture:** `of:` becomes "what is inside a container", with the declared `type:` deciding what inside means — elements for `Array`, keys and values for `Hash`. The container is derived into the `of:` bag at declaration exactly as `_derive_raw_shape_container!` already derives one into a `shape:`, so `OfValidator` dispatches on the declared container rather than on the runtime value's class. The bag's allowed keys become container-dependent, and that one whitelist is what closes the silent-ignore hole.

**Tech Stack:** Ruby (3.2/3.3/3.4), ActiveModel validations, RSpec.

**Spec:** `internal-docs/specs/2026-08-18-hash-maps-via-of-design.md`

**Ticket:** https://linear.app/teamshares/issue/PRO-3165/axn-hash-maps-via-of-and-close-the-nested-of-silent-ignore-hole

> **Status: complete, and superseded by the shipped behaviour where the two disagree.** The binding description is the spec above; this plan is kept as the record of how the work was sequenced. Two things it plans were decided differently during implementation, so every message spelling and code sketch below that names a KEY is stale:
>
> - **Map errors locate by ORDINAL, not by key** — `key at index 0 is not a Symbol`, `value at index 0 is not a Integer`. Validator messages never pass through redaction, so a rendered key would publish a `sensitive:` field's own data into `result.exception.message` and the INFO log line. The messages are unconditionally value-free instead, matching the element branch. Restoring key names for non-sensitive fields is follow-up work.
> - **`Axn::Internal::Rendering.hash_key` was never added.** Nothing renders a key at all, so there is no rendering seam for one to travel through; `lib/axn/internal/rendering.rb` is unchanged by this work.
>
> Beyond those, two declaration rules the plan does not describe shipped as well: a subfield rooted at a map-typed parent is refused at declaration from every seam a map can be declared at, and an axis naming an EMPTY union is judged as an absent axis (so `of: { values: [] }` raises rather than constraining nothing).

## Global Constraints

Specs live under `spec/` (non-Rails). Nothing here touches ActiveRecord or Rails, so nothing goes in `spec_rails/`.

Never assert `Hash#inspect` output text — its formatting differs across the supported Ruby matrix (3.2/3.3/3.4). Build expected error strings explicitly.

A value supplied by a caller is never asked to render itself. (As shipped, a Hash key is not rendered into a validation message at all — see the status note above.)

Anything an author must know is raised at declaration, never logged as a debug line.

No historical comments in code — no "used to X, now Y", no ticket references in comments explaining a change. Comments describe what the code does and why, in the present tense.

`shared` throughout means `Axn::Validation::Base.shared_validation_option_keys`, which is `[:if, :unless, :on, :allow_blank, :allow_nil, :strict]`.

Everything here runs through `_canonicalize_validator_options!`, which is the seam shape MEMBERS also pass through (`ShapeDeclaration#_symbol_keyed_member_validations`), so every rule added below applies to a member's bag automatically. Task 2 asserts that.

---

### Task 1: Whitelist the `of:` bag's keys

Closes the silent-ignore hole with no map support yet. An `of:` bag reaches `OfValidator` as an `ActiveModel::EachValidator` options hash, which ignores every key it does not read — so a nested `of:`, a nested `shape:`, a misspelled `message:`, or arbitrary junk all declare cleanly and constrain nothing.

**Files:**
- Modify: `lib/axn/core/contract.rb` (`_canonicalize_validator_options!`, around 2127-2140; new constant beside `KNOWN_VALIDATION_KEYS` at 1137)
- Test: `spec/axn/core/validations/validators/of_validator_spec.rb`
- Test: `spec/axn/core/validations/shape_contracts_spec.rb`

**Interfaces:**
- Consumes: `Axn::Validation::Base.shared_validation_option_keys`
- Produces: `OF_OPTION_KEYS` (a frozen `Set` of the keys an Array's `of:` bag may carry) and `_reject_unknown_of_keys!(bag, allowed, container)`, both of which Task 2 extends with a second allowed set.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/core/validations/validators/of_validator_spec.rb`, in the existing `describe "declaration-time validation"` block:

```ruby
it "rejects a nested of: inside the of: bag, which used to constrain nothing" do
  expect do
    build_axn { expects :matrix, type: Array, of: { klass: Array, of: Integer } }
  end.to raise_error(ArgumentError, /of: does not support of:/)
end

it "rejects a nested shape: inside the of: bag" do
  expect do
    build_axn { expects :rows, type: Array, of: { klass: Hash, shape: { members: [] } } }
  end.to raise_error(ArgumentError, /of: does not support shape:/)
end

it "rejects a misspelled message: rather than dropping the custom message" do
  expect do
    build_axn { expects :rows, type: Array, of: { klass: String, mesage: "nope" } }
  end.to raise_error(ArgumentError, /of: does not support mesage:/)
end

it "names every unsupported key at once" do
  expect do
    build_axn { expects :rows, type: Array, of: { klass: String, wat: 1, huh: 2 } }
  end.to raise_error(ArgumentError, /of: does not support wat:, huh:/)
end

it "still accepts the supported keys" do
  expect do
    build_axn { expects :rows, type: Array, of: { klass: String, message: "custom", allow_nil: true } }
  end.not_to raise_error
end

it "leaves on: to the context-scope guard, which has the better message" do
  expect do
    build_axn { expects :rows, type: Array, of: { klass: String, on: :create } }
  end.to raise_error(ArgumentError, /validation context/)
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/validators/of_validator_spec.rb -e "declaration-time validation"`

Expected: the first four and the last FAIL (no error raised — the keys are silently ignored); "still accepts the supported keys" passes already.

- [ ] **Step 3: Add the whitelist**

In `lib/axn/core/contract.rb`, beside `KNOWN_VALIDATION_KEYS` (around line 1137):

```ruby
# What an `of:` bag may carry. Everything else is refused rather than ignored: the bag reaches
# `OfValidator` as an EachValidator options hash, which reads the keys it knows and drops the rest —
# so an unrecognized key declares cleanly, constrains nothing, and every value passes.
#
# `on:` is admitted here and refused by `_reject_validator_context_scope!`, which names the actual
# problem (axn has no validation contexts) instead of reporting the key as unknown.
OF_OPTION_KEYS = (Set.new(%i[klass message]) | Axn::Validation::Base.shared_validation_option_keys).freeze
```

In `_canonicalize_validator_options!`, after the `of:` sugar is applied and before the `:klass` check:

```ruby
validations[:of] = Axn::Validators::OfValidator.apply_syntactic_sugar(validations[:of], fields)
declared_klasses = Array(validations.dig(:type, :klass))
raise ArgumentError, "of: requires type: Array (got #{declared_klasses.inspect})" unless declared_klasses == [Array]

_reject_unknown_of_keys!(validations[:of], OF_OPTION_KEYS)
raise ArgumentError, "of: must supply :klass" if validations[:of][:klass].nil?
```

And the guard itself, private, beside `_canonicalize_validator_options!`:

```ruby
# Every offender at once: an author who wrote two of them has one declaration to fix, not two rounds
# of the same error.
def _reject_unknown_of_keys!(bag, allowed)
  offenders = bag.keys.reject { |key| allowed.include?(key) }
  return if offenders.empty?

  raise ArgumentError,
        "of: does not support #{offenders.map { |key| "#{key}:" }.join(', ')} " \
        "(supported: #{allowed.to_a.map { |key| "#{key}:" }.join(', ')})"
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/validations/validators/of_validator_spec.rb spec/axn/core/validations/shape_contracts_spec.rb`

Expected: PASS. If an existing example declared a bag with an unsupported key, it was relying on the hole — update it to the supported spelling rather than widening the whitelist.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations
git commit -m "$(cat <<'EOF'
PRO-3165: refuse unsupported keys in an of: bag instead of ignoring them

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Accept `type: Hash` with `of: { keys:, values: }` at declaration

Declaration-time only — the bag is canonicalized, held to the Hash whitelist, and stored with its container. Runtime enforcement arrives in Task 3, so the tests here assert what raises and what declares, not what validates.

**Files:**
- Modify: `lib/axn/core/contract.rb` (`_canonicalize_validator_options!` and the new constants/guards from Task 1)
- Test: `spec/axn/core/validations/validators/of_validator_spec.rb`
- Test: `spec/axn/core/validations/shape_contracts_spec.rb`

**Interfaces:**
- Consumes: `OF_OPTION_KEYS`, `_reject_unknown_of_keys!` (Task 1)
- Produces: a canonical `of:` bag carrying `container:` (`::Array` or `::Hash`) — the key `OfValidator` dispatches on in Task 3, and the key `Internal::Reflection::Schema` branches on in Task 4. Under `Array` the bag keeps `klass:`; under `Hash` it carries `keys:` and/or `values:` and never `klass:`.

- [ ] **Step 1: Write the failing tests**

New `describe` block in `spec/axn/core/validations/validators/of_validator_spec.rb`:

```ruby
describe "Hash containers (maps)" do
  it "accepts keys: and values:" do
    expect { build_axn { expects :counts, type: Hash, of: { keys: Symbol, values: Integer } } }.not_to raise_error
  end

  it "accepts values: alone — an unconstrained key axis is said by omitting it" do
    expect { build_axn { expects :counts, type: Hash, of: { values: Integer } } }.not_to raise_error
  end

  it "accepts keys: alone" do
    expect { build_axn { expects :counts, type: Hash, of: { keys: Symbol } } }.not_to raise_error
  end

  it "accepts a union on either axis" do
    expect { build_axn { expects :counts, type: Hash, of: { keys: [String, Symbol], values: [String, Integer] } } }
      .not_to raise_error
  end

  it "rejects the bare form, which does not say which axis it constrains" do
    expect { build_axn { expects :counts, type: Hash, of: Integer } }
      .to raise_error(ArgumentError, /of: requires keys: and\/or values: for a Hash/)
  end

  it "rejects klass:, pointing at values:" do
    expect { build_axn { expects :counts, type: Hash, of: { klass: Integer } } }
      .to raise_error(ArgumentError, /of: does not support klass:/)
  end

  it "rejects a bag that constrains nothing" do
    expect { build_axn { expects :counts, type: Hash, of: {} } }
      .to raise_error(ArgumentError, /of: requires keys: and\/or values: for a Hash/)
  end

  it "rejects message:, which cannot say which axis failed" do
    expect { build_axn { expects :counts, type: Hash, of: { values: Integer, message: "nope" } } }
      .to raise_error(ArgumentError, /of: does not support message:/)
  end

  it "rejects a nested contract on an axis as not yet supported" do
    expect { build_axn { expects :counts, type: Hash, of: { values: { klass: Integer } } } }
      .to raise_error(ArgumentError, /not supported yet/)
  end

  it "rejects a nested contract inside a union on an axis" do
    expect { build_axn { expects :counts, type: Hash, of: { values: [String, { klass: Integer }] } } }
      .to raise_error(ArgumentError, /not supported yet/)
  end

  it "rejects of: beside shape: on a Hash as not yet supported" do
    expect do
      build_axn do
        expects :counts, type: Hash, of: { values: Integer }, shape: { members: [] }
      end
    end.to raise_error(ArgumentError, /not supported yet/)
  end

  it "rejects values: on an Array, pointing at klass:" do
    expect { build_axn { expects :ids, type: Array, of: { values: Integer } } }
      .to raise_error(ArgumentError, /of: does not support values:/)
  end

  it "rejects a union type:, from which no container can be derived" do
    expect { build_axn { expects :counts, type: [Array, Hash], of: { values: Integer } } }
      .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [Array, Hash])")
  end

  it "rejects of: with no type: at all" do
    expect { build_axn { expects :counts, of: { values: Integer } } }
      .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [])")
  end

  it "holds a shape member's bag to the same rules, since both pass through one seam" do
    expect do
      build_axn do
        expects :order, type: Hash do
          field :counts, type: Hash, of: { klass: Integer }
        end
      end
    end.to raise_error(ArgumentError, /of: does not support klass:/)
  end
end
```

Then update the two existing examples that assert the old message text — in `of_validator_spec.rb` ("raises ArgumentError when of: is used without type: Array", "when type: is a union containing Array", "when of: is used without any type:") and in `shape_contracts_spec.rb` around line 715 ("rejects `of:` beside a non-Array `type:`", "rejects a bare `of:` with no `type:`"). The message now names both containers:

```ruby
# shape_contracts_spec.rb — the non-Array case is now a non-container case
it "rejects `of:` beside a `type:` that is neither Array nor Hash, with the field path's own message" do
  expect { declared_with({ type: String, of: String }) }
    .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [String])")
end

it "rejects a bare `of:` with no `type:`, as the field path does" do
  expect { declared_with({ of: String }) }
    .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [])")
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/validators/of_validator_spec.rb spec/axn/core/validations/shape_contracts_spec.rb`

Expected: the new `Hash containers (maps)` block fails throughout — every `type: Hash` declaration currently raises `of: requires type: Array (got [Hash])` — and the two rewritten message assertions fail on the old text.

- [ ] **Step 3: Make the canonicalization container-aware**

Replace the `of:` half of `_canonicalize_validator_options!` with a container-derived branch:

```ruby
return unless validations.key?(:of)

container = _of_container!(validations)
validations[:of] = container == ::Hash ? _canonical_map_of!(validations) : _canonical_array_of!(validations, fields)
```

```ruby
# `of:` names what is INSIDE a container, so the declared type is what decides which grammar the bag is
# held to: an Array has elements, a Hash has keys and values. Derived here and stored in the bag, so the
# validator dispatches on what was DECLARED rather than on the value it is handed — a Hash arriving under
# `type: Array` is a type error, not a map.
#
# A union names no single container, which is the same situation `shape:` refuses for the same reason.
def _of_container!(validations)
  declared = Array(validations.dig(:type, :klass))
  return declared.first if declared == [::Array] || declared == [::Hash]

  raise ArgumentError, "of: requires type: Array or Hash (got #{declared.inspect})"
end

def _canonical_array_of!(validations, fields)
  bag = Axn::Validators::OfValidator.apply_syntactic_sugar(validations[:of], fields)
  _reject_unknown_of_keys!(bag, OF_OPTION_KEYS)
  raise ArgumentError, "of: must supply :klass" if bag[:klass].nil?

  bag.merge(container: ::Array)
end

# A Hash has two things inside it, so the bare form has no honest reading: `of: Integer` would have to
# pick an axis by convention, and which one it picked would not be visible in the declaration.
def _canonical_map_of!(validations)
  bag = Internal::ShapeGraph.hash_or_nil(validations[:of])
  raise ArgumentError, MAP_OF_REQUIRED_MESSAGE if nil.equal?(bag)

  _reject_unknown_of_keys!(bag, MAP_OF_OPTION_KEYS)
  raise ArgumentError, MAP_OF_REQUIRED_MESSAGE if bag[:keys].nil? && bag[:values].nil?

  _reject_nested_map_contract!(bag)
  _reject_map_beside_shape!(validations)
  bag.merge(container: ::Hash)
end

MAP_OF_REQUIRED_MESSAGE = "of: requires keys: and/or values: for a Hash — a Hash has two things inside it, " \
                          "so name the axis you are constraining"

# `message:` is absent deliberately: one message cannot say which axis failed, and a per-axis one needs
# the nested bag that `_reject_nested_map_contract!` refuses.
MAP_OF_OPTION_KEYS = (Set.new(%i[keys values]) | Axn::Validation::Base.shared_validation_option_keys).freeze

# An axis takes the same forms `type:` does — a class, a union of them, a `:boolean`/`:uuid`/`:params`
# symbol — and not a contract of its own. Refused as "not supported yet" rather than as meaningless,
# because it is the spelling a nested contract will take.
def _reject_nested_map_contract!(bag)
  %i[keys values].each do |axis|
    next if Array(bag[axis]).none? { |entry| entry.is_a?(::Hash) }

    raise ArgumentError, "of: #{axis}: takes a type, not a nested contract — that is not supported yet"
  end
end

# `shape:` names a Hash's own members and `of:` names its values, so the two describe different nodes and
# are complements rather than rivals. Refused as "not supported yet" so granting the combination later
# contradicts nothing already released.
def _reject_map_beside_shape!(validations)
  return if nil.equal?(Internal::ShapeGraph.hash_or_nil(validations[:shape]))

  raise ArgumentError, "of: beside shape: on a Hash is not supported yet — shape: names the hash's own " \
                       "members while of: names its values"
end
```

Note that `_reject_nested_map_contract!` reads `Array(bag[axis])`, so it covers a bare nested bag and one hidden inside a union in the same pass.

**Check before moving on:** the canonical bag now carries a `container:` key that no caller may supply — the whitelist rejects it — which means canonicalizing the same bag twice would reject axn's own derived key on the second pass. `OfValidator.apply_syntactic_sugar` is written to be idempotent (`return value if value.is_a?(Hash)`), so the surrounding seam may well be called more than once. Add an example declaring a field and a shape member whose bags are canonicalized through both entry points, and if a double pass is real, guard `_canonical_array_of!`/`_canonical_map_of!` with an early return for a bag already carrying `container:` — placed after the whitelist check on the first pass, never before it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/validations/validators/of_validator_spec.rb spec/axn/core/validations/shape_contracts_spec.rb`

Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`

Expected: PASS. A failure elsewhere asserting `of: requires type: Array` is the message change — update the assertion.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations
git commit -m "$(cat <<'EOF'
PRO-3165: accept type: Hash with of: { keys:, values: } at declaration

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3

**Message spelling correction (2026-08-18, post-implementation):** map errors locate by ORDINAL, not by key — `key at index 0 is not a Symbol` and `value at index 0 is not a Integer`. The key is never rendered into a validation message, on any field. Validator messages do not pass through redaction, so a rendered key would leak a `sensitive:` field's data into `result.exception.message` and the INFO log line, which the element branch deliberately avoids (`type_validator.rb`: "Value-free, like `msg`, so no sensitive input leaks"). `sensitive:` is not reachable where the `of:` bag is canonicalized, so the message is unconditionally value-free rather than value-free only for sensitive fields. Restoring key names for non-sensitive fields is follow-up work.
: Validate map keys and values at runtime

**Files:**
- Modify: `lib/axn/core/validation/validators/of_validator.rb`
- Modify: `lib/axn/internal/rendering.rb` (new `hash_key`)
- Test: `spec/axn/core/validations/validators/of_validator_spec.rb`

**Interfaces:**
- Consumes: the canonical bag from Task 2 (`container:`, `keys:`, `values:`)
- Produces: `Axn::Internal::Rendering.hash_key(key) -> String` — a key named in prose without dispatching anything the key defines.

- [ ] **Step 1: Write the failing tests**

```ruby
describe "Hash containers (maps) at runtime" do
  subject(:action) do
    build_axn do
      expects :counts, type: Hash, of: { keys: Symbol, values: Integer }
      def call = nil
    end
  end

  it "accepts a map matching both axes" do
    expect(action.call(counts: { acme: 1, globex: 2 })).to be_ok
  end

  it "accepts an empty map — emptiness is allow_empty's business, not of:'s" do
    expect(action.call(counts: {})).to be_ok
  end

  it "reports the offending key by name" do
    result = action.call(counts: { "acme" => 1 })
    expect(result).not_to be_ok
    expect(result.exception.message).to include('key "acme" is not a Symbol')
  end

  it "reports the offending value with the key that located it" do
    result = action.call(counts: { acme: "1" })
    expect(result).not_to be_ok
    expect(result.exception.message).to include("value at key :acme is not a Integer")
  end

  it "reports both axes independently when both are wrong" do
    result = action.call(counts: { "acme" => "1" })
    message = result.exception.message
    expect(message).to include('key "acme" is not a Symbol')
    expect(message).to include('value at key "acme" is not a Integer')
  end

  it "names a union on the failing axis" do
    unioned = build_axn do
      expects :counts, type: Hash, of: { values: [String, Integer] }
      def call = nil
    end
    expect(unioned.call(counts: { a: 1.5 }).exception.message).to include("value at key :a is not one of String, Integer")
  end

  it "leaves the non-Hash error to TypeValidator" do
    result = action.call(counts: "not a hash")
    expect(result).not_to be_ok
    expect(result.exception.message).not_to match(/value at key/)
  end

  it "names a key that is neither String nor Symbol without asking it to render itself" do
    hostile = Class.new do
      def inspect = raise("nope")
      def to_s = raise("nope")
    end
    keyed = build_axn do
      expects :counts, type: Hash, of: { values: Integer }
      def call = nil
    end
    result = keyed.call(counts: { hostile.new => "x" })
    expect(result).not_to be_ok
    expect(result.exception.message).to match(/value at key #<#<Class:/)
  end

  it "constrains only the declared axis" do
    values_only = build_axn do
      expects :counts, type: Hash, of: { values: Integer }
      def call = nil
    end
    expect(values_only.call(counts: { "anything" => 1 })).to be_ok
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/validators/of_validator_spec.rb -e "Hash containers (maps) at runtime"`

Expected: the acceptance examples pass vacuously (nothing is enforced yet) and every error-reporting example FAILs.

- [ ] **Step 3: Add the key renderer**

In `lib/axn/internal/rendering.rb`, beside `class_name`:

```ruby
# A Hash key named in prose — quoted as a String, colon-prefixed as a Symbol, and named by its class
# otherwise. Which of those it is IS the thing a `keys:` failure is about, so the two cannot render alike.
#
# Nothing the key defines runs: a String is rendered from its bytes (`Text.renderable` dispatches
# nothing), and `Symbol#name` is bound. Any other key is described rather than rendered, since a key
# that raises from `inspect` must not replace the validation verdict with its exception.
def hash_key(key)
  return ":#{Text.renderable(SYMBOL_NAME.bind_call(key))}" if Identity.kind?(key, ::Symbol)
  return "\"#{Text.renderable(key)}\"" if Identity.kind?(key, ::String)

  "#<#{class_name(key)}>"
end
```

with `SYMBOL_NAME = ::Symbol.instance_method(:name)` as a private constant in the same file.

- [ ] **Step 4: Add the Hash branch to OfValidator**

Rewrite `validate_each` and `check_validity!` in `lib/axn/core/validation/validators/of_validator.rb`:

```ruby
def check_validity!
  return if options[:container] == ::Hash

  raise ArgumentError, "must supply :klass" if options[:klass].nil?
end

def validate_each(record, attribute, value)
  return if value.nil? && (options[:allow_nil] || options[:allow_blank])

  options[:container] == ::Hash ? validate_entries(record, attribute, value) : validate_elements(record, attribute, value)
end

private

# The declared container decides which branch runs; the value's own class only decides whether this
# validator has anything to say about it. TypeValidator owns both mismatches.
def validate_elements(record, attribute, value)
  return unless value.is_a?(::Array)

  klasses = Array(options[:klass])
  msg = options[:message] || describe_mismatch(klasses)

  value.each_with_index do |el, i|
    valid = klasses.any? { |k| TypeValidator.value_matches?(el, klass: k) }
    record.errors.add(attribute, "element at index #{i} #{msg}") unless valid
  end
end

# Both axes are reported independently: a map whose keys and values are both wrong has two things to fix,
# and the key is what locates the value either way. An axis left undeclared constrains nothing.
def validate_entries(record, attribute, value)
  return unless value.is_a?(::Hash)

  key_klasses = Array(options[:keys])
  value_klasses = Array(options[:values])

  Axn::Internal::ShapeGraph.each_entry(value) do |key, entry|
    rendered = Axn::Internal::Rendering.hash_key(key)

    unless matches_axis?(key, key_klasses)
      record.errors.add(attribute, "key #{rendered} #{describe_mismatch(key_klasses)}")
    end
    next if matches_axis?(entry, value_klasses)

    record.errors.add(attribute, "value at key #{rendered} #{describe_mismatch(value_klasses)}")
  end
end

def matches_axis?(value, klasses)
  klasses.empty? || klasses.any? { |k| TypeValidator.value_matches?(value, klass: k) }
end

def describe_mismatch(klasses)
  klasses.size == 1 ? "is not a #{klasses.first}" : "is not one of #{klasses.join(', ')}"
end
```

`each_entry` is `ShapeGraph`'s bound `Hash#each`, so a Hash subclass cannot decide which entries get validated. `of_validator.rb` currently requires only `active_model` — add `require "axn/internal/shape_graph"` and `require "axn/internal/rendering"` at the top, matching how `type_validator.rb` requires `axn/internal/rendering` for the same reason.

The `# A custom message: replaces the type description but the index is always reported` comment moves with the element branch it explains.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/validations/validators/of_validator_spec.rb`

Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rspec`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/validation/validators/of_validator.rb lib/axn/internal/rendering.rb spec/axn/core/validations
git commit -m "$(cat <<'EOF'
PRO-3165: validate map keys and values at runtime

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Emit `additionalProperties`, and teach the property walk to see through it

**Files:**
- Modify: `lib/axn/internal/reflection/schema.rb` (`shape_property_plan` ~1483, `apply_structured_schema!` ~1380, `items_schema_for` ~1548)
- Modify: `lib/axn/internal/reflection/property_names.rb` (`each_emitted_node` ~343)
- Test: `spec/axn/internal/reflection/schema_spec.rb` (or the existing schema-reflection spec file for `of:`)

**Interfaces:**
- Consumes: the canonical bag from Task 2 (`container: ::Hash`, `values:`)
- Produces: `contents_schema_for(klasses, for_output:)` — the union-aware element/value schema builder that `items_schema_for` now delegates to.

- [ ] **Step 1: Write the failing tests**

```ruby
describe "Hash containers (maps)" do
  def schema_for(&) = Axn::Internal::Reflection::Schema.build_input_for(build_axn(&))

  it "emits additionalProperties for the value axis" do
    schema = schema_for { expects :counts, type: Hash, of: { values: Integer } }
    expect(schema[:properties][:counts]).to include(type: "object", additionalProperties: { type: "integer" })
  end

  it "emits anyOf under additionalProperties for a union value axis" do
    schema = schema_for { expects :counts, type: Hash, of: { values: [String, Integer] } }
    expect(schema[:properties][:counts][:additionalProperties])
      .to eq(anyOf: [{ type: "string" }, { type: "integer" }])
  end

  it "emits a Data value type's own members under additionalProperties" do
    point = Data.define(:x, :y)
    schema = schema_for { expects :points, type: Hash, of: { values: point } }
    expect(schema[:properties][:points][:additionalProperties])
      .to eq(type: "object", properties: { x: {}, y: {} })
  end

  it "emits nothing for the key axis" do
    schema = schema_for { expects :counts, type: Hash, of: { keys: Symbol, values: Integer } }
    expect(schema[:properties][:counts]).not_to have_key(:propertyNames)
  end
end
```

And, in the property-name walk's own spec, the case that proves the new rung is walked:

```ruby
it "walks property names under additionalProperties" do
  schema = { properties: { counts: { type: "object",
                                     additionalProperties: { type: "object", properties: { x: {}, y: {} } } } } }
  found = []
  Axn::Internal::Reflection::PropertyNames.send(:each_emitted_node, schema) { |path, names| found << [path, names] }

  expect(found).to include([%i[counts], %i[x y]])           # the map node's own names
  expect(found).to include([[:counts, :"{}"], %i[x y]])     # the value node's, one rung down
end
```

The first assertion is wrong on purpose — delete it once you see which of the two the walk actually yields. `each_emitted_node` yields `(path, names)` at each node that carries `properties:`, so the map property itself yields nothing and only the value node does.

Adapt that last example to however the spec file already reaches `each_emitted_node` — the assertion that matters is that the `x`/`y` names are yielded at a path carrying the new segment.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/internal/reflection`

Expected: FAIL — the map property emits no `additionalProperties` at all, because `shape_property_plan` returns its `nothing` plan for a non-array `of:` with no `shape:`.

- [ ] **Step 3: Generalize the element schema builder**

In `lib/axn/internal/reflection/schema.rb`:

```ruby
# One builder for what is INSIDE a container, whether that is an Array's items or a Hash's values: a
# union reflects as `anyOf` branches on both, and each branch carries its own element type's members.
def contents_schema_for(klasses, for_output: false)
  klasses = Array(klasses)
  return {} if klasses.empty?
  return single_items_schema(klasses.first, for_output:) if klasses.size == 1

  { anyOf: klasses.map { |k| single_items_schema(k, for_output:) } }
end

def items_schema_for(of_validations, for_output: false) = contents_schema_for(of_validations[:klass], for_output:)
```

- [ ] **Step 4: Emit the map**

Give `ShapePropertyPlan` a `container` field, populate it from the `of:` bag's own `container:`, and add the map case to `shape_property_plan` and `apply_structured_schema!`.

In `shape_property_plan`, ahead of the `in_items` branch:

```ruby
if of && of[:container] == ::Hash
  values = contents_schema_for(of[:values], for_output:)
  return ShapePropertyPlan.new(emitted: !values.empty?, in_items: false, shape:, container: ::Hash,
                               type_schema: values.empty? ? {} : { additionalProperties: values })
end
```

In `apply_structured_schema!`, ahead of the `plan.in_items?` branch:

```ruby
if plan.container == ::Hash
  prop.merge!(plan.type_schema) if plan.emitted
  return
end
```

Every other `ShapePropertyPlan.new` call gains `container: nil`. The `keys:` axis contributes nothing, per the spec: every JSON object key is a string, so `keys: String` would say nothing a client can act on and `keys: Symbol` would be a lie on the wire.

Because the map's `type_schema` is what `each_type_namespace` walks, the 25,000-property cap and the collision rules charge a `values:` type's members through the same path they already charge an `of:` element type's — no rule of their own.

- [ ] **Step 5: Teach the property walk the new rung**

In `lib/axn/internal/reflection/property_names.rb`, inside `each_emitted_node`, beside the `items` descent:

```ruby
each_emitted_node(schema[:additionalProperties], [*path, VALUES_SEGMENT], &block)
```

and beside `ITEMS_SEGMENT`:

```ruby
# A map's value node, in a path. Like ITEMS_SEGMENT, a segment no declared name can produce.
VALUES_SEGMENT = :"{}"
private_constant :VALUES_SEGMENT
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/internal/reflection`

Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `bundle exec rspec`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/internal/reflection spec/axn/internal/reflection
git commit -m "$(cat <<'EOF'
PRO-3165: emit additionalProperties for a map, and walk the new rung

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Document the grammar

**Files:**
- Modify: `docs/reference/class.md` (the `of:` bullets, around lines 90-93)
- Modify: `CHANGELOG.md` (the existing `## Unreleased` section)

- [ ] **Step 1: Extend the `of:` reference bullets**

The existing bullet reads "for `type: Array` fields, validates each element". Rewrite the group so `of:` is introduced as what is inside a container, with the Array form as it stands today and the Hash form beside it — one line per paragraph, no manual line breaks. Cover: the two axes, that omitting an axis leaves it unconstrained, that the bare form is Array-only and why, that an array on either axis is a union, that `message:` is Array-only, and that a Hash's `of:` emits `additionalProperties` while `keys:` emits nothing.

- [ ] **Step 2: Write the CHANGELOG entries**

Under `## Unreleased`, one `[FEAT]` entry in `### Added` for the map grammar and one `[BREAKING]` entry in `### Fixed` for the whitelist. The whitelist is breaking against `v0.1.0.pre.alpha.5.1`: a class that declared `of: { klass: X, of: Y }`, a nested `shape:`, or a misspelled option declared cleanly there and raises here. Say what changed, who is affected, and what to do — not how it was built.

- [ ] **Step 3: Verify the docs build and the examples are real**

Run: `bundle exec rspec` one final time, and check every code sample added to `docs/reference/class.md` against the runtime by declaring it in a scratch script — a documented spelling that raises is worse than an undocumented feature.

- [ ] **Step 4: Commit**

```bash
git add docs/reference/class.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
PRO-3165: document map declarations via of:

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review notes

Spec coverage: the grammar (Tasks 2, 5), both declaration tables (Tasks 1, 2), the runtime table (Task 3), schema reflection including the `keys:`-emits-nothing decision and the `each_emitted_node` rung (Task 4), and the untouched consumers — redaction, subfields, the declaration walk — which no task modifies, deliberately.

Interfaces: `container:` is written by Task 2, read by Tasks 3 and 4. `contents_schema_for` is introduced in Task 4 only. `hash_key` is introduced in Task 3 only. `OF_OPTION_KEYS`/`_reject_unknown_of_keys!` are introduced in Task 1 and extended by Task 2 with `MAP_OF_OPTION_KEYS`.

Two things left to the implementer's judgement, both flagged in place: the exact spec file and helper used for the `each_emitted_node` example in Task 4 Step 1, and the surrounding prose style when rewriting the `of:` bullets in Task 5.
