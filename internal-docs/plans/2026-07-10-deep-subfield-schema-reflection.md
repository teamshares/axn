# Deep Subfield Nesting in Schema Reflection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Represent deep subfield nesting (dotted `on:` paths, subfields of subfields, dotted field names) in `Axn::Reflection::Schema.build_input`, with requiredness/nullability propagated transitively, and narrow the dropped-subfield warning to structurally unrepresentable configs.

**Architecture:** A new `Axn::Reflection::SubfieldTree` pre-pass resolves every subfield config's `on:` chain once into per-root trees keyed by wire key (translating reader aliases exactly once) and computes the dropped set. `Schema.build_input` then emits recursively over the tree; requiredness/nullability derive from one recursion (`node_optional?` / `subtree_requires_presence?`). Emission, derivation, and `dropped_deep_subfields` all read the same tree, so they cannot drift.

**Tech Stack:** Ruby gem (axn), RSpec, RuboCop. No Rails dependency (this code must work outside Rails; `spec/` is the non-Rails suite).

**Spec:** `internal-docs/specs/2026-07-10-deep-subfield-schema-reflection-design.md` — read it before starting. Ticket: [PRO-2872](https://linear.app/teamshares/issue/PRO-2872/axn-represent-deep-subfield-nesting-in-schema-reflection).

## Global Constraints

- **Reflection is side-effect-free**: never run user code (no custom `validate:`/`model:` lookups/`if:`/dynamic options, no `==` on user objects — identity checks only, no `empty?` on non-literal containers). See the existing patterns in `lib/axn/reflection/schema.rb`.
- **Requiredness is derived from declared signals, not by validating** (header of `schema.rb`). Divergences must be stricter-than-runtime (schema requires more than runtime does), never looser.
- **Runtime invariants this plan relies on** (verify, don't re-derive): declaration rejects `default:`/`preprocess:`/`sensitive:` on any nested parent (`lib/axn/core/contract_for_subfields.rb:129-133`), so depth ≥ 2 subfields never carry defaults; deep/dotted ambient nesting is rejected at declaration; a nil parent yields every descendant absent (`lib/axn/core/field_resolvers.rb:24`, PRO-2857).
- **Wire keys vs readers**: `on:` names a *reader* (`reader_as`, the `as:`/`prefix:` alias); schema properties are keyed by *wire key* (`config.field`). Translation happens only in `SubfieldTree`.
- **TDD**: failing test first for every behavior change. Run `bundle exec rspec <file>` for the file under test; the full suite is `bundle exec rspec`. Lint with `bundle exec rubocop`.
- **Comments describe current behavior + intrinsic why** — never "used to X, now Y", never review-round references.
- **No manual line breaks in Markdown prose** (docs files): one line per paragraph.
- Behavior changes in this plan are intentional and documented per task: existing specs that assert the *old* single-level limitation are updated in the same task that changes the behavior — never deleted without replacement coverage.

---

### Task 1: `SubfieldTree` builder

**Files:**
- Create: `lib/axn/reflection/subfield_tree.rb`
- Create: `spec/axn/reflection/subfield_tree_spec.rb`
- Modify: `lib/axn/reflection/schema.rb:1-5` (add require)

**Interfaces:**
- Consumes: `field_configs` (`Axn::Core::Contract::FieldConfig`, has `.field`, `.reader_as`, `.validations`), `subfield_configs` (`Axn::Core::ContractForSubfields::SubfieldConfig`, has `.field`, `.on`, `.reader_as`, `.validations`, `.default`); `Axn::Reflection::Schema.nestable_as_object?(config)` (existing).
- Produces: `SubfieldTree.build(field_configs, subfield_configs)` → `SubfieldTree::Result` with `.roots` (`Hash{Symbol reader_as => Node}` — one entry per top-level field config) and `.dropped` (`Array<SubfieldConfig>` — deep configs with no schema representation, insertion order). `Node` responds to `.configs` (`Array<SubfieldConfig>`, empty for implicit nodes), `.children` (`Hash{Symbol wire_key => Node}`), `.config` (first config or nil), `.implicit?`. Later tasks call `SubfieldTree.build` from `Schema.build_input` and `Schema.dropped_deep_subfields`.

- [ ] **Step 1: Write the failing specs**

Create `spec/axn/reflection/subfield_tree_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::SubfieldTree do
  def tree_for(klass)
    described_class.build(klass.internal_field_configs, klass.subfield_configs)
  end

  it "groups shallow subfields as direct children of their top-level root, keyed by wire key" do
    klass = Class.new do
      include Axn
      expects :address, type: Hash
      expects :zip, on: :address, type: String
    end
    tree = tree_for(klass)

    root = tree.roots[:address]
    expect(root.config.field).to eq(:address)
    expect(root.children.keys).to eq([:zip])
    expect(root.children[:zip].config.field).to eq(:zip)
    expect(root.children[:zip]).not_to be_implicit
    expect(tree.dropped).to eq([])
  end

  it "expands a dotted on: path into implicit intermediate nodes" do
    klass = Class.new do
      include Axn
      expects :payload, type: Hash
      expects :zip, on: "payload.address", type: String
    end
    tree = tree_for(klass)

    address = tree.roots[:payload].children[:address]
    expect(address).to be_implicit
    expect(address.children[:zip].config.field).to eq(:zip)
    expect(tree.dropped).to eq([])
  end

  it "expands a dotted field name into implicit intermediate nodes under the parent" do
    klass = Class.new do
      include Axn
      expects :foo, type: Hash
      expects "bar.baz", on: :foo, type: String
    end
    tree = tree_for(klass)

    bar = tree.roots[:foo].children[:bar]
    expect(bar).to be_implicit
    expect(bar.children[:baz].config.field).to eq(:"bar.baz")
  end

  it "anchors a subfield-of-a-subfield under the parent subfield's node, resolving on: through the READER (as: alias) while keying children by WIRE KEY" do
    klass = Class.new do
      include Axn
      expects :payload, type: Hash, as: :data
      expects :meta, on: :data, type: Hash, as: :info
      expects :id, on: :info, type: Integer
    end
    tree = tree_for(klass)

    # Roots are keyed by reader_as (:data); children by wire key (:meta, :id).
    meta = tree.roots[:data].children[:meta]
    expect(meta.config.field).to eq(:meta)
    expect(meta.children[:id].config.field).to eq(:id)
  end

  it "merges two declaration routes to the same wire path onto one node, in declaration order" do
    klass = Class.new do
      include Axn
      expects :foo, type: Hash
      expects "bar.baz", on: :foo, type: String
      expects :bar, on: :foo, type: Hash
    end
    tree = tree_for(klass)

    bar = tree.roots[:foo].children[:bar]
    # The implicit node created by "bar.baz" and the explicit :bar declaration are the same node.
    expect(bar.configs.map(&:field)).to eq([:bar])
    expect(bar).not_to be_implicit
    expect(bar.children[:baz].config.field).to eq(:"bar.baz")
  end

  it "silently skips an on: :ambient_context subfield with no declared ambient field (excluded, not dropped)" do
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, type: Integer
    end
    tree = tree_for(klass)

    expect(tree.roots).to eq({})
    expect(tree.dropped).to eq([])
  end

  describe "dropped (deep configs with no JSON-object representation)" do
    it "drops a deep config under a model: ancestor but keeps it in the tree for requiredness" do
      klass = Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id, :profile), finder: :find }
        expects :name, on: "user.profile", type: String
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:name])
      expect(tree.roots[:user].children[:profile].children[:name].config.field).to eq(:name)
    end

    it "drops a deep config under a non-object (Array) ancestor, even one declared AFTER the deep config" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :zip, on: "payload.items", type: String
        expects :items, on: :payload, type: Array
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:zip])
    end

    it "drops a deep config under a mixed-union ancestor" do
      klass = Class.new do
        include Axn
        expects :payload, type: [Hash, Array]
        expects :id, on: "payload.meta", type: Integer
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:id])
    end

    it "drops a deep config whose implicit intermediate collides with a non-object shape member" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: String
        end
        expects "bar.baz", on: :payload, type: String
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:"bar.baz"])
    end

    it "does not drop a representable deep chain (object-shaped explicit ancestors)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash
        expects :id, on: :meta, type: Integer
        expects :deep, on: "payload.meta", type: String
        expects "bar.baz", on: :payload
      end
      tree = tree_for(klass)

      expect(tree.dropped).to eq([])
    end

    it "never drops a depth-1 subfield, even under a non-object parent (silent omission is preserved)" do
      klass = Class.new do
        include Axn
        expects :items, type: Array
        expects :length, on: :items, type: Integer
      end
      tree = tree_for(klass)

      expect(tree.dropped).to eq([])
    end
  end
end
```

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/axn/reflection/subfield_tree_spec.rb`
Expected: FAIL with `uninitialized constant Axn::Reflection::SubfieldTree` (NameError).

(The shape-block syntax used above — `expects :payload, type: Hash do … field :bar, type: String … end` — is the codebase's real shape DSL; see `spec/axn/reflection/schema_spec.rb:1114` for the canonical example.)

- [ ] **Step 3: Implement `SubfieldTree`**

Create `lib/axn/reflection/subfield_tree.rb`:

```ruby
# frozen_string_literal: true

module Axn
  module Reflection
    # Groups an Axn's subfield configs into per-root trees keyed by WIRE KEY (the JSON property name
    # a client sends), resolving each config's `on:` chain once. Emission, requiredness derivation,
    # and the dropped-subfield query all read the same finished tree, so they cannot drift.
    #
    # `on:` names a READER (`reader_as` — the `as:`/`prefix:` alias when present); schema properties
    # are keyed by wire key (`field`). This builder is the single place that translation happens: the
    # root `on:` segment is looked up among top-level readers first, then subfield readers (a subfield
    # anchor attaches the config beneath that subfield's own resolved node). Remaining dotted `on:`
    # segments and any dotted prefix of the field name become IMPLICIT nodes — intermediate keys with
    # no declaration of their own.
    #
    # Side-effect-free: inspects declared configs only; never runs user code.
    module SubfieldTree
      # `configs` is empty for an implicit node. Multiple configs on one node means the same wire
      # path was declared via two routes (e.g. `expects "bar.baz", on: :foo` and `expects :baz,
      # on: :bar`); runtime validates each independently, so consumers must honor all of them.
      Node = Data.define(:configs, :children) do
        def config = configs.first
        def implicit? = configs.empty?
      end

      Result = Data.define(:roots, :dropped)

      module_function

      def build(field_configs, subfield_configs)
        roots = field_configs.to_h { |c| [c.reader_as, Node.new(configs: [c], children: {})] }
        by_reader = {} # subfield reader_as => {node:, hops:} — anchor targets for a subfield-of-a-subfield
        deep_paths = [] # [config, hops] judged only once the tree is COMPLETE (an ancestor's type may be declared after the deep config)

        Array(subfield_configs).each do |config|
          root_key, *on_rest = config.on.to_s.split(".").map(&:to_sym)
          anchor_hops = []
          anchor = roots[root_key]
          if anchor.nil? && (entry = by_reader[root_key])
            anchor_hops = entry[:hops]
            anchor = entry[:node]
          end
          # Only a bare `on: :ambient_context` with no declared ambient field lands here — deliberately
          # excluded from the schema (EXCLUDED_FROM_INPUT_SCHEMA), so it is neither attached nor dropped.
          next if anchor.nil?

          segments = on_rest + config.field.to_s.split(".").map(&:to_sym)
          hops = anchor_hops.dup
          node = anchor
          segments[0..-2].each do |seg|
            hops << [node, seg]
            node = (node.children[seg] ||= Node.new(configs: [], children: {}))
          end
          leaf_key = segments.last
          hops << [node, leaf_key]
          leaf = (node.children[leaf_key] ||= Node.new(configs: [], children: {}))
          leaf.configs << config

          # Only a non-dotted field name gets a real reader method, so only it can anchor a later
          # `on:` (see ContractForSubfields#_define_subfield_reader).
          by_reader[config.reader_as.to_sym] = { node: leaf, hops: } unless config.field.to_s.include?(".")
          # Shallow (single hop off a top-level root) configs are always representable; only deeper
          # paths are candidates for dropping.
          deep_paths << [config, hops] if hops.size > 1
        end

        Result.new(roots:, dropped: compute_dropped(deep_paths))
      end

      # A deep config is dropped when any node it passes THROUGH (each hop's parent; never the leaf
      # itself) can't hold JSON object properties. Judged on the finished tree so declaration order
      # doesn't matter.
      def compute_dropped(deep_paths)
        deep_paths.filter_map do |config, hops|
          config if hops.any? { |node, key| blocking_ancestor?(node, key) }
        end
      end

      # An explicit ancestor blocks nesting when it has `model:` (the client sends `<field>_id`, not
      # the object) or isn't nestable as an object (non-object type, or a mixed union). An implicit
      # ancestor never blocks (a runtime dig through it presumes hash access) — but descending into an
      # IMPLICIT child whose key collides with a non-object `shape:` member does: the member property
      # already claims that key with a non-object type, so the deep structure has nowhere to live.
      def blocking_ancestor?(node, key)
        return true if node.configs.any? { |c| c.validations[:model] || !Schema.nestable_as_object?(c) }
        return false unless node.children[key]&.implicit?

        node.configs.any? do |c|
          member = Array(c.validations.dig(:shape, :members)).find { |m| m.field.to_sym == key }
          member && !Schema.nestable_as_object?(member)
        end
      end
    end
  end
end
```

Add the require at the top of `lib/axn/reflection/schema.rb` (after `require "time"`):

```ruby
require "axn/reflection/subfield_tree"
```

Implementation notes:
- `Data.define` members are frozen references, but the `configs` array and `children` hash *contents* are deliberately mutated during build — this matches how the tree grows. Do not reassign members.
- `Schema.nestable_as_object?` accepts anything responding to `.validations` — shape members are field-config-like, so they work as-is.

- [ ] **Step 4: Run specs to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/subfield_tree_spec.rb`
Expected: PASS (all).

Also run: `bundle exec rspec spec/axn/reflection/schema_spec.rb`
Expected: PASS — nothing consumes the tree yet.

- [ ] **Step 5: Lint and commit**

Run: `bundle exec rubocop lib/axn/reflection/subfield_tree.rb spec/axn/reflection/subfield_tree_spec.rb`
Expected: no offenses.

```bash
git add lib/axn/reflection/subfield_tree.rb spec/axn/reflection/subfield_tree_spec.rb lib/axn/reflection/schema.rb
git commit -m "PRO-2872: Add SubfieldTree — path-keyed subfield grouping for schema reflection

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Recursive emission in `Schema.build_input`

**Files:**
- Modify: `lib/axn/reflection/schema.rb` (header comment `:11-22`, `build_input` `:49-90`, `shallow_subfields` `:92-96` deleted, `dropped_deep_subfields` `:98-116`, `required_child?` `:179-195`, `field_optional?` `:202-225`, `apply_nested_subfields!` `:287-331`, `apply_model_id_requiredness!` `:543-568`)
- Modify: `lib/axn/core/schema_reflection.rb:28-44` (warning text)
- Modify: `spec/axn/reflection/schema_spec.rb` (new deep-nesting describe; update `.dropped_deep_subfields` describe at `:3055-3100`)
- Modify: `spec/axn/core/schema_reflection_spec.rb:32-63` (warning specs)

**Interfaces:**
- Consumes: `SubfieldTree.build(field_configs, subfield_configs)` → `Result(roots:, dropped:)`; `Node#configs/#children/#config/#implicit?` (Task 1).
- Produces: `Schema.build_input(field_configs, subfield_configs = [])` (public signature unchanged); `Schema.dropped_deep_subfields(field_configs, subfield_configs)` (signature unchanged, meaning narrowed); internal helpers `node_optional?(node)`, `subtree_requires_presence?(node)`, `children_require_presence?(children)`, `defaulted_child?(children)`, `apply_children!(prop, children)`, `apply_implicit_node!(prop, key, node)`, `object_compatible_property?(prop)`; changed signatures `required_child?(config, children)`, `field_optional?(config, children)`, `apply_nested_subfields!(prop, config, children)`, `apply_model_id_requiredness!(config, children, field_configs, properties, required)` where `children` is a `Hash{Symbol => Node}`. `shallow_subfields` is deleted.

- [ ] **Step 1: Write the failing specs for the three deep forms**

Add to `spec/axn/reflection/schema_spec.rb`, immediately before the `.dropped_deep_subfields` describe:

```ruby
  # Deep subfields (PRO-2872): a dotted `on:` path, a subfield-of-a-subfield, and a dotted field
  # name nest as recursive object properties, keyed by wire key at every level. Intermediates
  # introduced by a dotted segment are IMPLICIT (no declaration of their own): bare object
  # properties whose requiredness/nullability derive purely from their descendants.
  describe "deep subfield nesting (PRO-2872)" do
    it "nests a subfield-of-a-subfield recursively" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash
        expects :id, on: :meta, type: Integer
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      payload = schema[:properties][:payload]
      expect(payload[:type]).to eq("object")
      meta = payload[:properties][:meta]
      expect(meta[:type]).to eq("object")
      expect(meta[:properties][:id]).to include(type: "integer")
      expect(meta[:required]).to eq(["id"])
      expect(payload[:required]).to eq(["meta"])
      expect(schema[:required]).to include("payload")
    end

    it "nests a dotted on: path through an implicit intermediate object" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :zip, on: "payload.address", type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      address = schema[:properties][:payload][:properties][:address]
      expect(address[:type]).to eq("object")
      expect(address[:properties][:zip]).to include(type: "string")
      expect(address[:required]).to eq(["zip"])
    end

    it "nests a dotted field name through an implicit intermediate object" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects "bar.baz", on: :foo, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      bar = schema[:properties][:foo][:properties][:bar]
      expect(bar[:type]).to eq("object")
      expect(bar[:properties][:baz]).to include(type: "string")
      expect(bar[:required]).to eq(["baz"])
    end

    it "keys every level by wire key when on: chains through as: aliases" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, as: :data
        expects :meta, on: :data, type: Hash, as: :info
        expects :id, on: :info, type: Integer
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties]).to have_key(:payload)
      expect(schema[:properties][:payload][:properties][:meta][:properties][:id]).to include(type: "integer")
    end

    it "makes an all-optional deep chain omittable and nullable at every level" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :zip, on: "payload.address", type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      payload = schema[:properties][:payload]
      expect(payload[:type]).to eq(%w[object null])
      expect(payload[:properties][:address][:type]).to eq(%w[object null])
      expect(payload).not_to have_key(:required)
      expect(schema[:required]).to be_nil
    end

    it "keeps a deep subfield under a non-object explicit intermediate out of the schema (parent keeps its declared type)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :items, on: :payload, type: Array
        expects :first_sku, on: :items, type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      items = schema[:properties][:payload][:properties][:items]
      expect(items[:type]).to eq("array")
      expect(items).not_to have_key(:properties)
    end
  end
```

- [ ] **Step 2: Run to verify failures**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "deep subfield nesting"`
Expected: the first four and the sixth FAIL (no nested `properties` beyond one level today — `meta`/`address`/`bar` have no `:properties` key). The all-optional example may partially pass at the top level; the nested assertions FAIL.

- [ ] **Step 3: Rewrite `schema.rb` internals**

All changes to `lib/axn/reflection/schema.rb`.

**(a) Replace `build_input` and its KNOWN LIMITATION comment (`:49-90`)** with:

```ruby
      # Subfields nest recursively: a dotted `on:` path, a subfield of a subfield, and a dotted field
      # name all become nested object properties keyed by wire key (SubfieldTree resolves reader
      # aliases and dotted segments once, up front). STRUCTURAL EXCLUSIONS remain: a deep subfield
      # whose chain passes through a `model:` parent (the client sends `<field>_id`, not the object)
      # or a non-object parent (`type: Array`, a mixed union) has no JSON-object representation and is
      # omitted — surfaced via dropped_deep_subfields / the input_schema warning. A depth-1 subfield
      # under such a parent is silently omitted (the parent keeps its declared type), as ever.
      def build_input(field_configs, subfield_configs = [])
        tree = SubfieldTree.build(field_configs, Array(subfield_configs))
        properties = {}
        required = []

        field_configs.each do |config|
          next if EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)

          children = tree.roots[config.reader_as].children
          if config.validations[:model]
            # Emit the generated `<field>_id` property (don't clobber an explicitly-declared one).
            # Its requiredness/nullability is decided in the post-pass below so it can account for an
            # explicit `<field>_id` sibling regardless of declaration order.
            id_field, id_prop = model_id_property(config)
            properties[id_field] ||= id_prop
          else
            prop = build_property(config)
            apply_nested_subfields!(prop, config, children)

            properties[config.field] = prop.compact
            required << config.field.to_s unless field_optional?(config, children)
          end
        end

        # Second pass (after all properties exist, so it's independent of declaration order): decide each
        # generated model `<field>_id`'s requiredness/nullability from the model field + its explicit sibling.
        field_configs.select { |config| config.validations[:model] }.each do |config|
          children = tree.roots[config.reader_as].children
          apply_model_id_requiredness!(config, children, field_configs, properties, required)
        end

        schema = { type: "object", properties: }
        schema[:required] = required.uniq unless required.empty?
        schema
      end
```

**(b) Delete `shallow_subfields` (`:92-96`)** — nothing uses it after this task.

**(c) Replace `dropped_deep_subfields` (`:98-116`)** with:

```ruby
      # The subfield configs build_input omits from the input schema: deep configs (a dotted `on:`
      # path, a subfield of a subfield, or a dotted field name) whose chain passes through a `model:`
      # or non-object parent, so they have no JSON-object representation. They validate at runtime but
      # are absent from the schema; a caller can surface this otherwise-silent gap. A representable
      # deep chain (every explicit ancestor object-shaped) is NOT dropped — it nests in the schema.
      # Subfields rooted at a deliberately-excluded parent (EXCLUDED_FROM_INPUT_SCHEMA, e.g.
      # ambient_context) are skipped: their absence is intentional. Side-effect-free (SubfieldTree
      # inspects declared configs only).
      def dropped_deep_subfields(field_configs, subfield_configs)
        SubfieldTree.build(field_configs, Array(subfield_configs)).dropped
      end
```

**(d) Replace `required_child?` (`:179-195`)** — same doc-comment intent, transitive child test, `children` is a `Hash{Symbol => Node}`:

```ruby
      # Whether a nil/absent parent leaves a required nested obligation unmet — so it can't validate and
      # the parent is neither omittable nor nullable. Single source of truth for both the parent's
      # requiredness (field_optional?) and nullability (apply_nested_subfields!), so the two never disagree.
      # Two sources:
      #   * a required subfield ANYWHERE in the subtree — a nil parent yields every descendant absent
      #     (PRO-2857), so a required grandchild is stranded exactly like a required child; OR
      #   * a required shape (`do…end`) member WHEN a truthy-default subfield synthesizes the parent:
      #     that default makes apply_defaults_for_subfields! materialize `{}`, so ShapeValidator no longer
      #     short-circuits on nil and enforces the member. Only depth-1 subfields can carry a default
      #     (declaration rejects `default:` on a nested parent), so synthesis stays top-level-only.
      def required_child?(config, children)
        return true if children_require_presence?(children)

        # A subfield default synthesizes the parent only when the parent is object-shaped — runtime injects
        # `{}` for Hash/`:params`/untyped parents but refuses for a non-object type (`type: Array`), which
        # stays nil so ShapeValidator skips (mirrors Executor#_materialize_object_parent!).
        synthesizer = object_shaped?(config) && defaulted_child?(children)
        synthesizer && required_shape_member?(config)
      end

      # Whether any direct child node may NOT be omitted from the parent object.
      def children_require_presence?(children)
        children.values.any? { |node| !node_optional?(node) }
      end

      # Whether omitting/nil-ing this node's value strands a required descendant — the transitive
      # extension of the one-level required-child test.
      def subtree_requires_presence?(node)
        children_require_presence?(node.children)
      end

      # Whether a node may be absent from its parent object. An implicit node (a dotted-path
      # intermediate with no declaration of its own) is omittable exactly when nothing beneath it
      # requires presence. An explicit node follows the single-level rule at every depth: a usable
      # default always rescues omission (only depth-1 subfields can have one; a default whose contents
      # fail a child's validators is the same accepted divergence as at the top level); otherwise it
      # must tolerate nil AND strand no required descendant. With multiple configs at one node (the
      # same wire path declared via two routes) runtime enforces all of them, so the node is omittable
      # only if every config is.
      def node_optional?(node)
        return !subtree_requires_presence?(node) if node.implicit?

        node.configs.all? do |c|
          usable_default?(c, subfield: true) || (nil_accepted?(c) && !subtree_requires_presence?(node))
        end
      end

      # Whether any direct child carries a usable (truthy, non-Proc) default — the synthesis signal.
      def defaulted_child?(children)
        children.values.any? { |node| node.configs.any? { |c| usable_default?(c, subfield: true) } }
      end
```

**(e) Replace `field_optional?` (`:202-225`)** — body logic unchanged except the two subfield tests read the children hash:

```ruby
      # A field is absent from `required` when a declared signal makes it omittable.
      def field_optional?(config, children)
        has_required_child = required_child?(config, children)

        # A usable default on the PARENT materializes it (with its declared contents) before validation,
        # so it may always be omitted — its own default, not its subfields, decides. (A default whose
        # contents fail a child's validators is a separate, narrow divergence handled by usable_default?.)
        return true if usable_default?(config, subfield: false)

        # The parent's own nil-tolerance (optional:/allow_nil:) only makes it omittable when no required
        # child would be stranded — so it must be checked AFTER the required-child test, not ahead of it.
        return true if nil_accepted?(config) && !has_required_child

        # No parent-level omission signal: the parent is omittable only if runtime can synthesize a
        # COMPLETE parent from subfield defaults — at least one depth-1 subfield supplies a value and none
        # of the subtree is required (a required descendant has no default and can't be synthesized). This
        # synthesis only rescues an OBJECT-shaped parent: `apply_defaults_for_subfields!` injects `{}`,
        # which satisfies a Hash/`:params`/untyped parent but not a non-object one (`type: Array`, a typed
        # class) whose top-level type validator rejects the `{}`.
        return false unless object_shaped?(config)

        defaulted_child?(children) && !has_required_child
      end
```

**(f) Replace `apply_nested_subfields!` (`:287-331`)** with the recursive version plus its helpers:

```ruby
      # Mutates `prop` to nest the node's children as `prop[:properties]`/`prop[:required]`, recursing
      # through the whole subtree. Forces the parent to `type: object` (it now has structure). The parent
      # is nullable only when it tolerates nil AND strands no required descendant: runtime treats a nil
      # parent as "subfields absent" (PRO-2857), so a nil-accepting parent with an all-optional subtree
      # accepts `null`, while a required descendant (which a nil parent can't yield) keeps it object-only.
      # Only applies when EVERY admissible parent type is object-shaped (Hash/`:params`/untyped) — a
      # non-object parent (`type: Array`) or a mixed union (`type: [Hash, Array]`) keeps its declared
      # type(s) and its subfields' shape is omitted, since object properties can't represent a non-object
      # branch (deep descendants there are in dropped_deep_subfields; its children still shape
      # requiredness via required_child?, matching runtime).
      def apply_nested_subfields!(prop, config, children)
        return if children.empty?
        return unless nestable_as_object?(config)

        prop.delete(:format)
        prop[:properties] ||= {}
        prop[:required] ||= []

        apply_children!(prop, children)

        prop[:required] = prop[:required].uniq
        # A nil parent yields its subfields as absent, so `null` is admissible exactly when the parent
        # accepts nil and no required nested obligation is stranded (required_child? — which counts a
        # required shape member only when a defaulted subfield synthesizes the parent). Decided from
        # `config`/`children`, NOT `prop[:required]`, which also carries shape members that a bare
        # nil parent never triggers.
        prop[:type] = nil_allowed?(config) && !required_child?(config, children) ? %w[object null] : "object"
        prop[:required] = nil if prop[:required].empty?
      end

      # Emits one level of children into `prop` (which must already have :properties/:required arrays),
      # recursing into each child's own subtree.
      def apply_children!(prop, children)
        required_model_ids = []
        children.each do |key, node|
          if node.implicit?
            apply_implicit_node!(prop, key, node)
          elsif node.config.validations[:model]
            # The id key derives from the LEAF wire segment (a dotted model name digs `<leaf>_id` off
            # the same nested parent at runtime).
            id_field = Internal::FieldConfig.model_id_key(key)
            _, subprop = model_id_property(node.config)
            # A user may declare an explicit nested `<field>_id` subfield before the `model:` subfield;
            # don't clobber it with the generic model-generated one.
            prop[:properties][id_field] ||= subprop
            unless node_optional?(node)
              prop[:required] << id_field.to_s
              required_model_ids << id_field
            end
          else
            child_prop = build_property(node.config, subfield: true)
            apply_nested_subfields!(child_prop, node.config, node.children)
            # With two routes declared to one node, runtime enforces every config — so `null` survives
            # only if ALL tolerate nil (the property itself is built from the first-declared config).
            reject_null!(child_prop) unless node.configs.all? { |c| nil_allowed?(c) }
            prop[:properties][key] = child_prop.compact
            prop[:required] << key.to_s unless node_optional?(node)
          end
        end
        # A required nested model id can't be null (a null token resolves the model to nil at runtime).
        # Done after the loop so it survives an explicit id subfield declared after the model: subfield.
        required_model_ids.each { |id_field| reject_null!(prop[:properties][id_field]) if prop[:properties][id_field] }
      end

      # An implicit node (a dotted-path intermediate with no declaration of its own) emits a bare object
      # property whose only content is its children. If a shape member already claimed the key, merge
      # into it when it's object-compatible (untyped, or `object` among its types); otherwise leave the
      # member property untouched — the deep configs below it have no JSON-object representation there
      # (they're in dropped_deep_subfields, same predicate as SubfieldTree's drop pass).
      def apply_implicit_node!(prop, key, node)
        existing = prop[:properties][key]
        return if existing && !object_compatible_property?(existing)

        target = existing || {}
        target.delete(:format)
        target[:properties] ||= {}
        target[:required] ||= []
        apply_children!(target, node.children)
        target[:required] = target[:required].uniq
        # A fresh implicit intermediate is nullable exactly when nothing beneath requires presence (nil
        # digs to nil, PRO-2857); a shape-member merge target additionally keeps only the nil-tolerance
        # it already declared.
        nullable = !subtree_requires_presence?(node) && (existing.nil? || Array(existing[:type]).include?("null"))
        target[:type] = nullable ? %w[object null] : "object"
        target[:required] = nil if target[:required].empty?
        prop[:properties][key] = target.compact
        prop[:required] << key.to_s if subtree_requires_presence?(node)
      end

      # Whether an already-emitted property (a shape member) can absorb nested object structure.
      def object_compatible_property?(prop)
        !prop.key?(:type) || Array(prop[:type]).include?("object")
      end
```

**(g) Update `apply_model_id_requiredness!` (`:543-568`)** — signature takes `children` (the model root's children hash); the emptiness test now counts ALL children (deep/implicit included: a deep subfield under a model parent still resolves off the record at runtime, so an omitted record strands it — id required, matching runtime):

```ruby
      def apply_model_id_requiredness!(config, children, field_configs, properties, required)
        id_field, = model_id_property(config)
        explicit_id = field_configs.find { |c| c.field == id_field }
        model_omittable = children.empty? && optional_for_schema?(config)
        return if model_omittable || (explicit_id && usable_default?(explicit_id, subfield: false))

        key = id_field.to_s
        required << key unless required.include?(key)
        reject_null!(properties[id_field]) if properties[id_field]
      end
```

Keep its existing doc comment, but update the phrase "and it has NO shallow subfields" to "and it has NO subfields (at any depth — a deep subfield still resolves off the record at runtime, so an omitted record strands it)". The KNOWN LIMITATION paragraph about self-referential nested id/model contracts stays verbatim.

**(h) Update the module header (`:11-22`)**: delete the second divergence bullet ("a required deep subfield … doesn't force the parent required…") and reword the closing sentence, leaving:

```ruby
    # REQUIREDNESS IS DERIVED FROM DECLARED SIGNALS, NOT BY VALIDATING.
    # A field is omittable (absent from `required`) when a declared signal says so — a usable default,
    # or a nil/blank-tolerant validator set (`optional:`/`allow_nil:`/`allow_blank:`/`presence: false`).
    # We deliberately do NOT run the field's validators against its default to confirm the omitted call
    # would actually pass; that duplicate-validation pass was expensive and fragile. The tradeoff is a
    # documented divergence, narrow: a non-blank but otherwise-invalid default (`type: String,
    # default: 123`; `type: :uuid, default: "nope"`) is reflected as optional though the omitted call
    # fails at runtime. The safe direction (schema stricter than runtime) never causes failed calls; the
    # unsafe case above only arises from a self-contradictory contract and surfaces as a normal,
    # recoverable validation error. A required subfield at ANY depth forces its whole ancestor chain
    # required and non-nullable (a nil/omitted ancestor yields every descendant absent, PRO-2857).
```

**(i) Update the warning in `lib/axn/core/schema_reflection.rb`** — replace the `_warn_dropped_deep_subfields` comment and message:

```ruby
        # A deep subfield whose chain passes through a `model:` or non-object parent has no JSON-object
        # representation: it validates at runtime but is absent from the input schema. Surface that once
        # per class so an adapter author building tooling on the schema isn't misled by a silent gap.
        def _warn_dropped_deep_subfields
          return if @_axn_deep_subfield_warning_emitted

          dropped = Axn::Reflection::Schema.dropped_deep_subfields(internal_field_configs, subfield_configs)
          return if dropped.empty?

          @_axn_deep_subfield_warning_emitted = true
          paths = dropped.map { |c| "#{c.field} (on: #{c.on})" }.join(", ")
          Axn.config.logger.warn(
            "[Axn] #{resolved_axn_name} input_schema omits deep subfield(s) nested under a model: or " \
            "non-object parent (no JSON-object representation): #{paths}. They validate at runtime but " \
            "are absent from the reflected input schema; restructure the parent as a Hash/:params field, " \
            "or handle them in the adapter.",
          )
        end
```

- [ ] **Step 4: Update the existing dropped/warning specs to the narrowed meaning**

In `spec/axn/reflection/schema_spec.rb`, replace the `.dropped_deep_subfields` describe block (`:3055-3100`) with:

```ruby
  # A deep subfield whose chain passes through a `model:` or non-object parent has no JSON-object
  # representation (PRO-2872 represents every OTHER deep chain). This query names exactly those
  # omitted configs so the caller can warn — it must NOT flag a represented (object-shaped) chain,
  # a shallow subfield, nor a subfield under the deliberately-excluded ambient_context parent.
  describe ".dropped_deep_subfields" do
    it "returns [] for the three deep forms under object-shaped parents (they are represented now)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash          # shallow — represented
        expects :id, on: :meta, type: Integer            # deep: subfield-of-subfield
        expects :deep, on: "payload.meta", type: String  # deep: dotted on:
        expects "bar.baz", on: :payload                  # deep: dotted field name
      end

      expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
    end

    it "flags a deep subfield under a model: parent" do
      klass = Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id, :profile), finder: :find }
        expects :name, on: "user.profile", type: String
      end

      dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
      expect(dropped.map(&:field)).to eq([:name])
    end

    it "flags a deep subfield under a non-object intermediate, regardless of declaration order" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :sku, on: "payload.items", type: String
        expects :items, on: :payload, type: Array
      end

      dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
      expect(dropped.map(&:field)).to eq([:sku])
    end

    it "returns [] when every subfield is a shallow child of a top-level field" do
      klass = Class.new do
        include Axn
        expects :address, type: Hash
        expects :city, on: :address, type: String
        expects :zip, on: :address, type: String
      end

      expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
    end

    it "returns [] when there are no subfields at all" do
      klass = Class.new do
        include Axn
        expects :name, type: String
      end

      expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
    end

    it "does not flag a shallow ambient_context subfield (its parent is intentionally excluded)" do
      klass = Class.new do
        include Axn
        expects :company, on: :ambient_context, type: Integer
        expects :limit, type: Integer, default: 20
      end

      expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
    end
  end
