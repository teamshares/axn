# Ambient Subfield Symmetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore full symmetry for `on: :ambient_context` subfields — allow `default:`/`preprocess:`/`coerce:` (guard removal; the read path already applies them) and `shape:` (leaf-copy validation, non-leaf rejected at declaration, sensitive-masking gap closed), while keeping `user_facing:` rejected.

**Architecture:** Three of the four ambient carve-outs were justified by a write-back resolution model that PRO-2903 already replaced with a non-mutating read path (`ContractForSubfields.resolve_value`). Steps 1–2 remove the now-stale declaration guards; the only new logic is (a) a declaration check rejecting a `shape:` node that isn't a leaf, and (b) wiring PR #176's `_mask_unfilterable_shapes` into the one ambient logging path so a non-Hash sensitive shape value is masked.

**Tech Stack:** Ruby, RSpec, ActiveModel. Non-Rails test suite under `spec/` (run with plain `bundle exec rspec`).

## Global Constraints

- **Spec:** `internal-docs/specs/2026-07-15-ambient-subfield-symmetry-design.md` — read it before starting.
- **`user_facing:` stays rejected on ambient** at every depth (`contract_for_subfields.rb:224`). Never remove that guard.
- **All ambient gating stays `_on_roots_at_ambient?`-based** (fires at any depth: direct, dotted `on:`, nested-under-ambient). Never narrow it to an exact-root check.
- **No historical comments in code** — comments describe current behavior and intrinsic why, never "used to X / now Y" or ticket references as narration.
- **No manual line breaks in Markdown prose** (docs/CHANGELOG) — one line per paragraph.
- **Mirror layers reuse the source** — the sensitive-masking work reuses PR #176's helpers (`_mask_value_at_path`, `_mask_shape_value`, `_mask_opaque_or_preserve`, `_shape_has_sensitive_member?`); do not re-derive masking logic.
- Run the whole ambient + coercion suites after each task: `bundle exec rspec spec/axn/core/ambient_context_spec.rb spec/axn/core/coercion_spec.rb`.

---

## File Structure

- `lib/axn/core/contract_for_subfields.rb` — remove the `default:`/`preprocess:` raise (`:245`), `_reject_ambient_coerce!` (`:330`) + call site (`:320`), `_reject_ambient_shape!` (`:347`) + call site (`:321`); update the nesting comment (`:230`); add the `_check_ambient_shape_placement!` call at the declaration site (`:269`).
- `lib/axn/core/ambient_context.rb` — add `_check_ambient_shape_placement!` + `_each_ambient_node` (candidate-tree walk); add `_sensitive_ambient_shape_paths` (used by the masking wiring).
- `lib/axn/core/contract.rb` — parametrize `_mask_unfilterable_shapes(data, shape_paths, action_instance)`; wire ambient wholesale-masking into `execution_context`'s ambient slice (`:1131`).
- `spec/axn/core/ambient_context_spec.rb` — flip rejection specs to acceptance; add read/validation/shape/sensitive coverage.
- `spec/axn/core/coercion_spec.rb` — flip the ambient `coerce:` rejection (`:83`).
- `CHANGELOG.md` — reconcile the PRO-2909 entry; add the PRO-2912 entry.
- `docs/reference/class.md` — update ambient restriction copy (`:262`, `:302`, `:374`).

---

## Task 1: Allow `default:`/`preprocess:`/`coerce:` on ambient subfields

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb` (remove default/preprocess raise `:238-251`; remove `_reject_ambient_coerce!` call `:320` and method `:326-337`; rewrite nesting comment `:230-236`)
- Test: `spec/axn/core/ambient_context_spec.rb`, `spec/axn/core/coercion_spec.rb`

**Interfaces:**
- Consumes: `ContractForSubfields.resolve_value` (already applies coerce → preprocess → value-level default on the read path); `with_ambient_context(**attrs) { ... }` and `build_axn { ... }` test helpers.
- Produces: no new public surface — only removes three declaration guards. `user_facing:` and `_reject_ambient_shape!` remain (shape handled in Task 2).

- [ ] **Step 1: Write the failing acceptance tests**

Replace the two existing `it "rejects preprocess:..."` / `it "rejects default:..."` examples (`ambient_context_spec.rb:122-137`) with acceptance tests, and add coerce + nested + validation coverage. Insert into the `RSpec.describe "Axn ambient_context subfield restrictions"` block (keep the surviving `user_facing:` and `sensitive:` examples in that block untouched):

```ruby
it "applies default: to an absent ambient subfield on read and at validation" do
  klass = build_axn do
    expects :locale, on: :ambient_context, type: String, default: "en"
    exposes :loc
    def call = expose(loc: locale)
  end
  result = with_ambient_context({}) { klass.call }
  expect(result).to be_ok
  expect(result.loc).to eq("en")
