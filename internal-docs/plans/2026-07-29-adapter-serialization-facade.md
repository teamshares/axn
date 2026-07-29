# Adapter Serialization Facade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give adapter gems one declared entry point for rendering a result — `Axn::Extensions::Serialization.render(result, reject_opaque: false)` — and close `Axn::Reflection::Values` behind it, so a downstream gem can no longer constrain a refactor of core's own routing by depending on an internal predicate.

**Architecture:** A new `Axn::Extensions::Serialization` module derives the action's declared `exposes` configs from the result itself and hands them to the existing renderer. `Axn::Reflection::Values` keeps every line of its rendering logic and loses its *adapter-facing* surface: `follow_as_json?` is deleted (zero callers), `serialize_exposed` and seventeen helpers become `private_class_method`, and two methods stay public for named cross-module core callers — `serialize_value` for `Reflection::Schema`, and `canonical_wire_key` for `Core::Contract`'s declaration-time property-name checks (PRO-2995).

**Tech Stack:** Ruby, RSpec, RuboCop. No new dependencies, no new files in `lib/` beyond one.

**Ticket:** [PRO-2992](https://linear.app/teamshares/issue/PRO-2992/axn-narrow-the-adapter-facing-serialization-surface-behind)
**Spec:** `internal-docs/specs/2026-07-29-adapter-serialization-facade-design.md`

## Global Constraints

- **Rendering behavior does not change.** Same output, same `Axn::Reflection::UnserializableValue`, same messages, same split between the unconditional guarantees and what `reject_opaque:` buys. If a task tempts you to alter a rendering decision, stop — that is a different ticket.
- **`Axn::Reflection::UnserializableValue` keeps its name and its home.** Adapters rescue it by name (`axn-ruby_llm/lib/axn/ruby_llm/tool_adapter.rb:103`). Do not rename, alias, or re-home it.
- **Do not move `Axn::Reflection::Values` to `Axn::Internal::*`.** Explicit non-goal in the spec: it would break symmetry with `Reflection::Schema` (equally internal, staying put) and drag the public exception into a namespace question with no upside.
- **`render` takes no `field_configs` argument.** Deriving them is the point — an explicit list makes rendering a subset possible, which silently emits a body that contradicts the action's reflected `output_schema`.
- Comments describe current behavior and intrinsic why. No "used to X / now Y", no ticket numbers, no review references.
- No manual line breaks in Markdown prose — one line per paragraph.
- Never assert `Hash#inspect` text in a spec: Ruby 3.4 changed its spacing and CI runs 3.2/3.3/3.4. Object addresses in messages need regex or substring matching, never equality.
- Run `bundle exec rubocop` before each commit. Relevant maxima: `Layout/LineLength` 160, `Metrics/MethodLength` 70, `Metrics/AbcSize` 60. Multiline argument lists require a trailing comma; `Style/HashSyntax` requires shorthand for symbol keys.
- Full suite: `bundle exec rspec`. The Rails dummy app is a separate bundle: `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails`. Run it in Task 2 — `spec_rails/dummy_app/spec/axn/reflection/values_spec.rb` calls `serialize_value` ten times and must keep passing (it stays public, so this is a regression check, not a migration).
- CHANGELOG edits go under the existing `## 0.1.0-alpha.5` section, in `### Namespaces & extension API` (around L129) — that is where the `Axn::Extensions` namespace entry already lives, and PR #206 added to that same version section. Do **not** open an `## Unreleased`. If a newer `##` version section exists at the top when you run this, use that one instead.
- Adapter gems are out of scope. They pin axn by git *revision* in their lockfiles, so nothing breaks until each bumps deliberately, and each migrates in its own repo.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `lib/axn/extensions/serialization.rb` | The declared adapter entry point: derive configs, delegate rendering | **Create** |
| `lib/axn.rb` | Require graph | Modify (~L14): add `require "axn/extensions/serialization"` |
| `lib/axn/reflection/values.rb` | The renderer and every strictness check | Modify: delete `follow_as_json?` (L586-589), privatize `serialize_exposed` + 18 helpers, update the file header and `AS_JSON_PROJECTIONS` comments, add a module doc |
| `spec/axn/extensions/serialization_spec.rb` | Unit coverage for the entry point | **Create** |
| `spec/axn/reflection/values_spec.rb` | Renderer coverage | Modify: delete `describe ".serialize_exposed"` (L143-243), add a surface-closure example |
| `spec/axn/reflection/schema_spec.rb` | Schema reflection, incl. three runtime cross-checks against real serialization | Modify L84, L740, L1393: render through the facade |
| `AGENTS-tool-adapters.md` | Terse adapter cheat-sheet | Modify L79-102 |
| `docs/recipes/authoring-tool-adapters.md` | Adapter-author guidance | Modify L119-131 and L220 |
| `docs/reference/class.md` | User-facing reflection reference | Modify L811 |
| `CHANGELOG.md` | Release notes | Modify L24; add one entry under `### Namespaces & extension API` |

`AGENTS.md:83` also names `Axn::Reflection::Values` — **leave it alone.** That reference is guidance about core's own no-dispatch discipline in error paths, not an adapter pointer.

---

### Task 1: `Axn::Extensions::Serialization.render`

Pure addition. `Values` stays exactly as it is, so the whole existing suite keeps passing and the new spec is the only thing that moves. Task 2 closes the old surface.

**Files:**
- Create: `lib/axn/extensions/serialization.rb`
- Modify: `lib/axn.rb:14`
- Create: `spec/axn/extensions/serialization_spec.rb`

**Interfaces:**
- Consumes: `Axn::Reflection::Values.serialize_exposed(result, field_configs, reject_opaque: false)` (existing, unchanged); `Axn::Result#__action__` (existing public reserved accessor); `external_field_configs` (existing public class attribute).
- Produces: `Axn::Extensions::Serialization.render(result, reject_opaque: false) → Hash` with String keys. Raises `Axn::Reflection::UnserializableValue`. Task 2 makes this the only public rendering path; Task 3 documents it.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/extensions/serialization_spec.rb`. The first three examples are new; the rest are the six from `values_spec.rb`'s `describe ".serialize_exposed"` block with the configs argument dropped. `opaque_object` is copied from that spec file (both files need it independently, and the comment explains the process-wide `as_json` pollution it defends against).

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Extensions::Serialization do
  # An object with no own as_json, no to_h, and #to_s owned by Object — but `respond_to?` is
  # overridden to hide :as_json/:to_h rather than left to chance: another spec file's
  # `require "globalid"` adds a generic Object#as_json globally for the rest of this process (a
  # Rails app does the same), which would otherwise route a plain Object.new through the as_json
  # branch instead of the to_s fallback these examples mean to exercise.
  def opaque_object
    Object.new.tap do |o|
      def o.respond_to?(name, *args)
        return false if %i[as_json to_h].include?(name)

        super
      end
    end
  end

  describe ".render" do
    it "serializes each declared field by wire key (string)" do
      klass = Class.new do
        include Axn
        exposes :count, type: Integer
        def call = expose(count: 3)
      end

      expect(described_class.render(klass.call)).to eq("count" => 3)
    end

    # The configs are DERIVED from the result rather than passed in, so what lands in the body is
    # exactly the declared `exposes` — the same set output_schema reflects. An inbound-only field is
    # not part of that set and must not appear.
    it "renders the declared exposures and nothing else" do
      klass = Class.new do
        include Axn
        expects :multiplier, type: Integer
        exposes :product, type: Integer
        def call = expose(product: multiplier * 2)
      end

      expect(described_class.render(klass.call(multiplier: 4))).to eq("product" => 8)
    end

    # Adapter specs mock results with Axn::Result.ok, which builds a real (factory-made) action
    # behind the facade — so the derivation has to work there too, not just for a declared class.
    it "derives the configs from a mocked result" do
      expect(described_class.render(Axn::Result.ok(count: 3))).to eq("count" => 3)
    end

    # A field name is a property name in the output on the same terms as a nested Hash key, so it carries the
    # same UTF-8 promise. Declaration accepts any symbol, so a name with no UTF-8 rendering is reachable.
    it "holds a field name to the same encodability rule as a nested Hash key" do
      unencodable = "\xFF".b.to_sym
      klass = Class.new do
        include Axn
        auto_log false
        exposes unencodable

        define_method(:call) { expose(unencodable => 1) }
      end

      expect { described_class.render(klass.call) }
        .to raise_error(Axn::Reflection::UnserializableValue, /no UTF-8 rendering|UTF-8/)
    end

    it "names the offending field without interpolating its bytes, so reporting cannot itself raise" do
      unencodable = "\xFF".b.to_sym
      klass = Class.new do
        include Axn
        auto_log false
        exposes unencodable

        define_method(:call) { expose(unencodable => 1) }
      end

      # Symbol#inspect escapes the bytes to ASCII; interpolating the raw ones would raise
      # Encoding::CompatibilityError from building the message rather than reporting the defect.
      message = begin
        described_class.render(klass.call)
      rescue Axn::Reflection::UnserializableValue => e
        e.message
      end

      # The message itself is UTF-8 prose (it contains em dashes), so the property is that building it
      # succeeded and produced valid UTF-8 — not that it is ASCII-only.
      expect(message).to be_a(String)
      expect(message.encoding).to eq(Encoding::UTF_8)
      expect(message).to satisfy(&:valid_encoding?)
      expect(message).to include('\xFF')
    end

    # Canonicalizing field names to UTF-8 means two distinct Symbols can converge on one property, which
    # would silently overwrite — the same collapse the Hash branch raises on, reachable one level up.
    it "raises when two field names render as the same JSON property" do
      iso = "\xE9".dup.force_encoding(Encoding::ISO_8859_1).to_sym
      utf = :é
      klass = Class.new do
        include Axn
        auto_log false
        exposes iso
        exposes utf

        define_method(:call) { expose(iso => "FIRST", utf => "second") }
      end

      expect { described_class.render(klass.call) }
        .to raise_error(Axn::Reflection::UnserializableValue, /two exposed fields render as the same JSON property/)
    end

    it "renders an ordinary field name as a frozen UTF-8 property" do
      klass = Class.new do
        include Axn
        exposes :count, type: Integer
        def call = expose(count: 3)
      end

      key = described_class.render(klass.call).keys.first
      expect(key).to eq("count")
      expect(key.encoding).to eq(Encoding::UTF_8)
      expect(key).to be_frozen
    end

    it "threads reject_opaque: to the values it serializes" do
      owner = opaque_object
      klass = Class.new do
        include Axn
        auto_log false
        exposes :owner

        define_method(:call) { expose(owner:) }
      end
      result = klass.call

      expect(described_class.render(result)["owner"]).to match(/\A#<Object:0x[0-9a-f]+>\z/)
      expect { described_class.render(result, reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`owner`/)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/extensions/serialization_spec.rb`
Expected: every example errors with `NameError: uninitialized constant Axn::Extensions::Serialization`.

- [ ] **Step 3: Write the implementation**

Create `lib/axn/extensions/serialization.rb`:

```ruby
# frozen_string_literal: true

# Declared rather than inherited from the top-level `axn` entrypoint's require order, for the reason
# axn/reflection/values.rb gives about its own: the renderer is a runtime reference, so a standalone
# load of this file would NameError on the first call rather than at require time.
require "axn/reflection/values"

module Axn
  module Extensions
    # The declared entry point for rendering a successful Result — the one serialization call an
    # adapter gem makes. Everything behind it is core's own: Axn::Reflection::Values holds the
    # rendering decisions, and a caller depending on one of them constrains core's routing.
    module Serialization
      module_function

      # A successful Result's exposures as a JSON-safe Hash keyed by wire key (a String), over the
      # action's declared `exposes`.
      #
      # The configs are DERIVED from the result rather than passed in. Rendering a subset is the only
      # thing an explicit list would allow, and a subset silently produces a body that no longer
      # matches the action's reflected output_schema — which is the promise this rendering keeps.
      #
      # `reject_opaque:` additionally rejects a value (or Hash key) that declares no rendering of its
      # own. Off by default, because such output is honest and complete, just not a shape its author
      # chose: whether that is a failure belongs to the transport, since an HTTP contract should not
      # ship it while an LLM tool result is better off ugly than failed. Everything unconditional — a
      # cycle, two names collapsing to one property, a non-finite Float, bytes with no UTF-8
      # rendering — raises either way.
      #
      # Raises Axn::Reflection::UnserializableValue (an ArgumentError) naming the path to the
      # offending value, so an adapter's existing `rescue StandardError` maps it to an error response.
      def render(result, reject_opaque: false)
        configs = result.__action__.class.external_field_configs

        Axn::Reflection::Values.serialize_exposed(result, configs, reject_opaque:)
      end
    end
  end
end
```

Then add the require to `lib/axn.rb`, immediately after `require "axn/extensions/config"` (L14):

```ruby
require "axn/extensions"
require "axn/extensions/config"
require "axn/extensions/serialization"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/extensions/serialization_spec.rb`
Expected: 8 examples, 0 failures.

Then the full suite and RuboCop:

Run: `bundle exec rspec`
Expected: green (nothing was removed yet, so `values_spec.rb` still covers `serialize_exposed` directly — the temporary duplication is deliberate and Task 2 removes it).

Run: `bundle exec rubocop`
Expected: no offenses.

If the mocked-result example fails, do **not** paper over it by dropping the example — a `Axn::Result.ok` mock that cannot be rendered is a real finding, since adapter specs build results that way. Report it.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/extensions/serialization.rb lib/axn.rb spec/axn/extensions/serialization_spec.rb
git commit -m "PRO-2992: add Axn::Extensions::Serialization.render as the adapter entry point"
```

---

### Task 2: Close `Axn::Reflection::Values`

The narrowing itself. Nothing here changes behavior — it changes what is reachable.

**Files:**
- Modify: `lib/axn/reflection/values.rb` (header comment L6-11, module doc before L23, `AS_JSON_PROJECTIONS` comment L40-42, `serialize_value` doc, delete L586-589, add `private_class_method` block before the module's final `end`)
- Modify: `lib/axn/extensions/serialization.rb` (call the now-private method via `send`)
- Modify: `spec/axn/reflection/values_spec.rb` (add a surface `describe`; delete the `.serialize_exposed` block)
- Modify: `spec/axn/reflection/schema_spec.rb` (three call sites: L84, L740, L1393)

**Line numbers in this task refer to the files as they stand before you edit them.** Step 1 adds a block to `values_spec.rb` and Step 3 deletes lines from `values.rb`, so locate every later edit by the anchor text quoted here rather than by line number.

**Interfaces:**
- Consumes: `Axn::Extensions::Serialization.render` from Task 1.
- Produces: `Axn::Reflection::Values` with no adapter-facing surface — two public singleton methods, each with a named in-core caller: `serialize_value(value, path:, seen:, reject_opaque:)` for `Reflection::Schema` and `canonical_wire_key(key)` for `Core::Contract`. `serialize_exposed` and seventeen helpers are private; `follow_as_json?` no longer exists.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/reflection/values_spec.rb`, as the first `describe` block inside the outer one (immediately before `describe ".serialize_value"` at L27):

```ruby
  # The surface is the deliverable, not an implementation detail: an adapter renders through
  # Axn::Extensions::Serialization.render, and what stays public does so for a named cross-module core
  # caller — serialize_value for Reflection::Schema, which renders a literal `default:` through it so the
  # schema's wire form and the serializer's cannot disagree; canonical_wire_key for Core::Contract, which
  # rejects two declared names that would collapse onto one JSON property. Anything else appearing here is
  # a new public promise about the renderer's own decisions, which is what constrains core's routing later.
  describe "public surface" do
    it "exposes only the two methods core calls cross-module" do
      expect(described_class.singleton_class.public_instance_methods(false).sort).to eq(%i[canonical_wire_key serialize_value])
    end

    it "no longer answers the as_json-routing question that projection_for owns" do
      expect(described_class).not_to respond_to(:follow_as_json?)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb -e "public surface"`
Expected: two failures — the first listing all twenty-one public methods, the second reporting that `Values` does respond to `follow_as_json?`. If PRO-2995 has not landed yet, `canonical_wire_key` has no in-core caller outside this file; keep it public regardless and leave the expectation as written, since removing it later is a one-line change while re-privatizing it forces the `send` workaround into `Core::Contract` too.

- [ ] **Step 3: Delete `follow_as_json?` and its stale references**

In `lib/axn/reflection/values.rb`, delete L586-589 entirely (the three-line comment and the one-line method):

```ruby
      # Whether serialize_value renders `value` via `as_json` rather than `to_h`/`to_s`. Retained for
      # adapters that route on the same question (axn-openapi); the answer comes from projection_for so
      # there is one source of truth.
      def follow_as_json?(value) = AS_JSON_PROJECTIONS.include?(projection_for(value))
```

`AS_JSON_PROJECTIONS` now has a single use (the `when *AS_JSON_PROJECTIONS` arm at L206). **Keep the constant** — it names the set the `case` arm matches and the opaqueness verdict reads from — but rewrite its comment (L40-42), which names the deleted method:

```ruby
      # The projections `projection_for` names that serialize_value renders through `as_json`. Named as
      # a set rather than spelled into the `case` arm, so the route taken and the opaqueness verdict
      # below read from one list and cannot disagree.
      AS_JSON_PROJECTIONS = %i[own_as_json delegated_as_json generic_as_json].freeze
```

- [ ] **Step 4: Privatize the surface**

Add this immediately before the `end` that closes `module Values` — i.e. after `default_to_s?`, the last method in the file:

```ruby
      # Every rendering decision below serialize_value is core's own. Kept private so a downstream
      # gem cannot pin one of them: an adapter renders a whole result through
      # Axn::Extensions::Serialization.render, which is the only caller of serialize_exposed.
      # canonical_wire_key is absent deliberately — Core::Contract calls it to reject two declared names
      # that would collapse onto one JSON property, so the declaration check and the rendering it predicts
      # share one definition of a property name.
      private_class_method :serialize_exposed, :encodable_string!, :utf8_rendering, :transcode_to_utf8,
                           :finite_number!, :coerce_to_float, :within_container, :capture_hash_entries,
                           :own_wire_key, :no_entries_lost!, :raise_colliding_fields!, :owner_of,
                           :capture_elements, :raise_colliding_keys!,
                           :describe_key_classes, :check_opaque_key!, :projection_for, :default_to_s?
```

These are `module_function` methods, so each is both a public singleton method and a private instance method; `private_class_method` closes the singleton side. Internal calls are unaffected — they use an implicit receiver, which private methods allow.

Add a module doc immediately above `module Values` (L23), inside `module Reflection`:

```ruby
    # The value renderer: a Result's exposures, or any single value, rendered into a JSON-safe form
    # that matches what Reflection::Schema reflects. Core-internal — an adapter renders through
    # Axn::Extensions::Serialization.render — and everything but serialize_value and canonical_wire_key
    # is private.
```

Extend `serialize_value`'s existing doc comment (the block starting at L135) with one paragraph at its end, before the `def`:

```ruby
      # Public for one caller outside this module: Reflection::Schema renders a literal `default:`
      # through it, so a schema's wire form and the serializer's agree by construction. Not part of
      # the adapter surface — a whole result renders through Axn::Extensions::Serialization.render.
```

Finally, the file header (L6-11) claims adapters are pointed at `axn/reflection`, which is no longer where they are pointed. Replace the first sentence, keeping the rest of the paragraph verbatim:

```ruby
# Declared rather than inherited from the top-level `axn` entrypoint's require order: `axn/reflection`
# is loadable on its own (it composes only its own reflection files), and Axn::Extensions::Serialization
# requires this file directly, while serializing ANY Hash/Array reaches CycleGuard and raising needs
# UnserializableValue. Both are runtime references, so without these a standalone load NameErrors on
# ordinary output.
```

- [ ] **Step 5: Point the facade at the now-private method**

In `lib/axn/extensions/serialization.rb`, replace the body's last line:

```ruby
        Axn::Reflection::Values.send(:serialize_exposed, result, configs, reject_opaque:)
```

and add a comment directly above it:

```ruby
        # `send` because serialize_exposed is private: this facade is its only caller, and that is
        # what makes `render` the rendering path rather than one of two.
```

- [ ] **Step 6: Delete the migrated spec block**

In `spec/axn/reflection/values_spec.rb`, delete the whole `describe ".serialize_exposed" do` block — from that line through its matching `end` (six examples, originally L143-243). Task 1 already carries all six in `spec/axn/extensions/serialization_spec.rb`. Leave every other block in the file untouched, including the `describe Axn::Reflection::UnserializableValue` block near the end.

- [ ] **Step 7: Migrate the schema_spec cross-checks**

`spec/axn/reflection/schema_spec.rb` renders real results in three places, to prove a reflected schema agrees with what the serializer actually emits. They are the only other callers in the repo, and they should go through the public entry point for the same reason an adapter does. Replace each call, leaving the surrounding assertions untouched:

L84 — in `it "runtime: serialize_exposed emits every exposed key, including an unset nullable one (nil)"`:

```ruby
      serialized = Axn::Extensions::Serialization.render(klass.call)
```

L740:

```ruby
    serialized = Axn::Extensions::Serialization.render(klass.call(w: 1))
```

L1393:

```ruby
      expect(Axn::Extensions::Serialization.render(klass.call)["cfg"]).to eq({ "name" => "x" })
```

The surrounding comments and example names in that file say "serialize_exposed" in prose (L49, L53, L67, L77, L670, L679, L711, L728, L1362, L5172). Those describe the renderer's behavior, which is still `serialize_exposed`'s, so leave them as they are — renaming them would claim the facade owns rendering decisions it only delegates.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb spec/axn/reflection/schema_spec.rb spec/axn/extensions/serialization_spec.rb`
Expected: green, with the two `public surface` examples now passing.

Run: `bundle exec rspec`
Expected: green. A failure naming a `NoMethodError` on a private method means something outside this module still calls a helper — report which caller rather than un-privatizing the method.

Run: `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails`
Expected: green (that suite calls only `serialize_value`).

Run: `bundle exec rubocop`
Expected: no offenses. If `Layout/LineLength` fires on the `private_class_method` list, re-wrap it — do not shorten the list.

- [ ] **Step 9: Commit**

```bash
git add lib/axn/reflection/values.rb lib/axn/extensions/serialization.rb spec/axn/reflection/values_spec.rb spec/axn/reflection/schema_spec.rb
git commit -m "PRO-2992: close Axn::Reflection::Values behind the serialization entry point"
```

---

### Task 3: Repoint the adapter-facing docs

Four files name `Axn::Reflection::Values.serialize_exposed` as the thing adapter authors should call. That is the surface this ticket closes, so the docs are part of the deliverable rather than a follow-up.

**Files:**
- Modify: `AGENTS-tool-adapters.md:79-102`
- Modify: `docs/recipes/authoring-tool-adapters.md:119-131` and `:220`
- Modify: `docs/reference/class.md:811`
- Modify: `CHANGELOG.md:24` and `### Namespaces & extension API`

**Interfaces:**
- Consumes: `Axn::Extensions::Serialization.render(result, reject_opaque: false)` from Tasks 1-2.
- Produces: no code. Nothing depends on this task.

- [ ] **Step 1: Repoint `AGENTS-tool-adapters.md`**

Replace the first bullet of the `## Value serialization` section (L81-83):

```markdown
- Render a success result's exposures with `Axn::Extensions::Serialization.render(result)` → JSON-safe Hash.
  Don't hand-roll (it handles Symbol/BigDecimal/Time/`as_json`-vs-`to_h` so output matches `output_schema`).
- **You pass no config list** — `render` derives the declared `exposes` from the result itself. Rendering a
  subset is deliberately unsupported: it would emit a body contradicting `output_schema`.
- **Don't reach into `Axn::Reflection::Values`.** `render` is the surface; the renderer's helpers are private
  and `serialize_value` exists for core's schema reflection, not for you.
```

Leave the rest of the section as-is — the `UnserializableValue` bullet, the two-guarantees bullet, and the `reject_opaque:` wording all stay accurate. Then update the `Source:` line (L102):

```markdown
Source: `lib/axn/extensions/serialization.rb` (the renderer itself is `lib/axn/reflection/values.rb`, core-internal).
```

- [ ] **Step 2: Repoint `docs/recipes/authoring-tool-adapters.md`**

Replace L121 (the paragraph introducing the call):

```markdown
To render a successful `Axn::Result`'s exposed values into a JSON-safe hash, use `Axn::Extensions::Serialization.render` — don't hand-roll it (it handles Symbol/BigDecimal/Time/`as_json`-vs-`to_h` edge cases so the output validates against the reflected `output_schema`):
```

Replace the code block at L124-129:

```ruby
# An MCP or LLM tool adapter
exposed = Axn::Extensions::Serialization.render(result)

# An HTTP adapter, which must not ship an undeclared rendering in a response body
exposed = Axn::Extensions::Serialization.render(result, reject_opaque: config.reject_opaque)
```

Replace L131 (`Pass axn_class.external_field_configs …`) with:

```markdown
You don't pass the field configs: `render` derives them from the result's own action class, so a rendered body always covers exactly the declared `exposes` — and therefore always matches `output_schema`. Rendering a subset isn't supported, deliberately; a partial body would contradict the schema the same adapter published.

Where the rendering actually happens — `Axn::Reflection::Values` — is core-internal, exactly like `Axn::Reflection::Schema`. `render` is the declared entry point; the module's helpers are private, and what stays public is there for core's own callers rather than for an adapter.
```

Update the result-handling sketch at L220:

```ruby
  present_as == :message ? result.message : Axn::Extensions::Serialization.render(result)
```

- [ ] **Step 3: Repoint `docs/reference/class.md`**

At L811, replace the parenthetical pairing so it names the facade:

```markdown
Paired with `Axn::Extensions::Serialization.render(result)` (which renders a result to a JSON-safe Hash), this is the groundwork for exposing any Axn as a callable tool.
```

Keep the rest of that paragraph — the read-only/off-the-execution-path promise and the `input_schema` warning caveat — byte-identical.

- [ ] **Step 4: Update the CHANGELOG**

At L24, the `MyAxn.input_schema` entry names the old call. Replace just that clause:

```markdown
and `Axn::Extensions::Serialization.render(result)` renders a `Result` to a JSON-safe Hash
```

Then add one entry at the end of `### Namespaces & extension API`:

```markdown
* [BREAKING] Adapter gems render a result through one declared entry point: `Axn::Extensions::Serialization.render(result, reject_opaque: false)`, which derives the declared `exposes` configs from the result itself — there is no config list to pass, and no supported way to render a subset (a partial body would contradict the `output_schema` the same adapter published). `Axn::Reflection::Values` is core-internal behind it: `serialize_exposed` and every rendering helper are now private, `follow_as_json?` is removed (`projection_for` was already the single source of truth for the same question), and what stays public is there for a named cross-module core caller rather than for an adapter — `serialize_value` for `Reflection::Schema`'s literal-`default:` rendering, and `canonical_wire_key` for `Core::Contract`'s declaration-time check that two exposed names cannot collapse onto one JSON property. Rendering behavior, error messages, and `Axn::Reflection::UnserializableValue` (which adapters rescue by name) are unchanged.
```

Leave the three PR #206 entries under `### Tools & adapters` (L110-112) alone: they accurately describe what the renderer raises, and this entry supersedes the naming.

- [ ] **Step 5: Verify**

Run: `bundle exec rubocop`
Expected: no offenses (Markdown isn't linted, but the repo runs RuboCop over everything else and this confirms nothing else drifted).

Then grep for stragglers:

Run: `grep -rn 'Reflection::Values' AGENTS-tool-adapters.md docs CHANGELOG.md`
Expected: only the two deliberate mentions — the `AGENTS-tool-adapters.md` "don't reach into" bullet plus its `Source:` line, the recipe's core-internal paragraph, and the CHANGELOG's historical `### Tools & adapters` entries. Any other hit in `docs/` is a straggler to fix.

- [ ] **Step 6: Commit**

```bash
git add AGENTS-tool-adapters.md docs/recipes/authoring-tool-adapters.md docs/reference/class.md CHANGELOG.md
git commit -m "PRO-2992: point adapter docs at the serialization entry point"
```

---

## Follow-up (not this plan)

Each adapter gem migrates in its own repo, after this merges to `axn` main and that gem bumps its pinned revision:

- `axn-mcp/lib/axn/mcp/serializer.rb:13` — `Axn::Extensions::Serialization.render(result)`; `field_configs` can then drop out of `result_to_mcp_response`'s signature, and `invocation.rb:41` stops passing it. Note `wrap.rb:70` still reads `external_field_configs.empty?` to decide whether to declare an output schema — that stays.
- `axn-openapi/lib/axn/openapi/serializer.rb:30` — same switch; folds into the in-flight PR already rewriting that file, which drops `field_configs` from `Serializer.serialize` and `dispatcher.rb:88`.
- `axn-ruby_llm/lib/axn/ruby_llm/tool_adapter.rb:100` — same switch; the `rescue ::Axn::Reflection::UnserializableValue` on L103 is unchanged.
- `axn-webhooks` — nothing to migrate; it has no serialization call sites and gets the facade by default.