```

In `spec/axn/core/schema_reflection_spec.rb`, replace the warning describe (`:32-63`) with:

```ruby
  describe "unrepresentable-subfield omission warning" do
    let(:deep_klass) do
      Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id, :profile), finder: :find }
        expects :name, on: "user.profile", type: String # deep under a model: parent — no object representation
      end
    end

    it "warns, naming the omitted field" do
      expect(Axn.config.logger).to receive(:warn).with(/input_schema omits deep subfield.*\bname\b.*model: or non-object parent/m)
      deep_klass.input_schema
    end

    it "warns at most once per class across repeated input_schema calls" do
      expect(Axn.config.logger).to receive(:warn).once
      3.times { deep_klass.input_schema }
    end

    it "does not warn for a representable deep chain (object-shaped parents)" do
      representable = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash
        expects :id, on: :meta, type: Integer
      end
      expect(Axn.config.logger).not_to receive(:warn)
      representable.input_schema
    end

    it "does not warn when every subfield is shallow" do
      shallow_klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: String
      end
      expect(Axn.config.logger).not_to receive(:warn)
      shallow_klass.input_schema
    end
  end
```

Adjust the warning-regex wording if the final message text differs — the assertion must match the actual message.

- [ ] **Step 5: Run the new specs, then the FULL suite**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb spec/axn/core/schema_reflection_spec.rb spec/axn/reflection/subfield_tree_spec.rb`
Expected: PASS.