end

it "applies coerce: to an ambient subfield value on read and at validation" do
  klass = build_axn do
    expects :count, on: :ambient_context, type: Integer, coerce: true
    exposes :c
    def call = expose(c: count)
  end
  result = with_ambient_context(count: "5") { klass.call }
  expect(result).to be_ok
  expect(result.c).to eq(5)
end

it "applies preprocess: to an ambient subfield value on read" do
  klass = build_axn do
    expects :tag, on: :ambient_context, type: String, preprocess: ->(v) { v&.strip }
    exposes :t
    def call = expose(t: tag)
  end
  result = with_ambient_context(tag: "  x  ") { klass.call }
  expect(result).to be_ok
  expect(result.t).to eq("x")
end

it "applies default:/preprocess:/coerce: on a subfield nested under ambient_context" do
  klass = build_axn do
    expects :request, on: :ambient_context, type: Hash
    expects :ip, on: :request, type: String, default: "0.0.0.0"
    expects :port, on: :request, type: Integer, coerce: true
    exposes :ip_val, :port_val
    def call = expose(ip_val: ip, port_val: port)
  end
  result = with_ambient_context(request: { port: "8080" }) { klass.call }
  expect(result).to be_ok
  expect(result.ip_val).to eq("0.0.0.0")
  expect(result.port_val).to eq(8080)
end

it "applies default: on a dotted `on:` path rooted at ambient_context" do
  klass = build_axn do
    expects :session, on: "ambient_context.request", type: String, default: "anon"
    exposes :s
    def call = expose(s: session)
  end
  result = with_ambient_context(request: {}) { klass.call }
  expect(result).to be_ok
  expect(result.s).to eq("anon")
end
```

Then, in the `describe "retained guards still fire on a nested ambient subfield"` block (`ambient_context_spec.rb:497-533`), DELETE the four now-obsolete rejection examples (`default:`, `preprocess:`, `coerce:`, and the dotted-`on:` `default:`) and replace them with a single example proving the one *retained* ambient guard still fires nested:

```ruby
    it "rejects user_facing: on a subfield nested under ambient_context" do
      expect do
        build_axn do
          expects :request, on: :ambient_context, type: Hash
          expects :ip, on: :request, user_facing: "nope"
        end
      end.to raise_error(ArgumentError, /user_facing.*ambient|ambient.*user_facing/)
    end
```

In `spec/axn/core/coercion_spec.rb`, replace the `it "rejects coerce: on an ambient_context subfield..."` example (`:83-85`) with:

```ruby
it "applies coerce: on an ambient_context subfield value" do
  action = build_axn do
    expects :when, on: :ambient_context, coerce: Date
    exposes :w
    def call = expose(w: self.when)
  end
  result = with_ambient_context(when: "2026-07-15") { action.call }
  expect(result).to be_ok
  expect(result.w).to eq(Date.new(2026, 7, 15))
end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb spec/axn/core/coercion_spec.rb`
Expected: FAIL — the new acceptance examples raise `ArgumentError` ("`default:`/`preprocess:` are not supported…", "`coerce:` is not supported…") from the declaration guards.

- [ ] **Step 3: Remove the `default:`/`preprocess:` guard and rewrite the nesting comment**

In `lib/axn/core/contract_for_subfields.rb`, replace the block spanning the nesting comment through the `default:`/`preprocess:` raise (`:230-251`) with just the updated nesting comment:

```ruby
          # Deep ambient nesting — a dotted `on:` rooted at ambient (`on: "ambient_context.request"`),
          # a dotted subfield NAME on an ambient parent (`expects "request.ip", on: :ambient_context`),
          # and a subfield nested UNDER an ambient subfield (`expects :ip, on: :request`) — is fully
          # supported (PRO-2909): runtime resolution walks these, and `_filter_to_declared` rebuilds the
          # filtered ambient hash along each declared PATH, so a nested leaf resolves while undeclared
          # siblings are dropped. `default:`/`preprocess:`/`coerce:` resolve on the same non-mutating read
          # path (`resolve_value`) as every other subfield, so they apply here too — no write-back to
          # `provided_data` is involved. `user_facing:` stays rejected (above): an ambient value is
          # framework-supplied, so there is no caller to face regardless of resolution mechanism.
