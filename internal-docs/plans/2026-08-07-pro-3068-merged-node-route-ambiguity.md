# Merged Wire Node Route Ambiguity Implementation Plan (PRO-3068)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop declaration order from deciding which of a merged wire node's routes supplies a value — by rejecting the ambiguous reference in one case, and making the pick structurally single-valued in the other.

**Architecture:** Two consumers currently call `configs.first` on a node that two routes merged onto. Parent resolution (`_deepest_reader_name`) gets a declaration-time rejection: a dotted `on:` tail may not cross a node that answers to more than one reader name. The model lookup token (`sibling_id_configs`) gets a resolution fix instead: its order-picked defaulted route is replaced by the route that owns the canonical `<field>_id` reader, which reader-name uniqueness makes single-valued, so no rejection is needed. PRO-2901's blanket two-default rejection is then deleted, since the pick it existed to prevent no longer exists.

**Tech Stack:** Ruby, RSpec, ActiveModel validations. No new dependencies.

**Design doc:** `internal-docs/specs/2026-08-07-merged-node-route-ambiguity-design.md` — read it before starting. Every decision below traces to a numbered decision there.

## Global Constraints

- Ruby 3.2/3.3/3.4 must all pass. Never assert on `Hash#inspect` text — its rendering differs across these versions.
- axn must work outside Rails. Guard any ActiveRecord/Rails reference with `defined?()`. `spec/` is the non-Rails suite; Rails-specific behavior is mirrored in `spec_rails/dummy_app/`.
- Declaration-time checks are **side-effect-free**: they inspect declared configs only and never dispatch a method on a user-supplied value (a custom `#inspect`/`#respond_to?` must not be able to run). Render declared names through `Axn::Internal::Reflection::PropertyNames.renderable_label` — a declared name may hold non-UTF-8 bytes, and interpolating one into a UTF-8 message raises `Encoding::CompatibilityError` from the reporting itself.
- Declaration checks must raise **before any class mutation**. They already run on a candidate tree in `_expects_subfields`; do not move them.
- Comments explain **why**, not what. No historical narration ("used to X, now Y"), no ticket-review references in code.
- One line per Markdown paragraph in docs — no manual line wrapping.
- CHANGELOG entries go under the existing `## Unreleased` heading (verified: `git tag`'s newest is `v0.1.0.pre.alpha.5.1`, matching `lib/axn/version.rb`, so `## Unreleased` is genuinely unreleased).
- Run `bundle exec rspec` (5344 examples currently, 0 failures) before claiming any task done. `spec_rails` is unaffected by this work but run it before the final task.

## File Structure

**Modified:**

- `lib/axn/core/contract_for_subfields.rb` — owns both runtime seams. Gains `anchor_index` and `crossed_node` (the shared crossing question) and `id_token_routes` (the shared token-route precedence); `_deepest_reader_name` and `sibling_id_configs` become consumers of them.
- `lib/axn/core/contract/subfield_contradictions.rb` — gains `check_ambiguous_crossings!`; loses `check_conflicting_defaults!`, `raise_conflicting_defaults!`, `describe_default`.
- `lib/axn/internal/reflection/schema.rb` — `sibling_id_rescued?` asks `id_token_routes` instead of scanning every sibling config.
- `lib/axn/core/ambient_context.rb` — opts the ambient tree out of the crossing check.
- `docs/reference/class.md` — states the node-vs-route invariant where dotted `on:` is introduced.
- `CHANGELOG.md`.

**Test files:**

- `spec/axn/core/subfield_crossing_seam_spec.rb` (new) — unit coverage for the crossing seam.
- `spec/axn/core/contract/subfield_contradictions_spec.rb` — the crossing rejection and its controls; PRO-2901's converted examples.
- `spec/axn/core/validations/on_subfields_spec.rb` — the token-route behavior.
- `spec/axn/internal/subfield_tree_spec.rb`, `spec/axn/internal/reflection/schema_spec.rb` — two fixtures re-anchored.

**Layering note:** `Internal::Reflection::Schema` calling `Axn::Core::ContractForSubfields.id_token_routes` is the direction this codebase already uses (`schema.rb:793` references `Axn::Core::Contract::GENERATED_READER_SOURCE_PATH`). Reference it at call time only — do **not** add a `require`, because `contract_for_subfields.rb` already requires `reflection/schema` and that would be a load cycle.

---

### Task 1: Extract the crossing seam

Pure refactor plus one new public query. No behavior change — the suite must stay green with no fixture edits.

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb:60-87`
- Test: `spec/axn/core/subfield_crossing_seam_spec.rb` (create)

**Interfaces:**
- Consumes: `Axn::Internal::SubfieldTree::ResolvedPath` (members `node`, `wire_path`, `ancestors`, `parent_index`), reachable as `Klass._resolved_subfields.index[config]`.
- Produces: `Axn::Core::ContractForSubfields.anchor_index(config, path) -> Integer` and `Axn::Core::ContractForSubfields.crossed_node(config, path) -> SubfieldTree::Node | nil`. Task 2 calls `crossed_node`.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/subfield_crossing_seam_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"

# `crossed_node` answers "does this config resolve its parent through a node it never named?" — the one
# question both the runtime reader dispatch (_deepest_reader_name) and the ambiguous-crossing declaration
# check ask, so they cannot disagree about which reference is unnamed.
RSpec.describe "the unnamed-crossing seam (PRO-3068)" do
  subject(:klass) do
    build_axn do
      expects :payload, type: Hash
      expects :bar, on: :payload, type: Hash
      expects :count, on: "payload.bar", optional: true  # dotted tail: crosses :bar without naming it
      expects :named, on: :bar, optional: true           # names :bar's reader
    end
  end

  def seam_for(field)
    config = klass.send(:subfield_configs).find { |c| c.field == field }
    [config, klass._resolved_subfields.index[config]]
  end

  it "returns the node a dotted tail crosses without naming it" do
    node = Axn::Core::ContractForSubfields.crossed_node(*seam_for(:count))

    expect(node.configs.map(&:reader_as)).to eq([:bar])
  end

  it "returns nil when the config anchors on that node by reader name" do
    expect(Axn::Core::ContractForSubfields.crossed_node(*seam_for(:named))).to be_nil
  end

  it "returns nil for a top-level config, which reads no segment at all" do
    config = klass.internal_field_configs.find { |c| c.field == :payload }
    path = klass._resolved_subfields.index[config]

    expect(Axn::Core::ContractForSubfields.crossed_node(config, path)).to be_nil
  end

  it "reports the anchor's own chain index for a dotted on:" do
    config, path = seam_for(:count)

    # `on: "payload.bar"` — one segment below the root, so the anchor sits one hop above the on: target.
    expect(Axn::Core::ContractForSubfields.anchor_index(config, path)).to eq(path.parent_index - 1)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/subfield_crossing_seam_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'crossed_node' for Axn::Core::ContractForSubfields`.

- [ ] **Step 3: Add the two seams and route `_deepest_reader_name` through one**

In `lib/axn/core/contract_for_subfields.rb`, immediately after `deepest_reader_index` (which ends at line 67), insert:

```ruby
      # The chain index of the config's `on:` ANCHOR — the node the `on:` ROOT names. Each dotted segment
      # below that root is one more hop, so the anchor sits that many hops above the `on:` TARGET.
      def self.anchor_index(config, path)
        path.parent_index - (config.on.to_s.split(".").size - 1)
      end

      # The node this config resolves its parent THROUGH without naming it — its deepest reader-bearing
      # ancestor, when that ancestor is not the `on:` anchor. Only a dotted tail can put a reader-bearing
      # node between the anchor and the `on:` target: the anchor's own node always bears a reader, and no
      # ancestor above it can exceed its index. So nil means the config NAMED the reader it reads through
      # (`on: :b2`, `on: "b2.deeper"`) and that node's config order cannot affect it. Nil too for a
      # top-level config (no ancestors to walk) and for the recipe fallback (no reader-bearing ancestor).
      #
      # Shared with the ambiguous-crossing declaration check (SubfieldContradictions) so the runtime's
      # answer and the check's are the same answer, as `deepest_reader_index` already is.
      def self.crossed_node(config, path)
        return nil if path.ancestors.empty?

        reader_index = deepest_reader_index(path)
        return nil if reader_index.nil? || reader_index == anchor_index(config, path)

        path.ancestors[reader_index].first
      end
```

Then replace the inline anchor computation in `_deepest_reader_name` (line 83) so the two cannot drift:

```ruby
      def self._deepest_reader_name(config, path, reader_index)
        return config.on.to_s.split(".").first.to_sym if reader_index == anchor_index(config, path)

        _reader_config(path.ancestors[reader_index].first).reader_as
      end
```

Leave the existing comment above `_deepest_reader_name` in place, and delete only the `anchor_index = …` local line.

- [ ] **Step 4: Run the new test, then the whole suite**

Run: `bundle exec rspec spec/axn/core/subfield_crossing_seam_spec.rb`
Expected: PASS (4 examples).

Run: `bundle exec rspec`
Expected: 5344 examples, 0 failures. This task changes no behavior, so any failure means the extraction is wrong — most likely an off-by-one in `anchor_index`.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/contract_for_subfields.rb spec/axn/core/subfield_crossing_seam_spec.rb
git commit -m "PRO-3068: extract the unnamed-crossing seam"
```

---

### Task 2: Reject a dotted tail that crosses a node with two reader names

**Files:**
- Modify: `lib/axn/core/contract/subfield_contradictions.rb:23-28` (the `check!` sequence)
- Modify: `lib/axn/core/ambient_context.rb:66`
- Modify: `spec/axn/internal/subfield_tree_spec.rb:225`
- Modify: `spec/axn/internal/reflection/schema_spec.rb:4022`
- Test: `spec/axn/core/contract/subfield_contradictions_spec.rb`

**Interfaces:**
- Consumes: `ContractForSubfields.crossed_node(config, path)` and `.deepest_reader_index(path)` from Task 1.
- Produces: `SubfieldContradictions.check!(field_configs, subfield_configs, crossings: true)` — the third argument is new; every existing caller keeps the default except the ambient one.

- [ ] **Step 1: Write the failing tests**

Append this block inside the top-level `RSpec.describe` in `spec/axn/core/contract/subfield_contradictions_spec.rb`:

```ruby
  describe "an ambiguous crossing (PRO-3068)" do
    # A dotted tail addresses the wire NODE; where two routes merged onto it, the reference names neither,
    # and `configs.first` settles it by declaration order.
    it "rejects a dotted on: whose tail crosses a node with two reader names" do
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash, preprocess: ->(h) { h.merge(src: "one") }
          expects :baz, on: :bar, as: :b2, type: Hash, preprocess: ->(h) { h.merge(src: "two") }
          expects :src, on: "foo.bar.baz", optional: true
        end
      end.to raise_error(ArgumentError, /reads through wire path "foo\.bar\.baz".*:b1 and :b2/m)
    end

    it "rejects it in the other declaration order too" do
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: :bar, as: :b2, type: Hash, preprocess: ->(h) { h.merge(src: "two") }
          expects :baz, on: "foo.bar", as: :b1, type: Hash, preprocess: ->(h) { h.merge(src: "one") }
          expects :src, on: "foo.bar.baz", optional: true
        end
      end.to raise_error(ArgumentError, /reads through wire path "foo\.bar\.baz"/)
    end

    it "rejects when the crossing is declared BEFORE the second route completes the merge" do
      # check! re-scans the whole candidate tree, so the later declaration that creates the ambiguity is
      # caught even though the crossing reference was legal when it was written.
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash
          expects :src, on: "foo.bar.baz", optional: true
          expects :baz, on: :bar, as: :b2, type: Hash
        end
      end.to raise_error(ArgumentError, /reads through wire path "foo\.bar\.baz"/)
    end

    it "rejects even when no route carries a transform" do
      # The defect is the ambiguous REFERENCE, not an observed divergence: routes that agree today diverge
      # the moment one gains a preprocess:, and two Procs could never be compared anyway.
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash
          expects :baz, on: :bar, as: :b2, type: Hash
          expects :src, on: "foo.bar.baz", optional: true
        end
      end.to raise_error(ArgumentError, /reads through wire path "foo\.bar\.baz"/)
    end

    it "accepts a descendant that anchors on the route it means" do
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash, preprocess: ->(h) { h.merge(src: "one") }
          expects :baz, on: :bar, as: :b2, type: Hash, preprocess: ->(h) { h.merge(src: "two") }
          expects :src, on: :b2, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a dotted on: rooted at the route's own reader" do
      # `on: "b2.deeper"` names route 2 at the root; the tail below it is implicit, so nothing is unnamed.
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash
          expects :baz, on: :bar, as: :b2, type: Hash
          expects :src, on: "b2.deeper", optional: true
        end
      end.not_to raise_error
    end

    it "accepts a tail over an implicit intermediate" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :count, on: "payload.meta", type: Integer, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a tail over a declared single-route node" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash
          expects :count, on: "payload.meta", type: Integer, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a crossing of a node whose routes share ONE reader name" do
      # A confirmation companion beside the author's own same-named declaration is two configs on one node,
      # but both answer to :password_confirmation — dispatch resolves by the reader-owner rule
      # (SubfieldTree.yields_reader_name?), which is order-independent, so nothing is ambiguous.
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :password, on: :bar, type: Hash, confirmation: true
          expects :password_confirmation, on: "foo.bar", type: Hash
          expects :src, on: "foo.bar.password_confirmation", optional: true
        end
      end.not_to raise_error
    end

    it "accepts an ambient crossing, which resolves by recipe rather than through a route" do
      # An ambient config never enters the shared tree, so resolve_parent reads the `on:` root through its
      # reader and digs every tail segment raw — no route's reader is ever picked.
      expect do
        build_axn do
          expects :meta, on: :ambient_context, type: Hash
          expects :thing, on: "ambient_context.meta", as: :a1, type: Hash, optional: true
          expects :thing, on: :meta, as: :a2, type: Hash, optional: true
          expects :leaf, on: "ambient_context.meta.thing", optional: true
        end
      end.not_to raise_error
    end
  end
```

- [ ] **Step 2: Run the tests to verify the rejections fail**

Run: `bundle exec rspec spec/axn/core/contract/subfield_contradictions_spec.rb -e "an ambiguous crossing"`
Expected: the five rejection examples FAIL ("expected ArgumentError but nothing was raised"); the five acceptance examples PASS.

- [ ] **Step 3: Add the check**

In `lib/axn/core/contract/subfield_contradictions.rb`, change `check!` to accept the flag and call the new check:

```ruby
        def check!(field_configs, subfield_configs, crossings: true)
          tree = Axn::Internal::SubfieldTree.build(field_configs, subfield_configs)
          check_unanswerable_segments!(tree) # first: an unreachable path moots any ambiguity on it
          check_ambiguous_crossings!(tree) if crossings
          check_conflicting_defaults!(tree)  # before dead-tolerance: an explicit conflict is the plainer diagnosis
          check_dead_nil_tolerance!(tree, field_configs)
        end
```

Then add, directly below `check!`:

```ruby
        # The AMBIGUOUS-CROSSING check (PRO-3068): a config whose dotted `on:` tail resolves its parent
        # THROUGH a wire node that answers to more than one reader name. A dotted tail addresses that node
        # by WIRE KEY, and a wire key names a node rather than a route — so where two routes merged onto it
        # the reference names neither, and `_deepest_reader_name` falls back to the node's first config.
        # Swapping the two route declarations then changes the value every descendant reads (that route's
        # `preprocess:`/`default:`/`model:` included) with nothing raised and the emitted schema identical
        # either way.
        #
        # Rejected as an ambiguous REFERENCE, not on whether the routes currently differ: routes that agree
        # today diverge the moment one gains a transform, and two Procs can never be compared. This is the
        # same standard `_validate_subfield_reader_names!` applies to a duplicate reader, which raises even
        # when either would have worked.
        #
        # Keyed on distinct reader NAMES rather than config count, because that is what dispatch consumes.
        # Where every config at the node answers to one name, `public_send` resolves it through the
        # reader-owner rule, whose order-independence SubfieldTree.yields_reader_name? documents — so an
        # inferred `confirmation:` companion sharing a node with the author's own same-named declaration is
        # unambiguous and stays legal.
        def check_ambiguous_crossings!(tree)
          tree.index.each do |config, path|
            next unless config.subfield? # a top-level config reads no segment, so it crosses nothing

            node = Axn::Core::ContractForSubfields.crossed_node(config, path)
            next if node.nil?

            readers = node.configs.map(&:reader_as).uniq
            next if readers.size < 2

            raise_ambiguous_crossing!(config, path, readers)
          end
        end

        def raise_ambiguous_crossing!(config, path, readers)
          # The crossed node sits at the deepest reader-bearing chain index, and wire_path is indexed to
          # match (wire_path[i] is the wire key of ancestors[i]'s node), so its own path is that prefix.
          # Rendered segment by segment: a declared name may hold bytes with no UTF-8 rendering, and
          # joining one into this message raw would raise Encoding::CompatibilityError from the reporting.
          depth = Axn::Core::ContractForSubfields.deepest_reader_index(path)
          crossed = path.wire_path[0..depth].map { |s| Axn::Internal::Reflection::PropertyNames.renderable_label(s) }.join(".")
          raise ArgumentError,
                "subfield #{config.field.inspect} (on #{config.on.inspect}) reads through wire path " \
                "#{crossed.inspect}, which two routes declared — they answer to " \
                "#{readers.map(&:inspect).join(' and ')}, and a dotted path names the wire NODE rather than " \
                "either route, so only declaration order decides which route's value is read (its " \
                "`preprocess:`, `default:` and `model:` included). Declare that wire key once, split the " \
                "routes onto distinct wire keys, or anchor this subfield on the route you mean " \
                "(`on: #{readers.first.inspect}`)."
        end
```

Finally, widen the module's own header comment (line 9), which currently opens `Declaration-time rejection of contradiction-only subfield contracts (PRO-2889).` — the module now also hosts an ambiguity rejection, which is a different kind of defect (a reference with two answers, not a contract with none):

```ruby
      # Declaration-time rejection of subfield contracts that cannot mean one thing: a contradiction-only
      # contract, whose every judgment reuses the canonical derivation in satisfiability mode
      # (unknowable-at-declaration counts as satisfiable — never a parallel re-derivation, the failure mode
      # that sank PRO-2877's pulled detectors), and an ambiguous route reference, whose answer would
      # otherwise be settled by declaration order. Walks a CANDIDATE tree (prospective configs included;
      # nothing committed) and raises ArgumentError on the first one it can prove. Side-effect-free:
      # inspects declared configs only, never runs user code.
```

- [ ] **Step 4: Opt the ambient tree out**

In `lib/axn/core/ambient_context.rb`, replace the `check!` call at line 66:

```ruby
          # `crossings: false`: an ambient config never enters the shared tree, so `resolve_parent`
          # resolves it by recipe — the `on:` root through its reader (which names exactly one config) and
          # every tail segment as a raw dig (which reads no reader at all). No route is ever picked here,
          # so a crossing reference cannot be ambiguous, and checking it would reject a contract that
          # resolves deterministically.
          Axn::Core::Contract::SubfieldContradictions.check!([_synthetic_ambient_root], ambient, crossings: false)
```

- [ ] **Step 5: Run the new tests**

Run: `bundle exec rspec spec/axn/core/contract/subfield_contradictions_spec.rb -e "an ambiguous crossing"`
Expected: PASS (10 examples).

- [ ] **Step 6: Re-anchor the two affected fixtures**

Both declare a deep config through a merged `:baz` node. Re-anchor each on route 1's reader, which keeps the identical wire path (`foo.bar.baz.x.y`) and preserves each example's point — that route 2's non-nestable shape member still blocks the deep structure even though the deep config attached through route 1.

In `spec/axn/internal/subfield_tree_spec.rb:225` (route 1 has no `as:`, so its reader is `:baz`):

```ruby
        expects :y, on: "baz.x"
```

In `spec/axn/internal/reflection/schema_spec.rb:4022` (route 1 is `as: :baz_route1`):

```ruby
          expects :y, on: "baz_route1.x"                                                   # implicit x under baz + grandchild y
```

- [ ] **Step 7: Run the full suite**

Run: `bundle exec rspec`
Expected: 5344 examples, 0 failures. If anything besides those two fixtures fails, a legal contract is being rejected — read the message and check it against the acceptance examples above before loosening the check.

- [ ] **Step 8: Audit the guard by mutation, per AGENTS.md**

Delete the `check_ambiguous_crossings!` line from `check!`, run `bundle exec rspec spec/axn/core/contract/subfield_contradictions_spec.rb`, and confirm the five rejection examples fail. Restore it.

Then inverse-mutate to audit the controls: change `next if readers.size < 2` to `next if readers.size < 1` (an over-eager guard that fires on any crossed node) and confirm the single-route and implicit-intermediate acceptances fail. Restore it. Record both results in the commit message.

- [ ] **Step 9: Commit**

```bash
git add lib/axn/core/contract/subfield_contradictions.rb lib/axn/core/ambient_context.rb \
        spec/axn/core/contract/subfield_contradictions_spec.rb \
        spec/axn/internal/subfield_tree_spec.rb spec/axn/internal/reflection/schema_spec.rb
git commit -m "PRO-3068: reject a dotted on: tail that crosses a node with two reader names"
```

---

### Task 3: Select the model's id-token route by name, not by declaration order

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb:434-472` (`sibling_id_configs` and its comment)
- Modify: `lib/axn/internal/reflection/schema.rb:546-550` (`sibling_id_rescued?`'s last line)
- Test: `spec/axn/core/validations/on_subfields_spec.rb`

**Interfaces:**
- Produces: `Axn::Core::ContractForSubfields.id_token_routes(model_config, candidates) -> Array<FieldConfig>` — the shared precedence, consumed by `sibling_id_configs` and by `Schema.sibling_id_rescued?`.

- [ ] **Step 1: Write the failing tests**

Two of these replace an existing example. First, **invert** `spec/axn/core/validations/on_subfields_spec.rb:2272` — the example currently titled `"still rescues an ABSENT merged id via a different route's credited default"`. Replace the whole example with:

```ruby
      it "does NOT rescue an absent id through an aliased route on another spelling" do
        # Both id routes are `as:`-renamed, so neither is the model's own route (`on: :thing`) nor owns the
        # canonical `company_id` reader the model's generated companion answers to. Nothing points either at
        # this model, and post-PRO-2903 a `default:` is a fact about its OWN reader — nothing is written to
        # the wire — so the lookup falls back to the caller's raw token, which is absent.
        finder = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("MergedAbsentCo", finder)
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload, allow_blank: true
          expects :company_id, on: "payload.thing", optional: true, default: 42, as: :pt_company_id
          expects :company_id, on: :thing, optional: true, preprocess: ->(v) { v == "none" ? nil : v }, as: :t_company_id
          expects :company, on: :thing, model: { klass: MergedAbsentCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(payload: { thing: {} }) # id omitted entirely (parent present, id absent)

        expect(result).to be_ok
        expect(result.cid).to be_nil
      end

      it "rescues an absent id through the route that OWNS the canonical <field>_id reader" do
        # Same shape, except the off-route default keeps the `company_id` name — so it IS the reader the
        # model's generated companion would have answered to, and borrowing it is the documented contract
        # rather than a hidden coupling.
        finder = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("NamedAbsentCo", finder)
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload, allow_blank: true
          expects :company_id, on: "payload.thing", optional: true, default: 42
          expects :company, on: :thing, model: { klass: NamedAbsentCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(payload: { thing: {} })

        expect(result).to be_ok
        expect(result.cid).to eq(42)
      end

The own-route-beats-name-owner case needs two `default:` declarations on one merged node to be observable, which PRO-2901's check still rejects at this point in the plan — so that example belongs to Task 4, which deletes that check. Do not add it here, and do not add it skipped.
- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "aliased route on another spelling"`
Expected: FAIL — `expected: nil, got: 42` (the aliased route still rescues today).

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "OWNS the canonical"`
Expected: PASS already (an unaliased off-route default is the name owner, so this is a control that must not move).

- [ ] **Step 3: Add the shared precedence and consume it in `sibling_id_configs`**

In `lib/axn/core/contract_for_subfields.rb`, replace the whole comment block and body of `sibling_id_configs` (lines 434-472) with:

```ruby
      # The routes that may supply a `model:` field's `<field>_id` lookup token, in the order
      # `_declared_id_token` reads them. All routes of a merged id node read the SAME wire key, differing
      # only in their coerce:/preprocess:/default:, so route choice is purely "which transform interprets
      # that one wire value" — and both selectors below pick BY NAME, so declaration order never decides it.
      #
      #   * the id declared on the model's OWN route is AUTHORITATIVE: its transform is this model field's
      #     canonical id, the reader user code reads for it. A present token it maps to nil is genuinely nil
      #     for this model (_declared_id_token stops there), never re-read through another route. At depth 0
      #     every config carries `on: nil`, so a top-level `<field>_id` is always this case.
      #   * otherwise the route that OWNS the canonical `<field>_id` reader — `model_id_key(reader_as)`, the
      #     name the model's own generated companion answers to. Reader names are unique, so this selects at
      #     most one config: the model borrows a reader the author declared under exactly that name, which is
      #     what makes PRO-2910's "the token agrees with the `<field>_id` reader" a promise rather than a
      #     coupling.
      #
      # An `as:`-renamed route on some other spelling is neither, and supplies nothing. Nothing points it at
      # this model, and a `default:` on it is a fact about ITS reader — nothing is ever written to the wire —
      # so crediting it would mean this model resolving through another route's reader.
      #
      # Empty when no eligible `<field>_id` is declared (the caller's raw token off the parent carries no
      # transform) or when the config isn't in either subfield index (an ambient config falls back to the
      # ambient-scoped tree).
      def self.sibling_id_configs(action, config)
        path = action.class._resolved_subfields.index[config] || action.class._ambient_subfield_tree.index[config]
        return [] if path.nil?

        id_key = Axn::Internal::FieldConfig.model_id_key(config.field)
        # Candidate sibling `<field>_id` configs: another top-level root at depth 0 (a declared field, not a
        # child of parent_node), else the children of the leaf's own wire parent.
        candidates =
          if path.ancestors.empty?
            action.class.internal_field_configs.select { |c| c.field == id_key }
          else
            path.parent_node.children[id_key.to_sym]&.configs || []
          end

        id_token_routes(config, candidates)
      end

      # The token-route precedence itself, over an already-gathered candidate list — shared with the
      # declaration-time rescue credit (Reflection::Schema.sibling_id_rescued?) so the schema layer cannot
      # credit a rescue through a route the lookup will not read.
      def self.id_token_routes(config, candidates)
        own_route = candidates.find { |c| c.on.to_s == config.on.to_s }
        named_route = candidates.find { |c| c.reader_as == Axn::Internal::FieldConfig.model_id_key(config.reader_as) }

        [own_route, named_route].compact.uniq
      end
```

Then update the `_declared_id_token` comment (line 396) so it stops describing the removed ordering: replace `an ABSENT raw id reads ONLY defaulted routes (Schema.usable_id_token_default?) — the PRO-2889 omitted-id rescue — and skips the rest` with `an ABSENT raw id reads ONLY defaulted routes (Schema.usable_id_token_default?) — the PRO-2889 omitted-id rescue — and skips a route that would resolve nil anyway AND would fire an unguarded `preprocess:` on the absent value`.

- [ ] **Step 4: Narrow the rescue credit in lockstep**

In `lib/axn/internal/reflection/schema.rb`, replace `sibling_id_rescued?`'s final two lines (546-550) with:

```ruby
          sibling = parent.children[Internal::FieldConfig.model_id_key(key)]
          return false if sibling.nil?

          # Credited only through the route the LOOKUP will actually read the token from, asked per model
          # route on the node via the one precedence both layers share — otherwise this credits a rescue
          # that never happens, and a nil-tolerant model whose subtree needs it would be accepted at
          # declaration and resolve nil at run time.
          node.configs.select { |c| c.validations[:model] }.any? do |model_config|
            Axn::Core::ContractForSubfields.id_token_routes(model_config, sibling.configs).any? { |c| usable_id_token_default?(c) }
          end
```

Also update the third bullet of that method's comment (line 539) to name the precedence rather than "a sibling `<key>_id` child carries a default": `a sibling <key>_id route that this model's lookup would read the token from (ContractForSubfields.id_token_routes) carries a default usable as one (usable_id_token_default? rejects a blank literal — the model resolver blank-guards the id)`.

Do **not** add a `require` for `contract_for_subfields` here — `contract_for_subfields.rb` already requires this file, so the reference must stay a call-time constant lookup (as `schema.rb:793` already does for `Axn::Core::Contract`).

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb`
Expected: PASS, with the one skip from Step 1.

Run: `bundle exec rspec`
Expected: 5344 examples, 0 failures, 1 pending.

Any NEW failure here is the declaration-time consequence to expect: a nil-tolerant `model:` that stood only because an aliased off-route default was credited with rescuing it now raises `raise_dead_tolerance!`. That is the intended louder signal — fix the fixture by moving the default onto the model's own route or dropping its `as:`, and do not loosen the credit.

- [ ] **Step 6: Confirm the controls did not move**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb:2196 spec/axn/core/validations/on_subfields_spec.rb:2530 spec/axn/core/validations/on_subfields_spec.rb:2691 spec/axn/core/top_level_write_back_spec.rb:725`
Expected: PASS. These pin the behavior that must survive — both id routes aliased with the model preferring its own route, the consistency check reading that same route, PRO-2910's single-run stateful preprocess, and the top-level aliased id (where `on: nil` on both sides makes the declared id the own route). Line numbers shift as you edit; if one misses, find the example by name rather than assuming it was deleted.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract_for_subfields.rb lib/axn/internal/reflection/schema.rb \
        spec/axn/core/validations/on_subfields_spec.rb
git commit -m "PRO-3068: select a model's id-token route by name, never by declaration order"
```

---

### Task 4: Delete PRO-2901's blanket two-default rejection

**Files:**
- Modify: `lib/axn/core/contract/subfield_contradictions.rb:23-78`
- Modify: `spec/axn/core/contract/subfield_contradictions_spec.rb:460-600` (the PRO-2901 block)
- Modify: `spec/axn/core/validations/on_subfields_spec.rb:2819`
- Modify: `spec/axn/core/validations/on_subfields_spec.rb` (unskip Task 3's example)

**Interfaces:**
- Consumes: `check_ambiguous_crossings!` from Task 2, which is what still rejects the genuinely ambiguous shapes.
- Produces: nothing new. `check!` loses one call; three methods are deleted.

- [ ] **Step 1: Convert the specs first, so they fail**

In `spec/axn/core/contract/subfield_contradictions_spec.rb`, the PRO-2901 block's rejection examples become acceptances. Replace the example at line 474 (`"rejects two literal defaults on the same merged wire node"`) and its Proc-default sibling with:

```ruby
    # Two differently-defaulted readers over one wire slot is a coherent contract: each reader resolves its
    # own default on its own read path, nothing is written to the wire, and `node_optional?`'s satisfiability
    # credit gets MORE accurate (both routes rescue an omitted slot, not just one).
    it "accepts two literal defaults on the same merged wire node" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: :meta, as: :meta_count, default: 42, optional: true, type: Integer
          expects :count, on: "payload.meta", default: "", optional: true
        end
      end.not_to raise_error
    end

    it "accepts two Proc defaults on the same merged wire node" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: :meta, as: :meta_count, default: -> { 1 }, optional: true
          expects :count, on: "payload.meta", default: -> { 2 }, optional: true
        end
      end.not_to raise_error
    end

    # What still stands: a descendant reading DOWN through that node names neither route (PRO-3068).
    it "rejects a descendant that crosses a doubly-defaulted merged node" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: :meta, as: :meta_count, default: { a: 1 }, optional: true, type: Hash
          expects :count, on: "payload.meta", default: { a: 2 }, optional: true, type: Hash
          expects :a, on: "payload.meta.count", optional: true
        end
      end.to raise_error(ArgumentError, /reads through wire path "payload\.meta\.count"/)
    end
```

Keep the existing "accepts a merged node where only one route carries a default" and "…where neither route carries a default" examples as they are — they stay passing throughout.

In `spec/axn/core/validations/on_subfields_spec.rb:2819`, the example expecting `/conflicting default:/` becomes an acceptance. Its model sits on `:thing` and so does the defaulted `thing_company_id` route, which makes that route the own route and the lookup unambiguous:

```ruby
      it "resolves a merged doubly-defaulted id through the model's own route" do
        # Two defaulted routes onto one `company_id` wire key, neither owning the canonical reader name. The
        # own route (`on: :thing`, beside the model) supplies the token by name, so nothing is order-decided.
        finder = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def name = "acme"
          def self.fetch(id) = new(id)
        end
        stub_const("SiblingCo", finder)
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload # untyped
          expects :company_id, on: "payload.thing", optional: true, default: "", as: :pt_company_id
          expects :company_id, on: :thing, type: Integer, default: 42, as: :thing_company_id
          expects :company, on: :thing, model: { klass: SiblingCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, method_call: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(payload: { thing: { other: 1 } })

        expect(result).to be_ok
        expect(result.cid).to eq(42)
      end
```

Note that fixture's original comment claimed `untyped, so an opaque parent refuses the write-back`; the write-back it referred to was deleted in PRO-2903/2908, so the replacement above drops it rather than carrying it forward.

Finally, add the example Task 3 deferred to here, because it needs two defaults on one merged node to be observable. Put it beside Task 3's other token-route examples in `spec/axn/core/validations/on_subfields_spec.rb`:

```ruby
      it "prefers the model's OWN route over the canonically-named one" do
        # Both selectors can match at once; the own route is authoritative, exactly as it is for a present
        # token, so the transform declared beside the model is the one the finder consumes.
        finder = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("OwnRouteCo", finder)
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload, allow_blank: true
          expects :company_id, on: "payload.thing", optional: true, default: 42
          expects :company_id, on: :thing, optional: true, default: 7, as: :t_company_id
          expects :company, on: :thing, model: { klass: OwnRouteCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(payload: { thing: {} })

        expect(result).to be_ok
        expect(result.cid).to eq(7)
      end
```


- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/axn/core/contract/subfield_contradictions_spec.rb spec/axn/core/validations/on_subfields_spec.rb`
Expected: the converted acceptances FAIL with `ArgumentError: conflicting default: declarations on wire path …`; the new crossing rejection PASSES already (Task 2 supplied it).

- [ ] **Step 3: Delete the check and its helpers**

In `lib/axn/core/contract/subfield_contradictions.rb`:

Remove the `check_conflicting_defaults!(tree)` line from `check!`, leaving:

```ruby
        def check!(field_configs, subfield_configs, crossings: true)
          tree = Axn::Internal::SubfieldTree.build(field_configs, subfield_configs)
          check_unanswerable_segments!(tree) # first: an unreachable path moots any ambiguity on it
          check_ambiguous_crossings!(tree) if crossings
          check_dead_nil_tolerance!(tree, field_configs)
        end
```

Delete `check_conflicting_defaults!`, `raise_conflicting_defaults!` and `describe_default` outright, along with their comment blocks (lines 30-78 in the pre-Task-2 file). Per AGENTS.md's pre-alpha convention these are removed rather than tombstoned. `describe_default` has no other caller — confirm with `grep -rn "describe_default\|conflicting_defaults" lib/ spec/` before committing, and expect zero hits.

The PRO-2901 parenthetical about `usable_id_token_default?` sites lives inside the deleted comment block, so it goes with it — nothing else in this file references that check.

- [ ] **Step 4: Run the suite**

Run: `bundle exec rspec`
Expected: 5344 examples, 0 failures, 0 pending.

- [ ] **Step 5: A/B the guard change against the prior commit**

This task removes a guard, so per AGENTS.md confirm that only the examples whose behavior actually moved are the ones that flip. Read `internal-docs/agent-notes/ab-testing-guards.md` first — it covers the stale-lockfile and `$LOAD_PATH` cross-tree pitfalls. Use a throwaway worktree for the baseline; never stash-pop to switch commits.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract/subfield_contradictions.rb \
        spec/axn/core/contract/subfield_contradictions_spec.rb \
        spec/axn/core/validations/on_subfields_spec.rb
git commit -m "PRO-3068: drop the blanket two-default rejection on a merged node"
```

---

### Task 5: Docs and CHANGELOG

**Files:**
- Modify: `docs/reference/class.md:330`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the final behavior from Tasks 2-4. Nothing consumes this task.

- [ ] **Step 1: State the invariant where dotted `on:` is introduced**

`docs/reference/class.md:330` already explains that the root segment must be a declared field and that later segments name intermediate keys. Append to that paragraph:

```markdown
A dotted tail addresses the wire **node**, not a route to it — so where the same wire key was declared twice (two spellings of one route, distinguishable only by `as:`), a dotted reference through it names neither and is refused at declaration. Anchor on the route you mean instead (`on: :<that route's reader>`).
```

- [ ] **Step 2: Add the CHANGELOG entries**

Under `## Unreleased`, in the existing `### Fixed` section, add:

```markdown
* [BREAKING] A dotted `on:` path may no longer read through a wire node that two routes declared. `expects :baz, on: "foo.bar", as: :b1` beside `expects :baz, on: :bar, as: :b2` is one merged wire node with two readers, and a third declaration reading down through it — `expects :src, on: "foo.bar.baz"` — named the node rather than either route, so the first-declared route's `preprocess:`/`default:`/`model:` supplied the value to everything below it. Swapping those two lines silently changed what `src` resolved to, with nothing raised and the emitted schema identical either way. Such a reference now raises at declaration naming both routes. Anchor on the route you mean (`on: :b2`), declare the wire key once, or split the routes onto distinct wire keys. A dotted tail over an *undeclared* intermediate is untouched (that is what implicit intermediates are for), as is a tail over a single-route declared node, and so is a node whose routes share one reader name — an inferred `confirmation:` companion beside your own same-named declaration dispatches through the reader-owner rule, which declaration order cannot change (see PRO-3068).
* [BREAKING] A `model:` field's `<field>_id` lookup token now comes only from the id route declared beside it (same `on:`) or the route that owns the canonical `<field>_id` reader name. Previously any route declaring that wire key could supply it, chosen by declaration order among defaulted routes — so `expects :company_id, on: "payload.thing", as: :other_id, default: 7` supplied the token for `expects :company, on: :thing, model: Company` even though nothing pointed it at that model and its reader was named something else. A `default:` resolves on the read path and is never written to the wire, so it is a fact about its own reader; an `as:`-renamed route on another spelling now supplies nothing and the caller's raw token is used instead. Both selectors are single-valued by construction (reader names are unique; a second config on the same route with the same wire key is already a duplicate-field error), so no ambiguity is left to resolve by order. If you relied on the old rescue, declare the default on the model's own route or drop its `as:`. A nil-tolerant `model:` that stood only because such a route was credited with rescuing it now raises the existing dead-tolerance error at declaration rather than resolving nil at run time (see PRO-3068).
* [INTERNAL] Two `default:` declarations on one merged wire node are legal again. The rejection added for PRO-2901 was justified by an inbound write-back — the first-declared default writing the shared wire key — which PRO-2903/2908 removed; each route now resolves its own default on its own read path, and the one consumer that still picked among them by order is fixed above. One route raw with a String default beside one coerced with an Integer default is a coherent contract (see PRO-3068).
```

- [ ] **Step 3: Verify the docs build and the suite is clean**

Run: `bundle exec rspec`
Expected: 5344 examples, 0 failures.

Run the Rails suite, which needs its own Gemfile pinned explicitly or it picks up the root one and fails to boot:

```bash
cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec
```

Expected: PASS. This work touches no Rails-specific path, so a failure here means something unrelated broke.

Run: `bundle exec rubocop lib spec`
Expected: no offenses. The new methods are small; if `Metrics/MethodLength` fires on `check_ambiguous_crossings!`, extract the reader-name comparison rather than adding a disable comment.

- [ ] **Step 4: Commit**

```bash
git add docs/reference/class.md CHANGELOG.md
git commit -m "PRO-3068: document the node-vs-route invariant and the id-token precedence"
```

---

## Verification checklist

Before opening the PR:

- [ ] `bundle exec rspec` — 5344 examples, 0 failures, 0 pending.
- [ ] `spec_rails/dummy_app` suite passes with `BUNDLE_GEMFILE=Gemfile`.
- [ ] `bundle exec rubocop lib spec` — no offenses.
- [ ] `grep -rn "describe_default\|conflicting_defaults" lib/ spec/` — zero hits.
- [ ] `grep -rn "PRO-2901" lib/` — any survivor must still be true; the `sibling_id_configs` reference to it is gone with Task 3's rewrite.
- [ ] The mutation audit from Task 2 Step 8 is recorded, both directions.
- [ ] The PR description links https://linear.app/teamshares/issue/PRO-3068/axn-a-merged-wire-node-picks-its-supplying-config-by-declaration-order and names the two `[BREAKING]` changes plus the relaxation.
- [ ] The follow-up ticket from the design doc's "Out of scope" is filed: the emitted property at a merged node is built from `property_representative`/`model_configs.first`, so `of:`, `shape:`, `default:` and the description are declaration-order-dependent in reflection. Title it `[Axn]`, assign Kali, label Axn.