Run: `bundle exec rspec`
Expected: PASS. Pay attention to any existing spec that asserted the single-level limitation or called the removed `shallow_subfields` — update assertions to the new behavior only where the *limitation itself* was the subject; investigate anything else as a possible regression.

- [ ] **Step 6: Lint and commit**

Run: `bundle exec rubocop lib spec`
Expected: no offenses (extract small helpers if method-length cops fire; do not add blanket disables).

```bash
git add lib/axn/reflection/schema.rb lib/axn/core/schema_reflection.rb spec/axn/reflection/schema_spec.rb spec/axn/core/schema_reflection_spec.rb
git commit -m "PRO-2872: Represent deep subfield nesting in schema reflection

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Requiredness/nullability propagation edge cases

**Files:**
- Modify: `spec/axn/reflection/schema_spec.rb` (inside the "deep subfield nesting (PRO-2872)" describe)

**Interfaces:**
- Consumes: `Schema.build_input` (Task 2). Produces: behavior locked by tests; any fix stays within the Task 2 helpers.

- [ ] **Step 1: Write the specs (some may already pass — that's fine; they lock the invariants)**

```ruby
    describe "transitive requiredness/nullability (a required descendant strands every nil/omitted ancestor)" do
      it "forces an optional: intermediate AND its nil-tolerant top-level parent required when a deep leaf is required (fixes the old shallow-only divergence)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash, allow_nil: true
          expects :meta, on: :payload, type: Hash, optional: true
          expects :id, on: :meta, type: Integer
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        expect(schema[:required]).to include("payload")
        payload = schema[:properties][:payload]
        expect(payload[:type]).to eq("object")                       # null stripped: nil payload strands id
        expect(payload[:required]).to eq(["meta"])                   # optional: meta is overridden by its required child
        expect(payload[:properties][:meta][:type]).to eq("object")   # meta likewise non-nullable
      end

      it "keeps implicit intermediates required and non-nullable above a required deep leaf" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :id, on: "payload.a.b", type: Integer
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        a = schema[:properties][:payload][:properties][:a]
        expect(a[:type]).to eq("object")
        expect(a[:required]).to eq(["b"])
        expect(a[:properties][:b][:type]).to eq("object")
        expect(a[:properties][:b][:required]).to eq(["id"])
      end

      it "lets a usable default on the depth-1 parent rescue omission despite a required deep child (default contents are trusted, the standing divergence)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash, allow_nil: true
          expects :meta, on: :payload, type: Hash, default: { id: 1 }
          expects :id, on: :meta, type: Integer
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        payload = schema[:properties][:payload]
        # meta's default materializes it, so meta is omittable — and payload strands nothing.
        expect(Array(payload[:required])).not_to include("meta")
        expect(schema[:required]).to be_nil
        expect(payload[:properties][:meta][:required]).to eq(["id"])
      end

      it "counts a required deep leaf below a NON-OBJECT intermediate toward ancestor requiredness even though its shape is omitted (runtime still validates it)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash, allow_nil: true
          expects :items, on: :payload, type: Array, optional: true
          expects :first_sku, on: :items, type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        # first_sku is dropped from the schema shape (non-object parent) but runtime requires it,
        # which requires items present, which requires payload present.
        payload = schema[:properties][:payload]
        expect(payload[:required]).to eq(["items"])
        expect(payload[:type]).to eq("object")
        expect(schema[:required]).to include("payload")
        expect(payload[:properties][:items][:type]).to eq("array")
        expect(payload[:properties][:items]).not_to have_key(:properties)
      end
    end