```

- [ ] **Step 4: Remove `_reject_ambient_coerce!` and its call site**

In `lib/axn/core/contract_for_subfields.rb`, in `_parse_subfield_configs`, delete the `_reject_ambient_coerce!(config)` line (`:320`) from the `.each do |config|` block (leave `_reject_ambient_shape!(config)` and `_reject_dotted_model_name!(config, fields:)`):

```ruby
          _parse_field_configs(*fields, on:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                        metadata:, reader_names:, user_facing:, method_call:, **validations).each do |config|
            _reject_ambient_shape!(config)
            _reject_dotted_model_name!(config, fields:)
          end
```

Then delete the entire `_reject_ambient_coerce!` method and its comment (`:326-337`).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb spec/axn/core/coercion_spec.rb`
Expected: PASS (shape rejections still pass — untouched this task).

- [ ] **Step 6: Run the full suite to catch regressions**

Run: `bundle exec rspec`
Expected: PASS (0 failures). If any spec asserted the removed `default:`/`preprocess:`/`coerce:` ambient rejections, flip it to match the new behavior.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract_for_subfields.rb spec/axn/core/ambient_context_spec.rb spec/axn/core/coercion_spec.rb
git commit -m "PRO-2912: allow default:/preprocess:/coerce: on ambient subfields

Read path (resolve_value) already applies all three; only the stale
write-back-era declaration guards blocked them. user_facing: stays
rejected.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Allow `shape:` on a leaf ambient subfield; reject the non-leaf case

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb` (remove `_reject_ambient_shape!` call `:321` and method `:339-355`; add `_check_ambient_shape_placement!` call after the contradiction check `:269`)
- Modify: `lib/axn/core/ambient_context.rb` (add `_check_ambient_shape_placement!` + `_each_ambient_node`)
- Test: `spec/axn/core/ambient_context_spec.rb`

**Interfaces:**
- Consumes: `Axn::Reflection::SubfieldTree.build([_synthetic_ambient_root], ambient)` (already used by `_ambient_subfield_tree`); `SubfieldTree::Node#configs`/`#children`; `_on_roots_at_ambient?`; `_synthetic_ambient_root`; `_filter_ambient_node`'s leaf-copy behavior (`child.children.empty?`).
- Produces: `_check_ambient_shape_placement!(candidate_subfields)` — raises `ArgumentError` if any ambient node carries a `:shape` config AND has children. Called at declaration, pre-mutation.

- [ ] **Step 1: Write the failing tests**

In `spec/axn/core/ambient_context_spec.rb`, replace the `describe "shape blocks are rejected on ambient subfields..."` block (`:371-392`, the two "rejects a shape block" examples) with acceptance + non-leaf-rejection coverage:

```ruby
describe "shape: on ambient subfields (leaf-copy validation)" do
  it "validates a shape: on a leaf ambient subfield against the copied value" do
    klass = build_axn do
      expects :request, on: :ambient_context, type: Hash do
        field :ip, type: String
      end
      exposes :ip_val
      def call = expose(ip_val: request[:ip])
    end
    ok = with_ambient_context(request: { ip: "1.2.3.4", extra: "kept-in-copy" }) { klass.call }
    expect(ok).to be_ok
    expect(ok.ip_val).to eq("1.2.3.4")
    expect(ok.request).to include(extra: "kept-in-copy") # leaf copies the whole value

    bad = with_ambient_context(request: { ip: 123 }) { klass.call }
    expect(bad).not_to be_ok
  end

  it "validates a shape: on an ambient subfield reached via an implicit intermediate" do
    klass = build_axn do
      expects "meta.request", on: :ambient_context, as: :req, type: Hash do
        field :ip, type: String
      end
      exposes :ip_val
      def call = expose(ip_val: req[:ip])
    end
    ok = with_ambient_context(meta: { request: { ip: "1.2.3.4" } }) { klass.call }
    expect(ok).to be_ok
    expect(ok.ip_val).to eq("1.2.3.4")

    bad = with_ambient_context(meta: { request: { ip: 99 } }) { klass.call }
    expect(bad).not_to be_ok
  end

  it "rejects a shape: on an ambient node that also has a subfield child (non-overlapping)" do
    expect do
      build_axn do
        expects :request, on: :ambient_context, type: Hash do
          field :token, type: String
        end
        expects :foo, on: :request
      end
    end.to raise_error(ArgumentError, /only supported when it has no nested subfields|Declare the nested structure/)
  end

  it "rejects a shape member overlapping a subfield child on the same ambient node" do
    expect do
      build_axn do
        expects :request, on: :ambient_context, type: Hash do
          field :ip, type: String
        end
        expects :ip, on: :request, type: String
      end
    end.to raise_error(ArgumentError, /only supported when it has no nested subfields|Declare the nested structure/)
  end

  it "still allows the equivalent nested structure declared as subfields" do
    klass = build_axn do
      expects :request, on: :ambient_context, type: Hash
      expects :ip, on: :request, type: String
      exposes :ip_val
      def call = expose(ip_val: ip)
    end
    result = with_ambient_context(request: { ip: "1.2.3.4" }) { klass.call }
    expect(result).to be_ok
    expect(result.ip_val).to eq("1.2.3.4")
  end
end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb -e "shape: on ambient subfields"`
Expected: FAIL — the acceptance examples raise the current blanket `_reject_ambient_shape!` error ("a `shape:` block is not supported on an `on: :ambient_context` subfield"); the non-leaf examples pass for the wrong reason (blanket rejection, wrong message).

- [ ] **Step 3: Add the leaf-placement declaration check**

In `lib/axn/core/ambient_context.rb`, inside `module ClassMethods`, add after `_check_ambient_subfield_contradictions!` (`:59`):

```ruby
        # A `shape:` on an ambient subfield validates the COPIED ambient value: a shape-carrying node
        # with no subfield children is a leaf in `_filter_ambient_node`, so its whole value is copied
        # and shape validates against it — no filter-merge. A shape node WITH subfield children is not a
        # leaf: the filter rebuilds it from those children alone, dropping every shape-only member, so
        # the shape can't be validated there. Reject that at declaration (candidate tree, nothing
        # committed — same pattern as `_check_ambient_subfield_contradictions!`), pointing at declaring
        # the nested structure ONE way. Order-independent: a child's `on:` requires its parent already
        # declared, so a shape-carrying parent is always seen with its children by the time this runs.
        def _check_ambient_shape_placement!(candidate_subfields)
          ambient = candidate_subfields.select { |c| _on_roots_at_ambient?(c.on) }
          return if ambient.empty?

          tree = Axn::Reflection::SubfieldTree.build([_synthetic_ambient_root], ambient)
          _each_ambient_node(tree.roots[PARENT]) do |node|
            next if node.children.empty?

            shape_config = node.configs.find { |c| c.validations.is_a?(Hash) && c.validations.key?(:shape) }
            next unless shape_config

            raise ArgumentError,
                  "a `shape:` block on the ambient subfield `#{shape_config.field}` is only supported when it " \
                  "has no nested subfields — this node also has subfield children, so the ambient filter " \
                  "rebuilds it from those children alone and the shape's members can't be validated. Declare " \
                  "the nested structure ONE way: keep the `shape:` (validation only), or use subfields " \
                  "(`expects :<member>, on: :#{shape_config.field}`), which also give readers and `sensitive:`."
          end
        end

        # Depth-first walk of `node` and all its declared descendants, yielding each node.
        def _each_ambient_node(node, &block)
          yield node
          node.children.each_value { |child| _each_ambient_node(child, &block) }
        end
```

- [ ] **Step 4: Call the check at the declaration site and remove the blanket shape guard**

In `lib/axn/core/contract_for_subfields.rb`, add the placement check right after the contradiction check (`:269`):

```ruby
            Axn::Reflection::SubfieldContradictions.check!(internal_field_configs, subfield_configs + configs)
            _check_ambient_subfield_contradictions!(subfield_configs + configs)
            _check_ambient_shape_placement!(subfield_configs + configs)