```

- [ ] **Step 2: Run, fix any failures within the Task 2 helpers**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "transitive requiredness"`
Expected: PASS if Task 2 is correct. If a case fails, fix inside `node_optional?`/`subtree_requires_presence?`/`apply_implicit_node!` — do not special-case emission.

- [ ] **Step 3: Full file + commit**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb && bundle exec rubocop spec/axn/reflection/schema_spec.rb`
Expected: PASS / no offenses.

```bash
git add spec/axn/reflection/schema_spec.rb
git commit -m "PRO-2872: Lock transitive deep requiredness/nullability invariants

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `model:` at depth

**Files:**
- Modify: `spec/axn/reflection/schema_spec.rb` (inside the "deep subfield nesting (PRO-2872)" describe; also extend the existing "model: fields" describe at `:918`)

**Interfaces:**
- Consumes: `Schema.build_input`, `apply_children!` model branch (Task 2).

- [ ] **Step 1: Write the specs**

```ruby
    describe "model: subfields at depth" do
      it "emits <field>_id inside a deep nested object (not the model field itself)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash
          expects :company, on: :meta, model: { klass: Struct.new(:id), finder: :find }
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        meta = schema[:properties][:payload][:properties][:meta]
        expect(meta[:properties]).to have_key(:company_id)
        expect(meta[:properties]).not_to have_key(:company)
        expect(meta[:required]).to include("company_id")
        expect(meta[:properties][:company_id]).to include(not: { type: "null" }) # required id can't be null
      end

      it "places a dotted-name model subfield's id at the leaf segment under the implicit intermediate" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects "org.company", on: :payload, model: { klass: Struct.new(:id), finder: :find }
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        org = schema[:properties][:payload][:properties][:org]
        expect(org[:properties]).to have_key(:company_id)
        expect(org[:properties]).not_to have_key(:"org.company_id")
      end

      it "keeps an explicitly-declared deep sibling id instead of clobbering it with the generated one" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash
          expects :company_id, on: :meta, type: :uuid
          expects :company, on: :meta, model: { klass: Struct.new(:id), finder: :find }
        end
        meta = described_class.build_input(klass.internal_field_configs,
                                           klass.subfield_configs)[:properties][:payload][:properties][:meta]

        expect(meta[:properties][:company_id]).to include(type: "string", format: "uuid")
        expect(Array(meta[:required]).count("company_id")).to eq(1)
      end

      it "requires the top-level model <field>_id when the model has only DEEP subfields (an omitted record strands them at runtime)" do
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id, :settings), finder: :find }, allow_nil: true
          expects :theme, on: "company.settings", type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        expect(schema[:required]).to include("company_id")
      end
    end
```

- [ ] **Step 2: Run, fix within the Task 2 model branch if needed**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "model: subfields at depth"`
Expected: PASS. Likely failure spot: the dotted-name model id (`model_id_key(key)` from the leaf segment vs `config.field`) — the fix belongs in `apply_children!`, not in `model_id_property` (whose top-level behavior must not change).

- [ ] **Step 3: Full file + commit**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb && bundle exec rubocop`
Expected: PASS / no offenses.

```bash
git add spec/axn/reflection/schema_spec.rb lib/axn/reflection/schema.rb
git commit -m "PRO-2872: model: subfields at depth emit nested <field>_id

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Shape-member merge and same-node double declaration

**Files:**
- Modify: `spec/axn/reflection/schema_spec.rb` (inside the "deep subfield nesting (PRO-2872)" describe)

**Interfaces:**
- Consumes: `apply_implicit_node!`/`object_compatible_property?` (Task 2), `SubfieldTree.blocking_ancestor?` shape-collision rule (Task 1).

- [ ] **Step 1: Write the specs**

```ruby
    describe "composition with shape: members" do
      it "merges an implicit deep intermediate into an object-compatible shape member at the same key" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash
          end
          expects "bar.baz", on: :payload, type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(Array(bar[:type])).to include("object")
        expect(bar[:properties][:baz]).to include(type: "string")
        expect(bar[:required]).to include("baz")
      end

      it "leaves a NON-object shape member untouched and drops the colliding deep config (warned via dropped_deep_subfields)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects "bar.baz", on: :payload, type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar).to include(type: "string")
        expect(bar).not_to have_key(:properties)
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:"bar.baz"])
      end
    end

    describe "the same wire path declared via two routes" do
      it "builds the property from the first-declared config, unions requiredness, and intersects nullability" do
        klass = Class.new do
          include Axn
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects "bar.baz", on: :foo, type: String, allow_nil: true # route 1: optional/nullable
          expects :baz, on: :bar, type: String                      # route 2: required, non-nullable
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:foo][:properties][:bar]
        expect(bar[:required]).to eq(["baz"])                # union: route 2 requires it
        expect(bar[:properties][:baz][:type]).to eq("string") # intersection: null stripped (route 2 rejects nil)
      end
    end