```

Then delete the `_reject_ambient_shape!(config)` call in `_parse_subfield_configs` (`:321`) and the entire `_reject_ambient_shape!` method with its comment (`:339-355`). After this, the `.each do |config|` block reads:

```ruby
          _parse_field_configs(*fields, on:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                        metadata:, reader_names:, user_facing:, method_call:, **validations).each do |config|
            _reject_dotted_model_name!(config, fields:)
          end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb -e "shape: on ambient subfields"`
Expected: PASS — leaf shapes validate; non-leaf declarations raise the new placement error.

- [ ] **Step 6: Run the full ambient + full suite**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb && bundle exec rspec`
Expected: PASS (0 failures).

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract_for_subfields.rb lib/axn/core/ambient_context.rb spec/axn/core/ambient_context_spec.rb
git commit -m "PRO-2912: allow shape: on a leaf ambient subfield; reject non-leaf

A shape-carrying ambient node with no subfield children is a leaf, so
_filter_ambient_node copies its whole value and shape validates against
it. A shape node with children is rebuilt from children alone (shape-only
members dropped), so it is rejected at declaration.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Close the ambient sensitive-masking gap (non-Hash shape values)

**Files:**
- Modify: `lib/axn/core/contract.rb` (parametrize `_mask_unfilterable_shapes`; add `_sensitive_ambient_shape_paths`; wire masking into `execution_context`)
- Test: `spec/axn/core/ambient_context_spec.rb`

**Interfaces:**
- Consumes: `_mask_unfilterable_shapes` internals (`_mask_value_at_path`, `_mask_shape_value`, `_mask_opaque_or_preserve`), `_shape_has_sensitive_member?`, `_sensitive_shape_paths`, `_ambient_subfield_tree` (its `.index` is `{config => ResolvedPath}` with `#wire_path`; ambient wire paths are rooted at the synthetic `:ambient_context` segment).
- Produces: `_mask_unfilterable_shapes(data, shape_paths, action_instance)` (paths now passed in); `_sensitive_ambient_shape_paths(action_instance)` → `[[wire_path_within_ambient, shape], ...]`. `execution_context`'s ambient slice masks non-Hash sensitive shape values before ParameterFilter.

- [ ] **Step 1: Write the failing tests**

In `spec/axn/core/ambient_context_spec.rb`, inside the `describe "sensitive: composes down the declared path"` block (near `:445`), add:

```ruby
it "masks a sensitive shape member on an ambient subfield (Hash value) in execution_context" do
  klass = Class.new do
    include Axn
    expects :request, on: :ambient_context, type: Hash do
      field :ip, type: String
      field :token, type: String, sensitive: true
    end
    def call = nil
  end
  inst = klass.send(:new, ambient_context: { request: { ip: "1.2.3.4", token: "secret" } })
  inst._run
  ambient = inst.execution_context[:ambient_context]
  expect(ambient[:request][:token]).to eq("[FILTERED]")
  expect(ambient[:request][:ip]).to eq("1.2.3.4") # non-sensitive sibling preserved
end

it "masks a non-Hash ambient shape value wholesale when a member is sensitive" do
  klass = Class.new do
    include Axn
    expects :request, on: :ambient_context, type: Hash do
      field :token, type: String, sensitive: true
    end
    def call = nil
  end
  inst = klass.send(:new, ambient_context: { request: "111-11-1111" })
  inst._run
  expect(inst.execution_context[:ambient_context][:request]).to eq("[FILTERED]")
end

it "preserves nil absent data rather than masking it for a sensitive ambient shape" do
  klass = Class.new do
    include Axn
    expects :request, on: :ambient_context, type: Hash do
      field :token, type: String, sensitive: true
    end
    def call = nil
  end
  inst = klass.send(:new, ambient_context: { request: nil })
  inst._run
  expect(inst.execution_context[:ambient_context][:request]).to be_nil
end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb -e "masks a non-Hash ambient shape value"`
Expected: FAIL — the non-Hash value `"111-11-1111"` prints whole (the ambient logging path applies only ParameterFilter, which can't descend into a String under the `request` key). The Hash-valued example may already pass (ParameterFilter redacts the `token` key by name); the non-Hash and nil examples drive the change.

- [ ] **Step 3: Parametrize `_mask_unfilterable_shapes` and update its two existing callers**

In `lib/axn/core/contract.rb`, change the signature (`:363`) to take the paths, and update the reduce to use them:

```ruby
        def _mask_unfilterable_shapes(data, shape_paths, action_instance)
          return data unless data.is_a?(Hash)

          shape_paths.reduce(data) do |acc, (wire_path, shape)|
            _mask_value_at_path(acc, wire_path, shape, action_instance)
          end
        end
```

Update `_context_slice` (`:349`) to pass the top-level paths:

```ruby
          sliced = _mask_unfilterable_shapes(data.slice(*_declared_fields(direction)), _sensitive_shape_paths(action_instance), action_instance)
```

Update `_mask_unfilterable_shape_value` (`:373-375`):

```ruby
        def _mask_unfilterable_shape_value(field, value, action_instance)
          _mask_unfilterable_shapes({ field => value }, _sensitive_shape_paths(action_instance), action_instance)[field]
        end
```

- [ ] **Step 4: Add the ambient shape-path collector**

In `lib/axn/core/contract.rb`, add near `_sensitive_shape_paths` (`:381`):

```ruby
        # The ambient analog of `_sensitive_shape_paths`: `[(wire_path_within_ambient, shape)]` for
        # every ambient subfield whose shape carries a sensitive member. Ambient shapes are leaf nodes
        # (`_check_ambient_shape_placement!`), so their value is copied whole and may be a non-Hash the
        # ParameterFilter can't descend into — this feeds `_mask_unfilterable_shapes` to mask it. The
        # ambient tree's wire paths are rooted at the synthetic `:ambient_context` segment; drop it,
        # since the mask applies to the ambient VALUE the reader returns, not a hash wrapped under an
        # `:ambient_context` key.
        def _sensitive_ambient_shape_paths(action_instance)
          _ambient_subfield_tree.index.filter_map do |config, path|
            shape = config.validations.is_a?(Hash) ? config.validations[:shape] : nil
            next unless shape.is_a?(Hash) && _shape_has_sensitive_member?(shape, action_instance)

            [path.wire_path.drop(1), shape]
          end
        end
```

- [ ] **Step 5: Wire ambient masking into `execution_context`**

In `lib/axn/core/contract.rb`, update the ambient slice in `execution_context` (`:1131-1134`):

```ruby
          ambient = _safe_execution_context_slice do
            ambient_filter = self.class._has_dynamic_sensitive_fields? ? self.class._build_instance_filter(self) : self.class.inspection_filter
            masked = self.class._mask_unfilterable_shapes(ambient_context, self.class._sensitive_ambient_shape_paths(self), self)
            ambient_filter.filter(masked)
          end
```

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb -e "sensitive"`
Expected: PASS — non-Hash masked wholesale, Hash member redacted by name, sibling preserved, nil preserved.

- [ ] **Step 7: Run the full suite (masking is shared machinery)**

Run: `bundle exec rspec`
Expected: PASS (0 failures) — the two refactored callers keep their existing behavior (they now pass `_sensitive_shape_paths(...)` explicitly).

- [ ] **Step 8: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/ambient_context_spec.rb
git commit -m "PRO-2912: mask non-Hash sensitive shape values on the ambient log path

execution_context applied only ParameterFilter to ambient, which can't
descend into an object-backed/malformed shape value. Route the ambient
hash through PR #176's _mask_unfilterable_shapes with ambient-scoped
shape paths first.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: CHANGELOG + docs

**Files:**
- Modify: `CHANGELOG.md` (reconcile the PRO-2909 entry; add a PRO-2912 entry)
- Modify: `docs/reference/class.md` (`:262`, `:302`, `:374`)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Reconcile the PRO-2909 CHANGELOG entry**

In `CHANGELOG.md`, the `[FEAT] on: :ambient_context subfields can now nest to any depth (PRO-2909)` bullet ends with claims this PR reverses (both are still `Unreleased`, so they must not ship contradicting each other). Edit that bullet's tail: remove the sentence beginning "The per-invocation restrictions are unchanged and now apply at every depth: `default:`/`preprocess:`/`coerce:` … still raise at declaration …" and the following "A `shape:` block on an ambient subfield is also rejected … Full shape symmetry on ambient is deferred to a follow-up." Replace them with a single sentence keeping the still-true parts:

```
Declaration-time contradiction checks (PRO-2889/PRO-2901) now run against the ambient subtree as well, so a nested ambient contract is rejected exactly like its non-ambient twin (e.g. a `type: String` ambient parent with a required child that a String can never answer).
```

(That is, end the PRO-2909 bullet at the contradiction-checks sentence; the removed restriction/shape sentences are superseded by the PRO-2912 bullet below.)

- [ ] **Step 2: Add the PRO-2912 CHANGELOG entry**

At the top of the `## Unreleased` list in `CHANGELOG.md`, add:

```
* [FEAT] Full symmetry restored for `on: :ambient_context` subfields (PRO-2912). `default:`, `preprocess:`, and `coerce:` are now supported on any ambient subfield (nested or dotted included): they resolve on the same non-mutating read path (`resolve_value`) as every other subfield, so a defaulted/coerced/preprocessed ambient value is what both the reader and inbound validation see — no write-back to `provided_data` is involved (the write-back model that justified the old rejection was gone as of PRO-2903). A `shape:` block is now supported on an ambient subfield that is a **leaf** (no nested subfields): the ambient filter copies a leaf's whole value, so the shape validates against it (its schema-emission role stays moot — ambient is excluded from `input_schema`). A shape node that also declares nested subfields is rejected at declaration (the filter rebuilds such a node from its children alone, dropping shape-only members), pointing at declaring the nested structure one way — shape for validation only, or subfields for validation plus readers and `sensitive:`. A `sensitive:` shape member on an ambient subfield is masked in exception context, including when the ambient value is a non-Hash the key-name filter can't descend into (masked wholesale). `user_facing:` remains rejected on ambient subfields — an ambient value is framework-supplied, so there is no caller to face regardless of resolution mechanism.
```

- [ ] **Step 3: Update the docs ambient restriction copy**

In `docs/reference/class.md`:

At `:262`, change the last sentence from:

```
The only exception is an ambient parent (`on: :ambient_context`), whose value is framework-supplied per-invocation and does not support `default:`/`preprocess:`.
```

to:

```
An ambient parent (`on: :ambient_context`) supports `default:`/`preprocess:`/`coerce:` the same way — they resolve on the read path against the framework-supplied value; only `user_facing:` stays unsupported there (see below).
```

At `:302`, replace the sentence beginning "Because ambient values are resolved per-invocation and never read from the inbound arguments, `default:`, `preprocess:`, and `coerce:` are **not** supported …" and the following "A `shape:` block is **not** supported on an ambient subfield either …" with:

```
`default:`, `preprocess:`, and `coerce:` are supported on any ambient subfield (nested or not) — they resolve on the read path against the framework-supplied value, exactly as for every other subfield. `sensitive:` is supported and composes down the path. A `shape:` block is supported on an ambient subfield that is a **leaf** (no nested subfields): the filter copies a leaf's whole value, so the shape validates against it. A shape node that also declares nested subfields is rejected at declaration — declare the nested structure one way, either the `shape:` (validation only) or subfields (`expects :ip, on: :request`, which also give readers and `sensitive:`). `user_facing:` is **not** supported on an ambient subfield: an ambient value is framework-supplied, so there is no caller to face.
```

At `:374`, change the `coerce:` sentence tail from:

```
It works on top-level `expects` fields and subfields (`on:`) alike — except ambient_context subfields, whose values are never read from the inbound arguments.
```

to:

```
It works on top-level `expects` fields and subfields (`on:`) alike, including ambient_context subfields (the coerced value is what the reader and validation see).
```

- [ ] **Step 4: Verify no stale ambient-restriction copy remains**

Run: `grep -rn "not supported.*ambient\|ambient.*not support\|deferred to a follow-up\|shape symmetry on ambient is deferred" docs/ CHANGELOG.md`
Expected: only matches about `user_facing:` staying unsupported (which is correct). No matches claiming `default:`/`preprocess:`/`coerce:`/`shape:` are unsupported.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md docs/reference/class.md
git commit -m "PRO-2912: CHANGELOG + docs for restored ambient symmetry

Reconcile the still-Unreleased PRO-2909 entry (drop the now-false
restriction/deferral tail) and document that default:/preprocess:/coerce:
+ leaf shape: are supported on ambient subfields; user_facing: stays out.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] Run the full suite once more: `bundle exec rspec` — expect 0 failures.
- [ ] Run rubocop on touched files: `bundle exec rubocop lib/axn/core/contract_for_subfields.rb lib/axn/core/ambient_context.rb lib/axn/core/contract.rb` — expect no offenses (comment/line-length rules included).
- [ ] Confirm `user_facing:` on ambient still raises: `bundle exec rspec spec/axn/core/user_facing_spec.rb` — expect PASS.
- [ ] Re-read the spec's "What we are NOT doing" — confirm no filter-merge was added, `input_schema` is unchanged (ambient still excluded), and the normal (non-exception) logging path is untouched.