```

If the second declaration in the two-routes spec raises `DuplicateFieldError` at declaration time, the double-declaration case is impossible by construction — replace the spec with one asserting the declaration-time error, and simplify `Node#configs` handling in a follow-up comment (do NOT restructure the tree in this task; multiple-config support is cheap insurance).

- [ ] **Step 2: Run, fix within Task 1/2 helpers if needed**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "composition with shape" -e "two routes"`
Expected: PASS.

- [ ] **Step 3: Full suite + commit**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS / no offenses.

```bash
git add spec/axn/reflection/schema_spec.rb lib
git commit -m "PRO-2872: Lock shape-member merge and double-declaration semantics at depth

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Runtime-truth matrix

**Files:**
- Modify: `spec/axn/reflection/schema_spec.rb` (new describe after the deep-nesting one)

**Interfaces:**
- Consumes: `Schema.build_input` + `Axn.call` runtime (`klass.call(...)` returns a Result with `#ok?`).

- [ ] **Step 1: Write the specs — schema claims checked against actual calls**

```ruby
  # The schema's deep requiredness claims must AGREE with runtime outcomes (or diverge only in the
  # stricter direction). Each example asserts both sides against the same class.
  describe "runtime agreement for deep subfields" do
    it "required deep leaf: schema requires the chain, runtime rejects omission and accepts the full path" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :meta, on: :payload, type: Hash, optional: true
        expects :id, on: :meta, type: Integer
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
      expect(klass.call).not_to be_ok                                   # omitted payload strands id
      expect(klass.call(payload: { meta: nil })).not_to be_ok           # nil meta strands id
      expect(klass.call(payload: { meta: { id: 7 } })).to be_ok
    end

    it "all-optional deep chain: schema omits requiredness, runtime accepts omission, nil parent, and full path" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :zip, on: "payload.address", type: String, optional: true
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to be_nil
      expect(klass.call).to be_ok
      expect(klass.call(payload: nil)).to be_ok
      expect(klass.call(payload: { address: nil })).to be_ok
      expect(klass.call(payload: { address: { zip: "10001" } })).to be_ok
    end

    it "dotted field name: runtime digs the same path the schema advertises" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects "bar.baz", on: :foo, type: String
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:foo][:properties][:bar][:required]).to eq(["baz"])
      expect(klass.call(foo: {})).not_to be_ok
      expect(klass.call(foo: { bar: {} })).not_to be_ok
      expect(klass.call(foo: { bar: { baz: "ok" } })).to be_ok
    end

    it "defaulted depth-1 parent with a required deep child: schema optional, runtime accepts omission (default materializes)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :meta, on: :payload, type: Hash, default: { id: 1 }
        expects :id, on: :meta, type: Integer
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to be_nil
      expect(klass.call).to be_ok
    end
  end
```

- [ ] **Step 2: Run; investigate ANY disagreement as a bug (schema looser than runtime = must fix; stricter = must be a documented divergence)**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "runtime agreement for deep subfields"`
Expected: PASS. A runtime-side failure here means a wrong assumption about executor semantics — re-read `lib/axn/executor.rb` `apply_defaults_for_subfields!`/`validate_subfields_contract!` before touching reflection code.

- [ ] **Step 3: Commit**

```bash
git add spec/axn/reflection/schema_spec.rb
git commit -m "PRO-2872: Runtime-truth matrix for deep subfield requiredness

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Docs and CHANGELOG

**Files:**
- Modify: `docs/reference/class.md` (`:636` overview parenthetical, the divergence warning block near `:654`, the single-level paragraph at `:660`)
- Modify: `CHANGELOG.md` (Unreleased PRO-2842 entry, amend in place)

Reminder: one line per paragraph in Markdown — no hard wrapping.

- [ ] **Step 1: Update `docs/reference/class.md`**

1. In the overview paragraph (`:636`), change the parenthetical to: `(One deliberate exception: `input_schema` logs a single diagnostic warning per class when it omits a deep subfield that has no JSON-object representation — see below — writing only to the configured logger.)`
2. In the "Requiredness is advisory" warning block, DELETE the middle bullet (the "required _deep_ subfield … Only single-level subfields are represented" one). Keep the invalid-default and nested-model-with-defaulted-id bullets.
3. Replace the paragraph at `:660` ("Only single-level subfields are represented; …") with:

```markdown
Subfields nest to any depth: a dotted `on:` path (`on: "address.billing"`), a subfield of a subfield, and a dotted field name (`expects "bar.baz", on: :foo`) all appear as recursively nested object `properties`, keyed by wire key (aliases resolve to the key a client actually sends). A required subfield at any depth forces its whole ancestor chain into `required` (and strips those ancestors' nullability): a `nil`/omitted ancestor yields every descendant absent, so runtime could never satisfy the leaf. Intermediate keys introduced by a dotted segment reflect as plain object properties that are required (and non-nullable) exactly when something beneath them is. The one structural exclusion: a deep subfield whose chain passes through a `model:` parent (the client sends `<field>_id`, not the object) or a non-object parent (`type: Array`, a mixed union) has no JSON-object representation and is omitted from the schema — calling `input_schema` on such a class logs a one-time warning naming the omitted field(s), so the gap is visible rather than silent when you build tooling on the schema.
```

- [ ] **Step 2: Amend the CHANGELOG Unreleased entry**

In the PRO-2842 `[FEAT]` bullet in `CHANGELOG.md`:
1. Replace the divergence phrase `and a required deep/nested subfield under a nil-tolerant parent doesn't force that parent `required`` with nothing (leaving the invalid-default divergence as the only one; fix surrounding "two documented, narrow divergences" → "a documented, narrow divergence" and adjust grammar).
2. Replace the sentence starting `**Known limitation:** only single-level subfield nesting is represented —` through `(PRO-2871; full deep-nesting support tracked in PRO-2872).` with:

```markdown
Subfields nest to ANY depth (PRO-2872): a dotted `on:` path, a subfield-of-a-subfield, and a dotted field name all reflect as recursively nested object properties keyed by wire key, with a required subfield at any depth forcing its whole ancestor chain `required`/non-nullable (a nil ancestor yields every descendant absent) and dotted-segment intermediates reflecting as plain object properties required exactly when something beneath them is. The one structural exclusion: a deep subfield reached through a `model:` or non-object (`type: Array`, mixed-union) parent has no JSON-object representation and is omitted — `input_schema` logs a one-time warning per class naming such fields (via `Axn.config.logger`), so the gap is surfaced rather than silent for an adapter author building on the schema (PRO-2871).
```

3. Check the PRO-2857 entry's reflection sentence still reads true (it does — "a parent with a required child … stays object-only" now applies transitively; extend it with "(at any depth, PRO-2872)" if the sentence would otherwise mislead).

- [ ] **Step 3: Verify docs build if applicable, run full suite, commit**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS / no offenses.

```bash
git add docs/reference/class.md CHANGELOG.md
git commit -m "PRO-2872: Document deep subfield nesting in reflection docs + CHANGELOG

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Final verification

- [ ] **Step 1: Full suite + lint**

Run: `bundle exec rspec`
Expected: PASS, zero failures.

Run: `bundle exec rubocop`
Expected: no offenses.

- [ ] **Step 2: Grep for stale references**

Run: `grep -rn "single-level\|shallow_subfields\|KNOWN LIMITATION" lib docs CHANGELOG.md`
Expected: no hits describing the old limitation (the `apply_model_id_requiredness!` self-referential KNOWN LIMITATION comment legitimately remains; anything else describing "only single-level subfields" must be gone).

- [ ] **Step 3: Verify the divergence fix end-to-end (the headline behavior) with a one-off script**

Run:

```bash
bundle exec ruby -e '
require "axn"
klass = Class.new do
  include Axn
  expects :payload, type: Hash, allow_nil: true
  expects :meta, on: :payload, type: Hash, optional: true
  expects :id, on: :meta, type: Integer
  def call = nil
end
schema = klass.input_schema
raise "payload not required" unless schema[:required].include?("payload")
raise "no nested id" unless schema.dig(:properties, :payload, :properties, :meta, :properties, :id)
raise "runtime accepts omission?!" if klass.call.ok?
puts "deep reflection + runtime agree"
'
```

Expected output: `deep reflection + runtime agree` (and no deep-subfield warning logged, since the chain is representable).

- [ ] **Step 4: Commit anything outstanding; done**

Working tree should be clean. If not, review why before committing.
