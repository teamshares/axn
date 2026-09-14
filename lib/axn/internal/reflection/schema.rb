# frozen_string_literal: true

require "date"
require "time"
# A residue renders the fragment it declined to conjoin verbatim, so the builder cannot load without an encoder.
require "json"

# Prose a residue composes is caller-supplied in part, and a literal it mentions need not be JSON-encodable,
# so both go through the seams that own rendering rather than being concatenated or encoded directly.
require "axn/internal/text"
require "axn/internal/rendering"

require "axn/internal/identity"
require "axn/internal/native_methods"
require "axn/internal/subfield_tree"
# A property name in an emitted schema is the canonicalization's answer, so the builder cannot load without it.
require "axn/internal/reflection/values"
# A `format:` field's `pattern` is this module's translation, so the builder cannot load without it either.
require "axn/internal/reflection/pattern"

# The `model:` id convention and the conditional-gate keys are both read on the build path, so the builder
# cannot load without their owner either.
require "axn/internal/field_config"
require "axn/internal/shape_graph"
# transforms_wire_value? asks whether a token is one of Coercion::SUPPORTED's coercion targets, so the
# builder cannot load without that constant either.
require "axn/internal/coercion"

# The graph this builder walks is one the class merely HOLDS, so the builder cannot load without the two
# bounds every such walk needs (see `guard_contents_descent`).
require "axn/internal/cycle_guard"

# Blankness asks a RUNTIME VALUE whether it is blank/empty and how big it is — no JSON Schema in it at all,
# and `Core::Contract`'s declaration guards read the same answers, so it lives in its own file.
require "axn/internal/reflection/schema/blankness"

# Gates forwards every validator-set question to `Validation::Base`, so a config's own `optional?` and the
# emitted property's requiredness cannot answer differently.
require "axn/internal/reflection/schema/gates"

# TypeTokens maps one declared type token to one JSON type — the leaf every typing decision bottoms out in.
require "axn/internal/reflection/schema/vocabulary"
require "axn/internal/reflection/schema/type_tokens"

# Contents is the recursive descent into a container's elements/values/keys and a shape's named members.
require "axn/internal/reflection/schema/contents"

# ModelId owns the generated `<field>_id` property and the reconciliation deciding its type.
require "axn/internal/reflection/schema/model_id"

# Sizing owns the size and blank axes — including the derivations Contract's declaration guard reads back.
require "axn/internal/reflection/schema/sizing"

# Nestability answers whether a position can hold JSON object properties — the drop pass and the emitter
# both read it, so neither can decide for itself.
require "axn/internal/reflection/schema/nestability"

module Axn
  module Internal
    module Reflection
      # Builds JSON Schema (input/output) from an Axn's declared contract. Read-only, off the execution
      # path — it inspects declared field configs, never runs the action or its validators.
      #
      # REQUIREDNESS IS DERIVED FROM DECLARED SIGNALS, NOT BY VALIDATING.
      # A field is omittable (absent from `required`) when a declared signal says so — a usable default, or a
      # nil-tolerant validator set (`optional:`/`allow_nil:`/`allow_blank:`). A field that rejects nil by type
      # alone (`allow_empty: true`) stays required and non-nullable: emptiness is permitted, absence is not.
      # We deliberately do NOT run the field's validators against its default to confirm the omitted call
      # would actually pass; that duplicate-validation pass was expensive and fragile. The tradeoff is a
      # documented divergence, narrow: a non-blank but otherwise-invalid default (`type: String,
      # default: 123`; `type: :uuid, default: "nope"`) is reflected as optional though the omitted call
      # fails at runtime. The safe direction (schema stricter than runtime) never causes failed calls; the
      # unsafe case above only arises from a self-contradictory contract and surfaces as a normal,
      # recoverable validation error. A required subfield at ANY depth forces its whole ancestor chain
      # required and non-nullable (a nil/omitted ancestor yields every descendant absent, PRO-2857).
      module Schema
        # Which JSON Schema keyword each ActiveModel comparison operator becomes. The exclusive pair is the
        # draft-06+ NUMERIC form (`exclusiveMinimum: 0`), not draft-04's boolean flag beside `minimum:`.
        NUMERIC_BOUND_KEYS = {
          greater_than: :exclusiveMinimum,
          greater_than_or_equal_to: :minimum,
          less_than: :exclusiveMaximum,
          less_than_or_equal_to: :maximum,
          equal_to: :const,
        }.freeze

        # The emitted types a numeric bound keyword applies to. A bound on any other type would be ignored by a
        # validator at best and invalid at worst, so it is not emitted there at all.
        NUMERIC_TYPES = %w[integer number].freeze

        # The two entries that compare a value against a bound, and whether ActiveModel reads an `in:` range for
        # each — `numericality:` does (`RANGE_CHECKS`), `comparison:` has no range check.
        NUMERIC_BOUND_ENTRIES = { numericality: true, comparison: false }.freeze
        EXCLUDED_FROM_INPUT_SCHEMA = %i[ambient_context].freeze

        # Per-node result of the single bottom-up derivation pass (derive_annotations): `required` means
        # the node must appear in its PARENT's `required` array (mirrors node_optional?'s own-level rule,
        # using the node's FULL config set — the same default `children_require_presence?` always used);
        # `nullable` means `null` is admissible on the node's OWN emitted property, decided from the
        # node's non-model representative config (the same one apply_nested_subfields!'s callers already
        # select) and its children (mirrors required_child?, hazard disjunct included). Only meaningful
        # for a node that HAS children to nest (a leaf's own nullability is decided by build_property,
        # never read from here).
        NodeAnnotation = Data.define(:required, :nullable)

        # A constraint the contract enforces and the emitted document cannot state, recorded where it is
        # declined so the gap is reported rather than silent. `summary` is one clause naming what still
        # applies ("must equal 5 after coercion to Integer"); `kind` separates a limit of JSON Schema
        # itself (`:inherent`) from one axn has simply not taught the emitter yet (`:unfixed`), so the
        # audit's exclusion list can shrink as the latter are closed and can never silently grow.
        Residue = Data.define(:summary, :kind)

        # Residues ride on the property they belong to under this key while it is being built, and are
        # rendered into `description` and stripped by `finalize_residues!` before the schema is returned.
        # A non-emitted key rather than a parallel accumulator threaded through every builder: a property
        # already travels the whole emission path, and the one place that knows how to render them is then
        # also the one place that has to know they exist.
        RESIDUE_KEY = :__axn_residues

        RESIDUE_PREFACE = "Additional constraints apply that JSON Schema cannot express: "

        TRANSFORM_RESIDUE = "the value is transformed before these are checked, so they cannot be stated on the wire form"

        # Every blank a JSON document can carry. `false` is among them: ActiveSupport counts it blank, which
        # is what an ungated `presence:` rejects — and so is `nil`, which is why it is listed here even
        # though `reject_null!` independently strips a null branch on the nested-child path. The floor is
        # only ever restored where some config's ungated `presence:` rejects blank, and such a config also
        # answers `nil_allowed?` false, so naming nil here cannot narrow a nil-tolerant position; it closes
        # the axis path, where that separate null pass does not reach.
        BLANK_WIRE_VALUES = ["", [], {}, false, nil].freeze

        # Keys a gate can never remove, so a diff between the full and always-run properties must not read
        # them as removed. `default:` is not a validator entry — it is applied whatever any condition says —
        # and comparing it by VALUE misreported it anyway, since `Float::NAN == Float::NAN` is false and a
        # NaN default therefore looked removed on every call.
        RESIDUE_UNGATEABLE_KEYS = [:description, :default, RESIDUE_KEY].freeze

        GATED_RESIDUE = "a conditional declaration at this position contradicts this one, so it applies only on the calls " \
                        "its condition opens"

        # Where a subschema can live in what this emitter emits — a map of name => subschema, a single
        # subschema, or a list of them. Kept to the keywords it actually writes (`build_property`,
        # `apply_structured_schema!`, `conditional_requiredness_clause`, `write_pattern!`) so the
        # residue walk descends only into NODES and never into a declaration's own literal values.
        SUBSCHEMA_MAPS = %i[properties].freeze
        SUBSCHEMA_NODES = %i[items additionalProperties propertyNames not if then else].freeze
        SUBSCHEMA_LISTS = %i[allOf anyOf].freeze

        # Extracted modules are mixed in rather than delegated to: their methods stay reachable as
        # `Schema.foo` for the callers outside this file, and as a bare call from every method inside it,
        # so the split is about where the code LIVES, not about re-routing anyone.
        include Vocabulary
        extend Blankness
        extend Gates
        extend TypeTokens
        extend Contents
        extend ModelId
        extend Sizing
        extend Nestability

        module_function

        # Attach a residue to the property it qualifies, returning the property. Deduplicated by summary —
        # a collision judged at two depths reports the same clause once.
        def record_residue(prop, summary, kind: :inherent)
          return prop if summary.nil?

          existing = prop[RESIDUE_KEY] || []
          return prop if existing.any? { |r| r.summary == summary }

          prop.merge(RESIDUE_KEY => existing + [Residue.new(summary:, kind:)])
        end

        def residues_on(prop) = prop.is_a?(::Hash) ? (prop[RESIDUE_KEY] || []) : []

        # Render every residue in a finished schema into its property's `description` and strip the
        # carrier key, collecting `[path, residue]` pairs for the once-per-class warning. The rendering
        # APPENDS: an author's own `description:` is the field's documentation and this is a footnote to
        # it, never a replacement.
        #
        # A FROZEN node is skipped whole: the emitter hands out shared frozen constants for the fixed
        # shapes (NULL_BRANCH, EMPTY_ENUM) and for the witnesses a consumer must not be able to mutate
        # into another action's schema, and none of them can carry a residue — so descending into one
        # could only ever raise.
        def finalize_residues!(schema, path: [], collected: [])
          return [schema, collected] unless schema.is_a?(::Hash)
          return [schema, collected] if schema.frozen?

          residues = schema.delete(RESIDUE_KEY)
          if residues&.any?
            residues.each { |r| collected << [path.dup, r] }
            clause = "#{RESIDUE_PREFACE}#{residues.map(&:summary).join('; ')}."
            # Each part is rendered BEFORE the join. An author's `description:` is caller-supplied text and
            # may be valid in an encoding this generated prose cannot concatenate with (a UTF-16 String
            # raises outright); joining first and rendering after would raise from inside the composition.
            schema[:description] = join_prose(schema[:description], clause)
          end

          # Only the keywords that HOLD a subschema are descended into. Walking every Hash and Array
          # instead reaches a declaration's own literals — a `default:`/`enum:`/`const:` value is the
          # author's data, not a node — and a literal `{ __axn_residues: [...] }` there was deleted and
          # then read as residues, raising `NoMethodError` on a String mid-reflection. The three shapes
          # below are the ones this emitter actually writes; a keyword it does not emit is not listed,
          # since a position nothing writes is one nothing has to be protected from.
          SUBSCHEMA_MAPS.each do |key|
            node = schema[key]
            next unless node.is_a?(::Hash)

            # The segment is carried RAW, never rendered here: a declared name is caller-supplied and
            # reflection may not dispatch on one (a `to_s` that raises took the whole reflection down
            # once already, and one that counts its calls sees this walk as a second ask). Whoever
            # reports a residue renders the path through PropertyNames' own escaping labeler.
            node.each { |name, sub| finalize_residues!(sub, path: path + [name], collected:) }
          end

          SUBSCHEMA_NODES.each { |key| finalize_residues!(schema[key], path:, collected:) }

          SUBSCHEMA_LISTS.each do |key|
            node = schema[key]
            next unless node.is_a?(::Array)

            node.each { |sub| finalize_residues!(sub, path:, collected:) }
          end

          [schema, collected]
        end

        # An attribute a config may or may not carry, read tolerantly: `#description` and `#default`, enumerated at
        # each call site. A `FieldConfig` answers both and a `ShapeConfig` answers `#description` only (a member is
        # reader-less, so `default:` is rejected on one), which is what this exists for — one emission path over two
        # config types, plus the configs a downstream caller builds itself and hands to the public `build_input`.
        #
        # `ShapeGraph.read` is the same tolerant read the declaration guards use, so both layers agree about what a
        # config has.
        def declared_attribute(config, name) = Axn::Internal::ShapeGraph.read(config, name)

        # A member's NAME, or nil when it has none. Even `#field` is read tolerantly, and skipped rather than
        # raised on: a DECLARED member always has one (the walk rejects a nameless member and stores a Symbol), so
        # what this tolerance is for is the configs a caller builds itself and hands to the public `build_input`.
        def member_name(member)
          name = Axn::Internal::ShapeGraph.fetch(member, :field)
          Axn::Internal::ShapeGraph.missing?(name) ? nil : name
        end

        # The `required` entry for a property keyed by `name`: a String holding the bytes that name is KEYED by.
        #
        # Rendered from a String's own bytes rather than by dispatching its `to_s`, for the same reason
        # `member_properties` renders a member's entry from the one Symbol it keyed the property by: `required` and
        # `properties` are two readers of one name, and a name that answers them differently lists a required
        # property this schema never emitted — a schema no input can satisfy. Ruby stores a plain String key as a
        # frozen copy of its bytes, so a SINGLETON `to_s` on such a name diverted the `required` entry alone, needing
        # no second declaration to go wrong.
        #
        # A Symbol keeps the rendering it always had, which is Ruby's own and cannot be overridden at all (a Symbol
        # takes no subclass instance and no singleton). So does anything else, because the property-name rules refuse
        # a name that renders through its own code (`NativeMethods.native_name_rendering?`) before any validated
        # projection returns — only the public `build_input`/`build_output` reach here with one.
        #
        # Every site that writes a `required` entry goes through this, not only the two a caller's own name can reach
        # (a top-level inbound field and an exposed one). At the others the name has already been interned to a Symbol
        # by the time it arrives — `SubfieldTree` interns a wire segment, `model_id_key` builds the generated id, and a
        # conditional-requiredness clause is emitted only for a framework-generated reader — so this is a no-op there.
        # They route through it anyway so that "what String does a `required` entry hold" has one answer rather than
        # one per site, which is how the top-level pair came to disagree with `properties` in the first place.
        def required_key(name)
          case name
          when ::String then ::String.new(name)
          else name.to_s
          end
        end

        # The members of a shape that actually name a property, paired with that name.
        # Captured through the shared seam rather than iterated directly: `Array(...)` preserves a caller's
        # Array SUBCLASS and then dispatches its `filter_map`, so a list answering that differently from `each`
        # made reflection disagree with the declaration guard and the runtime validator — which both capture with
        # `each` — about which members exist. One owned Array, three consumers.
        def named_members(members)
          Axn::Internal::ShapeGraph.capture(members).filter_map { |m| (name = member_name(m)) && [m, name] }
        end

        # Subfields nest recursively: a dotted `on:` path, a subfield of a subfield, and a dotted field
        # name all become nested object properties keyed by wire key (SubfieldTree resolves reader
        # aliases and dotted segments once, up front). A STRUCTURAL EXCLUSION remains: a deep subfield
        # whose chain passes through a `model:` parent (the client sends `<field>_id`, not the object) or
        # a non-object parent (`type: Array`, a mixed union) has no JSON-object representation, so it's
        # omitted — surfaced via dropped_deep_subfields / the input_schema warning. A depth-1 subfield
        # under such a parent is silently omitted (the parent keeps its declared type), as ever.
        #
        # `resolved:` accepts a prebuilt ResolvedSubfields artifact (the per-class cache) so callers on
        # a repeated path skip the tree build + annotation derivation; it must have been built from the
        # same configs. Without it, both are computed fresh — the standalone entry point is unchanged.
        # The inbound projection OF A CLASS. The one place `build_input`'s argument list is assembled from a
        # class, so the reflected reader and the setup-time validator cannot drift into building two different
        # schemas from the same declaration.
        #
        # `residues:` is an optional array to collect `[path_segments, Residue]` pairs into — what the contract
        # enforces and this document cannot state. The schema always carries them as prose in the relevant
        # `description`; a caller passing this array also gets them structured, which is what the
        # once-per-class warning and the wire audit's exclusion list read.
        def build_input_for(klass, residues: nil)
          build_input(klass.internal_field_configs, klass.subfield_configs, resolved: klass._resolved_subfields, klass:, residues:)
        end

        def build_input(field_configs, subfield_configs = [], resolved: nil, klass: nil, residues: nil)
          tree = resolved&.tree || Axn::Internal::SubfieldTree.build(field_configs, Array(subfield_configs))
          ann = resolved&.annotations || derive_annotations(tree.roots)
          properties = {}
          required = []
          conditionals = []

          field_configs.each do |config|
            next if EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)

            # The config's OWN node, through the index rather than by reader name: a name can be claimed
            # by one declaration while another config yields it (SubfieldTree.build), and a config must
            # reflect its own contract — the children nested under it, the requiredness derived from them
            # — not the ones belonging to whoever holds the name.
            node = tree.index[config].node
            if config.validations[:model]
              # Emit the generated `<field>_id` property (don't clobber an explicitly-declared one). Its
              # requiredness/nullability is decided in the post-pass below so it can account for an
              # explicit `<field>_id` sibling regardless of declaration order.
              #
              # A NON-model sibling ALWAYS wins the property regardless of which is visited first (its
              # own branch below writes unconditionally; this branch only `||=`s), so when one exists
              # anywhere in `field_configs` — checked BEFORE building anything, since the whole list is
              # known upfront — building `id_prop` here would just be discarded. Skipping it matters
              # beyond the wasted allocation: for an ActiveRecord model, `model_id_property` dispatches
              # `primary_key`/`type_for_attribute` (PRO-3384) to infer the id's type, and that dispatch,
              # and the DB/schema access behind it, has no reason to run for a result nothing will use.
              #
              # MODEL configs sharing this name are excluded from that check: a field named `company_id`
              # that is ITSELF a `model:` field emits at `company_id_id`, not at `company_id` — it never
              # touches this key at all — so treating it as the winning sibling skipped the ONLY thing
              # that would have written `company_id`'s property, leaving a `required` entry with no
              # matching property.
              id_field = Axn::Internal::FieldConfig.model_id_key(config.field)
              unless field_configs.any? { |c| c.field == id_field && !c.validations[:model] }
                id_type = reconciled_model_id_type_token([config], id_field)
                _, id_prop = model_id_property(config, id_type)
                properties[id_field] ||= id_prop
              end
            else
              prop = build_property(config)
              apply_nested_subfields!(prop, node, ann)

              properties[config.field] = prop.compact
              unless field_optional?(config, node.children, ann)
                clause = conditional_requiredness_clause(config, tree, node, klass)
                clause ? conditionals << clause : required << required_key(config.field)
              end
            end
          end

          # Second pass (after all properties exist, so it's independent of declaration order): decide each
          # generated model `<field>_id`'s requiredness/nullability from the model field + its explicit sibling.
          field_configs.select { |config| config.validations[:model] }.each do |config|
            children = tree.index[config].node.children
            apply_model_id_requiredness!(config, children, field_configs, properties, required, ann)
          end

          schema = { type: "object", properties: }
          schema[:allOf] = conditionals unless conditionals.empty?
          schema[:required] = required.uniq unless required.empty?
          finalize_residues!(schema, collected: residues || [])
          schema
        end

        # The subfield configs build_input omits from the input schema: deep configs (a dotted `on:`
        # path, a subfield of a subfield, or a dotted field name) whose chain passes through a `model:`
        # or non-object parent, so they have no JSON-object representation. They validate at runtime but
        # are absent from the schema; a caller can surface this otherwise-silent gap. A representable deep
        # chain (every explicit ancestor object-shaped) is NOT dropped — it nests in the schema.
        # Subfields rooted at a deliberately-excluded parent (EXCLUDED_FROM_INPUT_SCHEMA, e.g.
        # ambient_context) are skipped: their absence is intentional. Side-effect-free (SubfieldTree
        # inspects declared configs only).
        #
        # `resolved:` accepts the per-class ResolvedSubfields cache, whose `dropped` was already computed
        # from the same tree at build time (see ResolvedSubfields.build) — reading it here is a cheap
        # reader, not a recomputation. Without it, both the tree and the verdict are built fresh.
        def dropped_deep_subfields(field_configs, subfield_configs, resolved: nil)
          return resolved.dropped if resolved

          dropped_from_deep_paths(Axn::Internal::SubfieldTree.build(field_configs, Array(subfield_configs)).deep_paths)
        end

        # The judgment over a tree's deep candidates: which of the `[config, hops]` pairs SubfieldTree.build
        # collected (a config reached through more than one hop) have no JSON-object representation. Tree
        # construction only COLLECTS these — whether a chain can hold JSON object properties is a question
        # about what this layer can EMIT, so the two public entry points (this one, and dropped_deep_subfields
        # for a caller that has only configs, not a built tree) both funnel through the same private judgment.
        def dropped_from_deep_paths(deep_paths)
          compute_dropped(deep_paths)
        end

        # A deep config is dropped when a node it passes THROUGH (each hop's parent; never the leaf itself)
        # can't hold JSON object properties. Judged on the finished tree so declaration order doesn't matter.
        def compute_dropped(deep_paths)
          deep_paths.filter_map { |config, hops| config if path_blocked?(hops) }
        end

        # Walk a deep config's ancestor chain hop by hop, carrying the shape members an implicit hop merged
        # into so a deeper implicit hop can test their OWN nested shape members (a member-of-a-member).
        # `carried` is the object-shaped member configs the current node stands in for (empty for a real
        # node or a fresh implicit intermediate that claimed no shape member).
        #
        # Public: PropertyNames.emitted_configs asks this at EVERY depth (not just the deep configs
        # compute_dropped reports), because the emitter blocks a property at whichever ancestor blocks it —
        # so property attribution needs the same per-hop answer, not a second predicate that could drift.
        def path_blocked?(hops)
          carried = []
          hops.each do |node, key|
            return true if blocking_ancestor?(node, key, carried)

            carried = merged_shape_members(node, key, carried)
          end
          false
        end

        # An explicit ancestor blocks nesting when its configs forbid it (a `model:` route, or a non-object /
        # mixed-union type on any route) — node_configs_block_nesting? is the single source of truth emission's
        # apply_nested_subfields! gates on too, so the drop pass and the schema agree (they are the same method,
        # not two copies of one rule). An implicit ancestor never blocks on its own type — but descending into
        # an IMPLICIT child whose key collides with a non-object `shape:` member does: the member property
        # already claims that key with a non-object type, so the deep structure has nowhere to live. Those
        # members come from the node's own explicit configs AND every member this implicit node merged into
        # (`carried`), so a member of a member is tested at depth.
        def blocking_ancestor?(node, key, carried = [])
          return true if node_configs_block_nesting?(node.configs)
          return false unless node.children[key]&.implicit?

          colliding_shape_members(node, key, carried).any? { |m| !nestable_as_object?(m) }
        end

        # The shape members a node (via its explicit configs or the `carried` members it merged into) declares
        # at `key` AND the descent merges there — carried into the next hop. Empty when nothing merges.
        #
        # Both kinds of child merge, because emission merges at both: an IMPLICIT child carries every nestable
        # colliding member (a non-nestable one would already have blocked in blocking_ancestor?, so the select
        # is the same all-or-nothing answer stated defensively), and an EXPLICIT child carries whatever
        # merged_explicit_members says it merges — the one predicate apply_children! asks too, so the drop pass
        # and the schema cannot disagree about which members a descent represents.
        # `configs` is which of the node's routes may contribute a member, and the two callers want different
        # answers. The drop pass passes them ALL (the default), because every route is ENFORCED and a
        # non-nestable member on any of them must block whether or not it is emitted. `emitted_shape_sources`
        # passes the representative alone, because it asks what the document CONTAINS and only the
        # representative route's shape is ever emitted.
        def merged_shape_members(node, key, carried, configs = node.configs)
          child = node.children[key]
          return NO_SHAPE_MEMBERS unless child

          members = shape_members_at(carried.empty? ? configs : configs + carried, key)
          return members.select { |m| nestable_as_object?(m) } if child.implicit?

          merged_explicit_members(child, members)
        end

        # The colliding `shape:` members an EXPLICIT child merges into its own property, or none.
        #
        # THE owner of that question, for emission (apply_children!) and the drop pass (merged_shape_members)
        # alike. Two gates, each the one its own layer already applies elsewhere: the child must nest at all
        # (node_configs_block_nesting?, the same predicate apply_nested_subfields! gates on), and EVERY
        # colliding member must be object-shaped (nestable_as_object?, the same predicate apply_implicit_node!
        # gates on). All-or-nothing on the second, so a member whose contents have no object representation
        # never contributes half of itself.
        #
        # A non-nestable member does NOT block the child the way it blocks an implicit one: the child's own
        # declared type governs what it emits, and a `type: Hash` node under a `type: [Hash, Array]` member
        # still nests its subfields as properties — runtime narrows to the Hash branch there, and a contract
        # written that way resolves for real (measured). It only means the member's own contents are not
        # merged in, because they describe branches this node does not admit.
        def merged_explicit_members(child, members)
          return NO_SHAPE_MEMBERS if members.empty?
          return NO_SHAPE_MEMBERS if node_configs_block_nesting?(child.configs)

          members.all? { |m| nestable_as_object?(m) } ? members : NO_SHAPE_MEMBERS
        end

        NO_SHAPE_MEMBERS = [].freeze

        # Every `shape:` member declared at `key` across the node's own configs AND the members carried from
        # a shallower hop — via shape_members_at, the same locator emission uses, so the two sides can't
        # disagree on which members collide with the implicit child at `key`.
        def colliding_shape_members(node, key, carried)
          return shape_members_at(node.configs, key) if carried.empty?

          shape_members_at(node.configs + carried, key)
        end

        private_class_method :compute_dropped, :blocking_ancestor?, :merged_shape_members, :colliding_shape_members,
                             :merged_explicit_members

        # The configs whose `shape:` members reflection EMITS at the node a subfield's parent occupies: the
        # representative of that node's own routes (the only one `apply_structured_schema!` builds a property
        # from), plus every ancestor member the descent merged on the way down, carried hop by hop exactly as
        # `apply_children!` carries it.
        #
        # Public, and the reason the carry has one owner rather than a copy per caller: `Core::Contract`'s
        # declaration guards judge a claim by what the emitter WRITES, so they have to read this walk instead
        # of predicting it — and a copy that fell behind (this one reset the carry at an explicit hop, as
        # emission itself once did) silently stopped seeing claims that were in the document.
        #
        # EMITTED is the whole of it, so the walk carries only what the representative route declares at each
        # hop: `apply_structured_schema!` builds a node's property from that route alone, and the ancestor
        # merge conjoins a member only where the ancestor emitted one to conjoin with. Carrying every route's
        # members instead made this find a claim the document does not contain, and the guard then refused a
        # declaration `main` accepts — the exact inverse of the defect the carry was added to fix, and the
        # reason "which route declared it" cannot be dropped in favour of "is it enforced".
        #
        # Asked of a SUBFIELD path, the only kind with a parent node to describe: a depth-0 config has no
        # ancestors, and the caller answers that case before reaching here (a top-level field's own shape is
        # read straight off the config).
        def emitted_shape_sources(path)
          carried = NO_SHAPE_MEMBERS
          path.ancestors.first(path.parent_index).each do |(node, segment)|
            carried = merged_shape_members(node, segment, carried, Array(property_representative(node.configs)))
          end
          Array(property_representative(path.parent_node.configs)) + carried
        end

        # One bottom-up pass over the whole subfield tree, computed once from build_input and threaded
        # through every emission site below (apply_nested_subfields!/apply_children!/apply_implicit_node!/
        # apply_model_id_requiredness!) instead of each of them independently re-walking the subtree via
        # subtree_requires_presence?/required_child? — the repeated-recomputation pattern that let a
        # dropped/blocked deep shape agree at some sites but not others.
        # `compare_by_identity`: SubfieldTree::Node is a plain Data value, so identity (not #==/#hash on its
        # contents) is what distinguishes one tree position from another.
        def derive_annotations(roots, satisfiability: false)
          ann = {}.compare_by_identity
          roots.each_value { |node| annotate_node!(node, ann, satisfiability:) }
          ann
        end

        # Post-order: a node's annotation only depends on its (already-annotated) children.
        def annotate_node!(node, ann, satisfiability: false)
          node.children.each_value { |child| annotate_node!(child, ann, satisfiability:) }
          credit_sibling_id_defaults!(node, ann) if satisfiability

          # ANCESTOR-FORCING is derived from the RELAXABLE-filtered subset of the node's configs: a route
          # whose requiredness a conditional gate can relax at runtime can't oblige an omitted/nil
          # ancestor to be present — only a route with an UNGATED nil-rejecting check can. That covers
          # both a declaration-level gate (`if:`/`unless:` on the whole declaration) AND a per-validator
          # nested gate on every check that could reject nil (e.g. `presence: { if: -> { data.present? } }`
          # — the presence is gated off when the ancestor is absent, so the omitted ancestor validates).
          # Passing the filtered subset to node_optional? (rather than the full set, then subtracting a
          # fully-gated node afterward) is what makes a MIXED node correct: a node merged from an
          # ungated-but-omittable route (e.g. `optional: true`) and a gated-required route forces nothing,
          # because its only ancestor-relevant obligation — the ungated route — is itself omittable. The
          # prior two-step form (full-set node_optional? then relax only when EVERY config is gated)
          # over-forced exactly that shape, wrongly rejecting a runtime-valid contract in satisfiability mode.
          #
          # This is ONLY the ancestor-propagation signal. Own-level emission stays static-maximal: the
          # emission sites (apply_children!/field_optional?) call node_optional? with the full or
          # per-route config set directly, so a gated route's own nested `required` obligation is
          # unchanged. Edge cases preserved: an implicit node ignores the `configs` param inside
          # node_optional? (a pure subtree test), so its ancestor-forcing is untouched; a fully-relaxable
          # node yields an empty subset, and `[].all?` is vacuously true → node_optional? true → not
          # required; an all-ungated node passes its full set (unchanged).
          # The satisfiability short-circuit inside node_optional? (the usable_default? line) still reads
          # the FULL node.configs regardless of the param, so a node-level default keeps rescuing every
          # route. Mode-independent: satisfiability mode needs it so a declared tolerance above a gated
          # child is exercisable (not dead), and strict mode honors the ancestor's own declared optionality
          # instead of inventing strictness the declaration disavowed (the design doc's "one deliberate
          # exception").
          required = !node_optional?(node, ann, node.configs.reject { |c| requiredness_conditionally_relaxable?(c) }, satisfiability:)

          if node.implicit?
            # An implicit node's nullability has no config of its own to consult (required IS the transitive
            # presence test here), so it's simply the inverse.
            nullable = !required
          else
            # required_child? (and apply_nested_subfields!'s nullability line it feeds) always reasons about
            # the node's non-model representative config — the same one apply_children! emits the property from,
            # read through the one owner of that rule (property_representative). A node with no non-model
            # config (a pure model: route) never nests, so its nullable is unused; false is an inert default.
            representative = property_representative(node.configs)
            nullable = representative ? nil_allowed?(representative) && !required_child?(representative, node.children, ann) : false
          end

          ann[node] = NodeAnnotation.new(required:, nullable:)
        end

        # Satisfiability-only post-adjustment (runs before this node's own requiredness is computed, so the
        # credit propagates up every ancestor): a model-routed child that a sibling `<key>_id` subfield can
        # rescue is re-annotated non-required. The sibling's value-level default supplies the lookup token at
        # read time (see ContractForSubfields.resolve_model_via_id), so omitting the record still
        # resolves it and the record answers the subtree; the record's attributes are unknowable at
        # declaration, so crediting the rescue is the satisfiability doctrine. STRICT (schema) mode is
        # untouched — it keeps its documented stricter-than-runtime divergence for self-referential id/model
        # subfield pairs (apply_model_id_requiredness!'s KNOWN LIMITATION).
        def credit_sibling_id_defaults!(node, ann)
          node.children.each do |key, child|
            next if child.implicit? || !ann[child].required
            next unless sibling_id_rescued?(node, key, child)

            ann[child] = NodeAnnotation.new(required: false, nullable: ann[child].nullable)
          end
        end

        # Whether a node's model route is rescued by a sibling `<key>_id` default — the SINGLE source of
        # truth for both the satisfiability annotation credit (credit_sibling_id_defaults!) and
        # SubfieldContradictions' per-config tolerance loop, so the two can't drift on which nodes the
        # id rescues. Three conjuncts:
        #   * the node carries a `model:` route (the record it resolves answers the subtree at runtime);
        #   * every NON-model route merged onto the node is own-level satisfiability-tolerant (a usable
        #     default or nil-accepting) — own-level only, because the model subtree is satisfied via the
        #     resolved record; it's the non-model route's OWN wire value the id can't supply (a pure-model
        #     node has no non-model route, so the empty set trivially satisfies this); AND
        #   * a sibling `<key>_id` route that this model's lookup would read the token from
        #     (FieldConfig.id_token_routes) carries a default usable as one (usable_id_token_default?
        #     rejects a blank literal — the model resolver blank-guards the id).
        # `parent` is the node whose children include both `node` (keyed by `key`) and the id sibling.
        def sibling_id_rescued?(parent, key, node)
          return false unless node.configs.any? { |c| c.validations[:model] }

          non_model = node.configs.reject { |c| c.validations[:model] }
          return false unless non_model.all? { |c| usable_default?(c, subfield: true, satisfiability: true) || nil_accepted?(c) }

          sibling = parent.children[Internal::FieldConfig.model_id_key(key)]
          return false if sibling.nil?

          # Credited only through the route the LOOKUP will actually read the token from, asked per model
          # route on the node via the one precedence both layers share — otherwise this credits a rescue
          # that never happens, and a nil-tolerant model whose subtree needs it would be accepted at
          # declaration and resolve nil at run time.
          node.configs.select { |c| c.validations[:model] }.any? do |model_config|
            Internal::FieldConfig.id_token_routes(model_config, sibling.configs).any? { |c| usable_id_token_default?(c) }
          end
        end

        # Whether a nil/absent parent leaves a required nested obligation unmet — so it can't validate and
        # the parent is neither omittable nor nullable. Single source of truth for both the parent's
        # requiredness (field_optional?) and nullability (apply_nested_subfields!), so the two never disagree.
        # Two sources:
        #   * a required subfield ANYWHERE in the subtree — a nil parent yields every descendant absent
        #     (PRO-2857), so a required grandchild is stranded exactly like a required child; OR
        #   * a required shape (`do…end`) member WHEN the parent has its OWN applied default that
        #     materializes it: a top-level parent's default still resolves to its materialized value (e.g.
        #     `{}`) through the read-path reader ShapeValidator's `source:` reads, so ShapeValidator runs
        #     against the materialized value and enforces the member — omission can't be rescued by the
        #     parent's nil-tolerance. Counts a Proc default (materialization fires before
        #     the Proc's value matters — the applicability hazard). A SUBFIELD default no longer triggers
        #     this: it resolves the child's value on the read path and never synthesizes the parent, so a
        #     nil parent short-circuits ShapeValidator regardless of any descendant default.
        def required_child?(config, children, ann)
          return true if children_require_presence?(children, ann)

          config.applied_default? && synthesizable?(config) && required_shape_member?(config)
        end

        # Whether any direct child node may NOT be omitted from the parent object — a read of each child's
        # own precomputed annotation, never a fresh descent into its subtree.
        def children_require_presence?(children, ann)
          children.values.any? { |node| ann[node].required }
        end

        # Whether omitting/nil-ing this node's value strands a required descendant — the transitive
        # extension of the one-level required-child test.
        def subtree_requires_presence?(node, ann)
          children_require_presence?(node.children, ann)
        end

        # Whether a node may be absent from its parent object. An implicit node (a dotted-path
        # intermediate with no declaration of its own) is omittable exactly when nothing beneath it
        # requires presence. An explicit node follows the single-level rule at every depth: a usable
        # default always rescues omission (declaration allows a default only when `on:` names a top-level
        # reader, but a dotted field NAME can land that defaulted config on a deeper node — honored here
        # either way; a default whose contents fail a child's validators is the same accepted divergence
        # as at the top level); otherwise it must tolerate nil AND strand no required descendant — a nil
        # node yields every descendant absent (PRO-2857), so a nil-tolerant node with a required subtree is
        # NOT omittable (reflected required/non-nullable, matching runtime). With multiple configs at one node
        # (the same wire path declared via two routes) runtime enforces all of them, so the node is
        # omittable only if every config is. `configs` defaults to the whole node but may be a subset: a
        # merged node's model and non-model routes emit separate properties (`<leaf>_id` vs the object),
        # each required per its own routes' configs, not the node as a whole.
        def node_optional?(node, ann, configs = node.configs, satisfiability: false)
          return !subtree_requires_presence?(node, ann) if node.implicit?

          # Satisfiability doctrine: a default on ANY of the node's OWN configs (node.configs — the FULL
          # set, not the possibly-subset `configs` param) resolves the SHARED value at this node on the
          # read path, so it rescues omission for every route reading it. Each sibling route then validates
          # against that resolved value — being optimistic that the default satisfies each sibling's
          # validator is the satisfiability doctrine (rejection is reserved for provably dead declarations).
          # Gated on satisfiability so strict schema mode stays byte-identical to the per-config rule below.
          return true if satisfiability && node.configs.any? { |c| usable_default?(c, subfield: true, satisfiability: true) }

          configs.all? do |c|
            usable_default?(c, subfield: true, satisfiability:) ||
              (nil_tolerance_rescues_absence?(c, satisfiability:) && !subtree_requires_presence?(node, ann))
          end
        end

        # Whether the parent's shape (`do…end`) block declares a member that isn't schema-optional.
        def required_shape_member?(config)
          named_members(config.validations.dig(:shape, :members)).any? { |m, _name| !optional_for_schema?(m) }
        end

        # A field is absent from `required` when a declared signal makes it omittable.
        def field_optional?(config, children, ann, satisfiability: false)
          has_required_child = required_child?(config, children, ann)

          # A usable default on the PARENT materializes it (with its declared contents) before validation,
          # so it may always be omitted — its own default, not its subfields, decides. (A default whose
          # contents fail a child's validators is a separate, narrow divergence handled by usable_default?.)
          return true if usable_default?(config, subfield: false, satisfiability:)

          # The parent's own nil-tolerance (optional:/allow_nil:) only makes it omittable when no required
          # child would be stranded — so it must be checked AFTER the required-child test, not ahead of it.
          return true if nil_tolerance_rescues_absence?(config, satisfiability:) && !has_required_child

          # No parent-level omission signal remains. A subfield default resolves only the CHILD's value on
          # the read path (ContractForSubfields.resolve_value) — it never synthesizes the parent — so a
          # descendant default cannot rescue the parent's own omission. The parent's requiredness is decided
          # by its OWN signals (own default / own nil-tolerance, above) plus required-child stranding; a
          # child default fixes the child's nil, not the parent's own presence/blank obligation.
          false
        end

        # An exact JSON Schema conditional for a gated-but-otherwise-required top-level field whose
        # single Symbol condition references a declared sibling field. Ruby truthiness on a JSON value
        # is precisely "present, and neither false nor null", so the emitted clause matches the runtime
        # gate exactly. Returns nil — fall back to unconditional `required`, the static-maximal safe
        # direction — unless EVERY guard holds:
        #   * exactly one gate (if: XOR unless:), and its rule is a Symbol;
        #   * the Symbol resolves to a declared top-level inbound field's reader (condition_reference);
        #   * the referenced field carries no default: and no preprocess: (either can make the settled
        #     runtime value diverge from what the caller sent, flipping the gate relative to the wire)
        #     and is not model:-routed (lookup success isn't wire-expressible) nor schema-excluded;
        #   * for an unless: gate, the referenced field's type can't admit boolean coercion of a
        #     schema-admissible wire value coerce_boolean maps to false — a falsy STRING or the integer 0
        #     (boolean_coercion_can_flip_truthiness?). Coercion only flips a truthy wire value to falsey:
        #     for an if: gate that direction keeps the emitted `then`
        #     stricter than runtime (safe — still emitted), but for an unless: gate it opens the runtime
        #     `else` gate the emitted clause left closed (looser than runtime — fall back);
        #   * (a subfield default BENEATH the referenced field needs no guard: value-level defaults
        #     resolve the child's value on the read path and never synthesize the parent — PRO-2903 —
        #     so a wire-omitted referenced field settles nil/falsey exactly as the clause reads it;
        #     a subfield preprocess likewise never materializes an absent root);
        #   * the referenced reader is the FRAMEWORK-GENERATED one — a Symbol condition names a reader
        #     method, but a user can suppress predicate generation (a pre-existing `?` method) or
        #     redefine a plain reader after `expects`, and runtime would then evaluate the USER method
        #     against the settled value while the clause conditions on the wire value. Verified via
        #     source_location against the generation site (framework_generated_reader?), pure
        #     introspection. `klass` is nil for direct build_input callers → fall back (safe direction);
        #   * the gated field is not model:-routed and has no subfields of its own (a required
        #     descendant unconditionally forces the field, contradicting a conditional requirement);
        #   * no NIL-REJECTING validator entry carries a per-validator (nested) gate key — blank or not.
        #     The clause models the DECLARATION gate; a nested gate on a nil-rejecting entry un-ties that
        #     entry from it (AM's measured per-key merge): a blank same-key override un-gates the entry
        #     (unconditionally required — clause looser than runtime), and a non-blank nested gate ties it
        #     to a different condition (also inexact). Nil-TOLERANT nested-gated entries are harmless.
        def conditional_requiredness_clause(config, tree, node, klass)
          return nil if config.validations[:model] || node.children.any?

          gates = config.validations.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
          return nil unless gates.size == 1

          # The emitted clause conditions requiredness on exactly this DECLARATION gate — exact only if
          # every nil-rejecting validator entry inherits that gate unmodified. A nested gate KEY on such an
          # entry breaks that (AM's measured per-key merge, fields.rb#validator_gate_open?): a BLANK
          # same-key nested override un-gates the entry, making it unconditionally required (clause looser
          # than runtime), while a NON-blank nested gate ties the entry to a DIFFERENT condition than the
          # clause emits (also inexact). Either way fall back to unconditional required (the static-maximal
          # safe direction). Nil-TOLERANT entries never reject an omitted value, so a nested gate on them
          # can't affect requiredness — don't fall back on those.
          entries = Axn::Validation::Base.validator_entries(config.validations)
          shared = shared_validation_options(config.validations)
          return nil if entries.any? { |key, opt| !nil_tolerant_validation?(key, opt, shared) && entry_mentions_gate_key?(opt) }

          rule = gates.values.first
          return nil unless rule.is_a?(Symbol)

          ref = condition_reference(rule, tree)
          return nil unless ref
          return nil if ref.validations[:model] || !ref.default.nil? || ref.preprocess
          return nil if EXCLUDED_FROM_INPUT_SCHEMA.include?(ref.field)
          return nil unless framework_generated_reader?(klass, rule)

          # An unless: gate treated static-maximally emits `else: required`, firing only when the
          # referenced wire value is FALSEY. But inbound boolean coercion can flip a schema-admissible
          # truthy wire value ("false"/"f"/"0" as a String, or the JSON number 0) to a falsey settled
          # value, opening the runtime gate while the emitted `if` still reads the wire value as truthy —
          # so the schema would NOT require the gated field though the runtime does (looser than
          # runtime). For an if: gate the same flip makes the schema stricter (the emitted `then` keeps
          # requiring while the runtime gate closes), so only unless: must fall back to unconditional
          # required.
          return nil if gates.key?(:unless) && boolean_coercion_can_flip_truthiness?(ref)

          condition = {
            required: [required_key(ref.field)],
            properties: { ref.field => { not: { enum: [false, nil] } } },
          }
          branch = gates.key?(:if) ? :then : :else
          { if: condition, branch => { required: [required_key(config.field)] } }
        end

        # The declared top-level inbound field a Symbol condition reads: an exact reader-name match,
        # or — for a `?`-suffixed Symbol — the boolean field whose generated predicate alias it names.
        # The condition reads the READER; the emitted schema keys by the field's WIRE key.
        def condition_reference(rule, tree)
          exact = top_level_reader_owner(tree, rule)
          return exact if exact

          name = rule.to_s
          return nil unless name.end_with?("?")

          base = top_level_reader_owner(tree, name.delete_suffix("?"))
          base if base&.boolean?
        end

        # The top-level config whose reader ANSWERS to `name`, via the tree's reader-owner index rather
        # than a scan for a config that merely spells the name: a name can be claimed by one declaration
        # while an inferred confirmation companion yields it (SubfieldTree.reader_owners), and the runtime
        # gate dispatches to the method — so the clause must key on the owner's wire key. A subfield owner
        # is no reference at all: its wire key is a nested property, and the clause names top-level ones.
        def top_level_reader_owner(tree, name)
          owner = tree.reader_owners[name.to_sym]
          owner unless owner.nil? || owner.subfield?
        end

        # Whether inbound coercion could flip the Ruby truthiness of the referenced field between its
        # wire value and its settled value — the ONLY way coercion changes a truthiness judgment, and
        # the reason an unless: gate can't be emitted declaratively for such a field. Coerce-or-leave
        # (Coercion.coerce_value) transforms String wire values through the parse-based COERCERS, and —
        # for a `:boolean` target specifically — a non-String value too (Coercion#coerce_boolean also
        # accepts an Integer, per its acceptance table: idempotent true/false, integer 0/1, and
        # FALSY_STRINGS/TRUTHY_STRINGS). Among the coercible targets (Coercion::SUPPORTED) only
        # `:boolean` maps a truthy wire value to a falsey Ruby value — Date/Time/Integer/Float/Symbol all
        # yield a truthy value from a truthy String, and a schema-valid boolean is already true/false
        # (idempotent, no flip). A flip is therefore possible only when the ref's declared type BOTH
        # (a) admits the `:boolean` coercion branch AND (b) admits some OTHER branch whose schema-valid
        # wire values include one coerce_boolean maps to false — i.e. a branch admitting a FALSY_STRINGS
        # member (a JSON `string` branch) or admitting integer `0` (a JSON `integer`/`number` branch,
        # since coerce_boolean checks `value.zero?` before any type-specific parse). A `string`+format
        # branch (Date/Time) still counts: JSON Schema treats `format` as annotation-only by default, so
        # the schema still admits an arbitrary String wire value the coercer can reach. A plain
        # `:boolean`-only property emits no other branch, so no schema-valid input can reach the falsey
        # path — no flip. AND (c) coercion isn't explicitly disabled: explicit `coerce: false` can't
        # flip; an explicit `coerce: true` can; an ABSENT flag with a coercible branch is treated as
        # flippable (the class-level `coerce_input_types` override may enable coercion, and reflection
        # must not resolve per-class config — conservative toward the safe fallback). Declared-config
        # inspection only, side-effect-free (single_type_for is pure).
        FLIPPABLE_JSON_TYPES = %w[string integer number].freeze

        def boolean_coercion_can_flip_truthiness?(ref)
          type_opt = ref.validations[:type]
          return false unless type_opt

          bag = Axn::Internal::ShapeGraph.hash_or_nil(type_opt)
          if nil.equal?(bag)
            klasses = Axn::Internal::ShapeGraph.type_tokens(type_opt)
          else
            klasses = Axn::Internal::ShapeGraph.type_tokens(bag[:klass])
            return false if bag[:coerce] == false
          end

          klasses.include?(:boolean) && klasses.any? { |k| FLIPPABLE_JSON_TYPES.include?(single_type_for(k, for_output: false)[:type]) }
        end

        # Whether the method a Symbol condition names still resolves to the reader Axn generated (not a
        # user method that would evaluate against the settled value instead of the wire value). The
        # generation site is recorded on Contract::GENERATED_READER_SOURCE_PATH; a generated reader —
        # and a boolean predicate alias, which shares the aliased definition's source_location — reports
        # that file, while a user `def` reports the declaring file. Pure introspection, side-effect-free.
        # `respond_to?(:method_defined?)` was standing in for "is this a Module" — a dispatched proxy for a
        # question `Module#===` answers directly, and one the class itself got to answer. Asked properly here,
        # then resolved through the same single method-table lookup `custom_serialization?` uses, so the two
        # sites no longer disagree about how this class of question is asked.
        def framework_generated_reader?(klass, rule_name)
          return false unless Axn::Internal::Identity.kind?(klass, ::Module)

          reader = Axn::Internal::NativeMethods.declared_instance_method(klass, rule_name)
          reader&.source_location&.first == Axn::Core::Contract::GENERATED_READER_SOURCE_PATH
        end

        # Optional (client may omit) iff a usable default exists, or — with no usable default — the
        # validators tolerate a nil/omitted value. Top-level `exposes` requiredness is NOT decided here:
        # `build_output` marks every top-level exposed key required directly (the serializer always emits
        # them). This method reaches a `for_output` config only for a nested shape member, which is
        # serialized from the actual value and so honors its own `optional:`/`allow_nil:`/`default:`.
        def optional_for_schema?(config, subfield: false, satisfiability: false)
          return true if usable_default?(config, subfield:, satisfiability:)

          nil_tolerance_rescues_absence?(config, satisfiability:)
        end

        # Whether this config's nil-tolerance actually rescues an ABSENT value. It does not when the field
        # declares a literal default its own blankness checks reject: axn resolves a declared default for a nil
        # value however it arrived — an omitted key or an explicit null — so the validators see that default,
        # never nil, and the tolerance is never what decides the call. THE single definition, so requiredness
        # and nullability (which the same resolution governs) cannot disagree.
        #
        # Satisfiability mode resolves toward satisfiable and ignores the veto, matching the Proc-default rule:
        # a caller who SUPPLIES a value still has a working contract, so a dead default is no reason to reject
        # the declaration.
        def nil_tolerance_rescues_absence?(config, satisfiability: false)
          return false unless nil_accepted?(config)

          satisfiability || !blank_default_rejected?(config)
        end

        # A default lets the client omit the field (Axn applies it before validation). We judge usability
        # by declared SHAPE only — never by running the field's validators. A Proc default is unknowable at
        # declaration, so the two modes diverge on it (the ONLY semantic delta): strict (schema) mode
        # resolves toward required — the safe direction — while satisfiability mode (the declaration-rejection
        # detector) resolves toward satisfiable, since the Proc DOES apply at runtime and rejection is
        # reserved for provably dead declarations. For a subfield, only a truthy default is applied at runtime
        # (`next unless config.default`), so a falsey subfield default never counts.
        #
        # An empty literal default (`{}`/`""`/`[]`) makes the field omittable only when nothing here would
        # reject the synthesized blank — asked of every check that governs blankness/emptiness
        # (`blank_default_rejected?`), since either can be the one standing between the field and an empty
        # value. (A blank rejected by an author's OWN size constraint — a `length:` floor — is a
        # self-contradictory contract: the same accepted divergence as a non-blank invalid default, where
        # the schema reflects optional though the omitted call fails at runtime.)
        #
        # The emptiness check is limited to literal containers (Hash/Array/String): reflection must stay
        # side-effect-free, and calling `empty?` on an arbitrary default (e.g. an ActiveRecord::Relation or
        # other lazy collection) could issue a query or run user code. A non-literal default is present.
        def usable_default?(config, subfield:, satisfiability: false)
          # `#default` is beyond the documented member contract, so absent and nil are one answer here — both
          # mean "no default to relax the field with", which is what the original respond_to? guard did.
          value = declared_attribute(config, :default)
          return false if value.nil?
          # The governing split (PRO-2889): a Proc default is unknowable at declaration. Strict (schema)
          # mode resolves toward required — the safe direction — while satisfiability mode (the
          # declaration-rejection detector) resolves toward satisfiable: the Proc DOES apply at runtime,
          # and rejection is reserved for provably dead declarations.
          return satisfiability if value.is_a?(Proc)
          return false if blank_default_rejected?(config)

          subfield ? config.applied_default? : true
        end

        # Whether this field's own checks would reject the blank/empty literal value its default supplies —
        # THE single definition of "can this default relax the field", read both when judging the default's
        # usability and when deciding requiredness (an omitted call resolves the default, so a rejected one
        # cannot be omitted). Two checks govern blankness and either can be the only one present, so both are
        # asked, each against the value IT rejects:
        #
        #   * a presence validator rejects a BLANK value (`presence_blank?`) — `presence: true` does,
        #     absent/`presence: false` does not, `presence: { allow_blank: true }` accepts it (`allow_nil`
        #     alone doesn't help a non-nil blank like ""/{}/[]);
        #   * `allow_empty: false`'s own check rejects an EMPTY one (`empty_default?`), which is a different
        #     value set: a whitespace-only String default is blank but not empty, and passes.
        #
        # A Proc default is unknowable at declaration (usable_default? settles it before reaching here) and a
        # non-applied subfield default supplies nothing to reject. Gates are deliberately not consulted, as
        # everywhere else on the input side: a gated check is counted as if it ran.
        def blank_default_rejected?(config)
          return false unless config.respond_to?(:default)

          value = config.default
          return false if value.nil? || value.is_a?(Proc)
          return true if presence_blank?(value) && presence_rejects_blank?(config.validations)

          empty_default?(value) && config.validations.key?(Axn::Internal::FieldConfig::NON_EMPTINESS_KEY)
        end

        # Whether an active `presence:` check here rejects every blank value: one is declared and it is not
        # blank-tolerant. THE single definition, read by the blank-default judgment and by the size-floor
        # emission. A truthy non-Hash entry carries no tolerance, so it rejects blank.
        def presence_rejects_blank?(validations)
          presence = validations[:presence]
          return false unless presence

          opts = effective_entry_options(presence, Axn::Validation::Base.shared_validation_options(validations))
          !opts[:allow_blank]
        end

        # Whether an empty value is rejected by something OTHER than the author's own `length:` — either
        # `allow_empty: false`'s own check or a live presence check (every empty value is blank, so a presence
        # check that rejects blank rejects every empty value). THE question "can an empty value get through
        # here", which decides both the fallback floor of 1 and whether a blank-tolerant `length:` still
        # contributes its floor.
        def empty_value_rejected?(validations)
          return true if validations.key?(Axn::Internal::FieldConfig::NON_EMPTINESS_KEY)

          presence_rejects_blank?(validations)
        end

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
        # `node`'s own representative config (the FIRST non-model config at a merged node) shapes the
        # property itself (type, nullability) — see NodeAnnotation. `node.configs` is EVERY config at the
        # node: it decides both whether to nest at all (node_configs_block_nesting?, the same predicate the
        # drop pass uses, so a route the tree drops from is never re-nested) and, threaded on as parent
        # configs, which `shape:` members might collide with an implicit child.
        def apply_nested_subfields!(prop, node, ann, carried: NO_SHAPE_MEMBERS)
          children = node.children
          return if children.empty?

          node_configs = node.configs
          if node_configs_block_nesting?(node_configs)
            # A non-nestable parent (non-object type, mixed union, or model route) omits its children's
            # SHAPE but NOT their OBLIGATION: field_optional? still forces the parent required when a child
            # requires presence, so its nullability must agree. A nil parent yields every descendant absent
            # (PRO-2857), stranding the required descendant, so strip the parent's `null` admission
            # (reject_null! handles both a type array and an anyOf union) — mirroring the nested-child guard
            # in apply_children!. Predicate: children_require_presence?(children), the same transitive
            # presence test as the nested analog's subtree_requires_presence?(node); required_child?'s
            # shape-synthesis clause is inert for a non-object parent, so the plain presence test is exact
            # and keeps the two sites' reasoning identical.
            reject_null!(prop) if children_require_presence?(children, ann)
            return
          end

          prop.delete(:format)
          prop[:properties] ||= {}
          prop[:required] ||= []

          apply_children!(prop, children, node_configs, ann, carried:)

          prop[:required] = prop[:required].uniq
          # A nil parent yields its subfields as absent, so `null` is admissible exactly when the parent
          # accepts nil and no required nested obligation is stranded (required_child? — which counts a
          # required shape member only when the parent's OWN default materializes it). Read from the
          # precomputed annotation (derive_annotations already applied this same rule to `node`), NOT
          # `prop[:required]`, which also carries shape members that a bare nil parent never triggers.
          prop[:type] = ann[node].nullable ? %w[object null] : "object"
          prop[:required] = nil if prop[:required].empty?
        end

        # Emits one level of children into `prop` (which must already have :properties/:required arrays),
        # recursing into each child's own subtree. `parent_configs` are the configs whose subfields these
        # children are — used to decide, by the same predicate as the drop pass, whether an implicit child
        # may merge into a colliding shape member. They are the top-level/subfield configs at an explicit
        # parent (ALL of them at a merged node, mirroring SubfieldTree), or the shape members an implicit
        # intermediate merged into (so nested members block at depth), or empty for a fresh implicit
        # intermediate that claimed no shape member.
        #
        # A single wire path can be declared via two routes (Node#configs size > 1), and the routes can
        # disagree on kind: a `model:` route emits the generated `<leaf>_id` while a plain route emits the
        # object property. Both are enforced at runtime, so both are emitted, each required per its OWN
        # route's configs — not the node as a whole.
        #
        # ACCEPTED DIVERGENCE (looser-than-runtime, the only such case here): at a merged model+non-model
        # node the non-model route's raw-key object property admits an object value that runtime ALWAYS
        # rejects — the model resolver reads the raw key as the record, and a JSON object is never a model
        # instance, so only absent/null are JSON-satisfiable. Left as-is: sending the object yields a normal,
        # recoverable validation error, and the generated `<leaf>_id` already advertises the working path.
        def apply_children!(prop, children, parent_configs, ann, carried: NO_SHAPE_MEMBERS)
          required_model_ids = []
          model_id_siblings = []
          # Hoisted: every child asks the same question of the same two lists, and this is a hot loop.
          ancestor_configs = carried.empty? ? parent_configs : parent_configs + carried
          # Asked ONCE rather than per child, and it is the difference between this costing nothing and costing
          # a discarded list per child: a contract declaring no `shape:` at this node — the common case by far —
          # has no member to collide with at any key, so the per-key lookup below is skipped outright. Measured
          # at +15% allocations for a shape-free action with 21 subfield children before this guard, ~0 after.
          ancestor_shapes = ancestor_configs.any? { |c| c.validations[:shape] }
          # The ENFORCED list (`ancestor_configs`, every route) is right for nullability, but wrong for "what
          # did the ancestor actually EMIT here" — `apply_structured_schema!` builds a node's property from
          # the REPRESENTATIVE route alone, so a later, non-representative route's shape member is declared
          # but never reaches the document. Restricted the same way `property_representative` restricts
          # everywhere else that has to name the config a property was built FROM (judging every route let a
          # merged node's non-representative EXACT route mask its representative's APPROXIMATE one — the
          # property actually conjoined was the representative's fake hint, not the exact route the
          # unrestricted list also saw). `carried` is already representative-restricted by construction, so
          # it is unaffected here.
          emitted_ancestor_configs = Array(property_representative(parent_configs)) + carried
          children.each do |key, node|
            if node.implicit?
              apply_implicit_node!(prop, key, node, ancestor_configs, ann)
              next
            end

            model_configs = node.configs.select { |c| c.validations[:model] }
            non_model_configs = node.configs.reject { |c| c.validations[:model] }
            # The object property is built from ONE of them; see property_representative, which every layer that
            # has to name that config reads (requiredness annotation, and the size cap's shape charge).

            unless model_configs.empty?
              apply_model_id_child!(prop, key, node, model_configs, children, parent_configs, ann, required_model_ids,
                                    model_id_siblings, carried)
            end

            representative = property_representative(node.configs)
            next unless representative

            members = ancestor_shapes ? shape_members_at(ancestor_configs, key) : NO_SHAPE_MEMBERS
            emitted_members = ancestor_shapes ? shape_members_at(emitted_ancestor_configs, key) : NO_SHAPE_MEMBERS
            apply_explicit_child!(prop, key, node, representative, non_model_configs, members, emitted_members, ann)
            prop[:required] << required_key(key) unless node_optional?(node, ann, non_model_configs)
          end
          # The sibling's OWN entry (a plain child of this same loop) always wins the property outright
          # regardless of visitation order, so `prop[:properties][id_field]` is only guaranteed to hold
          # the sibling's FINAL emission once every key has been visited — merging mid-loop risked
          # reading a not-yet-overwritten model placeholder.
          #
          # Ordered BEFORE the required-null pass just below, not after: merging the declared `id_type:`
          # in uses the SIBLING's OWN `allow_nil:`/`allow_blank:` to decide whether `"null"` joins the
          # merged type (an untyped `company_id, allow_nil: true` sibling beside a REQUIRED model
          # reconstructed `type: ["integer", "null"]`) — but requiredness here is decided by the MODEL,
          # not the sibling, and a required model id can never actually resolve from `nil` at runtime.
          # Merging first and then letting the null pass strip `"null"` from whatever type it finds lets
          # that pass win regardless of which ran the type in; the reverse order let the sibling's own
          # nullability reintroduce a null branch the null pass had already correctly removed, silently
          # admitting a value runtime always rejects for a required id (top-level
          # `apply_model_id_requiredness!` never had this bug — its merge already ran before its own
          # `reject_null!`, being a single sequential method rather than two loops here).
          model_id_siblings.each do |id_field, model_configs, explicit_id|
            merge_model_id_type_into_sibling!(prop[:properties][id_field], model_configs, explicit_id, id_field) if prop[:properties][id_field]
          end
          # A required nested model id can't be null (a null token resolves the model to nil at runtime).
          # Done after the loop so it survives an explicit id subfield declared after the model: subfield.
          required_model_ids.each { |id_field| reject_null!(prop[:properties][id_field]) if prop[:properties][id_field] }
        end

        # Builds and writes the property for one EXPLICIT child. Extracted from `apply_children!`'s loop for the
        # reason `apply_model_id_child!` was: conjoining an ancestor `shape:` member here pushed that single
        # method back over this file's own complexity budget, and another key folded into one already-large loop
        # body is what the earlier extraction was avoiding.
        #
        # An ancestor `shape:` may describe this very key, and `apply_structured_schema!` has already emitted
        # its property into `prop[:properties][key]` (from `build_property`, before `apply_children!` ran at
        # all). Runtime enforces the member and the node alike, so the two are CONJOINED rather than one
        # replacing the other — the merged (object-shaped) members are carried down so a deeper hop sees a
        # member-of-a-member, the same thing `apply_implicit_node!` does at an implicit child. Without this
        # branch advertised a bare object for a position the contract still held to every nested member it
        # declared: the document was looser than the runtime, and the same contract spelled with a dotted `on:`
        # emitted it correctly (PRO-3399).
        #
        # PRO-3405: the conjoin runs whenever `member_prop` exists, not only when `merged_members` came back
        # non-empty. `merged_explicit_members`'s gates (the node must nest; every colliding member must be
        # object-shaped) answer a DIFFERENT question — whether to carry the member down for a deeper hop's
        # member-of-a-member test — and the conjunction itself needs neither: conjoin_shape_member_property
        # already knows how to combine two object-shaped properties (the keyword union above) and how to combine
        # anything else (a sibling `allOf` branch), so a member the node "cannot nest" rides alongside as its
        # own `allOf` branch rather than being dropped.
        #
        # The merge runs BEFORE the descent, not after: the nested pass reads `child_prop[:properties]` to
        # decide whether a generated `<leaf>_id` still needs writing, and `apply_implicit_node!` reads it again
        # to place a blocked merge's obligation on the member's own property. Merging afterwards left both of
        # them looking at a property the member's contribution had not reached yet.
        #
        # `member_configs`/`own_configs` (the collision's two sides, as ROUTE lists — `emitted_members` and
        # `[representative]` here) let `conjoin_shape_member_property` judge each side's DECLARED type before
        # trusting its emitted property as an exact constraint worth conjoining — see that method for the two
        # separate reasons a side can be untrustworthy (a transform, or an unknown class) and how each is
        # handled, and for how the same judgment recurses through `merge_emitted_maps` for a name colliding one
        # level down. `emitted_members`, not `members`: at a merged node `apply_structured_schema!` only ever
        # builds `member_prop` from the REPRESENTATIVE route, so approximateness is judged on that route alone —
        # `members` (every route) stays for nullability just below, an ENFORCED question the representative
        # restriction does not apply to.
        #
        # `null` survives only when every non-model route tolerates nil (runtime enforces all of them; the
        # property itself is built from the first non-model config), EVERY colliding shape member tolerates nil
        # too — merged or not, since a member this node declined to merge is still enforced, and a non-nullable
        # one forbids nil however permissive the node's own declaration is — and no required descendant is
        # stranded, a nil node yielding every descendant absent (PRO-2857), so a required one below it forbids
        # nil even for a non-object node whose subfield shape isn't nested here. The members are read via
        # nil_allowed?, the predicate `apply_implicit_node!` reads them with, never sniffed off the emitted
        # property: an untyped nil-tolerant member emits no `type`, leaving no null branch to find.
        def apply_explicit_child!(prop, key, node, representative, non_model_configs, members, emitted_members, ann)
          merged_members = merged_explicit_members(node, members)
          child_prop = build_property(representative, subfield: true)
          member_prop = prop[:properties][key]
          child_prop = conjoin_shape_member_property(member_prop, child_prop, member_configs: emitted_members, own_configs: [representative]) if member_prop
          apply_nested_subfields!(child_prop, node, ann, carried: merged_members)
          # A route carrying `preprocess:` is NOT exempted from its own `nil_allowed?` here, though the Proc
          # does run before presence is judged and so might turn a wire `nil` into something non-nil
          # (`preprocess: ->(_) { "x" }` on an otherwise-required node does exactly that). The exemption
          # cannot be scoped safely: reflection has no way to tell that CONSTANT-preprocess case apart from
          # an ordinary IDENTITY (or any other nil-preserving) `preprocess: ->(v) { v }`, where the Proc does
          # NOT rescue nil and the required check correctly rejects it at runtime — `preprocess:` is an
          # opaque Proc, and reflection must not execute it to find out which. Of the two directions that
          # ambiguity forces a choice between — an unsatisfiable node for the constant-preprocess case, or a
          # schema that ACCEPTS a wire `nil` the far more common pass-through case REJECTS — the latter is
          # the one direction reflection may never take (`schema_wire_audit_spec`'s own hard invariant). So
          # the constant-preprocess case is left as a known, unfixable residual: the same "cannot execute
          # user code" limit already accepted for a transforming side's constraints generally.
          null_ok = non_model_configs.all? { |c| nil_allowed?(c) } &&
                    members.all? { |m| nil_allowed?(m) } &&
                    !subtree_requires_presence?(node, ann)
          reject_null!(child_prop) unless null_ok
          prop[:properties][key] = child_prop.compact
        end

        # The nested twin of `build_input`'s own model branch — its own method rather than another key
        # folded into `apply_children!`'s single already-large loop body, which the conflict/reconciliation
        # logic here had pushed past this file's complexity budget. Mutates `prop`/`required_model_ids` in
        # place, exactly as the inlined code it replaces did.
        def apply_model_id_child!(prop, key, node, model_configs, children, parent_configs, ann, required_model_ids,
                                  model_id_siblings, carried)
          # The id key derives from the LEAF wire segment (a dotted model name digs `<leaf>_id` off
          # the same nested parent at runtime). A user may declare an explicit NON-model nested
          # `<field>_id` subfield — its own entry in `children`, keyed by that same id, visited
          # independently of this one — and it always wins the property, so `model_id_property` is
          # skipped rather than built and discarded: for an ActiveRecord model that call dispatches
          # `primary_key`/`type_for_attribute` (PRO-3384), and there is no reason to pay that (or the
          # DB/schema access behind it) for a result an explicit sibling is about to replace anyway.
          #
          # Gated on `explicit_id`, not merely `sibling_node`'s presence: a sibling node whose OWN
          # field is itself a `model:` (e.g. `company_id, model: ...` beside `company, model: ...`)
          # never writes to THIS key at all — it emits its own generated id one level deeper
          # (`company_id_id`) — so treating its mere existence as "something will write here" skipped
          # the only thing that would have.
          id_field = Internal::FieldConfig.model_id_key(key)
          sibling_node = children[id_field]
          explicit_id = sibling_node&.configs&.find { |c| !c.validations[:model] }
          # A `shape:` member on the PARENT (`parent_configs`) can ALSO claim `id_field` by name — a
          # wire-property source `apply_structured_schema!` merges into `prop[:properties]` BEFORE this
          # method ever runs (called from `build_property`, ahead of `apply_nested_subfields!`), entirely
          # outside the subfield tree `children` searches: `field :company_id, type: String` inside a
          # `do...end` block beside `expects :company, on: ..., model: { id_type: Integer }` left
          # `explicit_id` nil (no SUBFIELD sibling exists), so the conflict check never ran, and the shape
          # member's `||=`-preserved string property silently discarded the declared integer id_type.
          #
          # Restricted to the REPRESENTATIVE config's OWN shape, not every route at a merged parent node: at
          # a merged node `apply_structured_schema!` (building the parent's OWN property, via
          # `property_representative`) only ever merges the FIRST non-model route's shape — a member declared
          # on a LATER, non-representative route never reaches `prop[:properties]` at all. Searching every
          # `parent_configs` (what `shape_members_at` alone does — correct for `apply_implicit_node!`'s use,
          # an intermediate node with no representative of its own) found a member that was never actually
          # emitted, so the check believed something had already claimed the key while NOTHING had: the
          # model's own property was skipped, but nothing replaced it, leaving `id_field` `required` with no
          # matching entry in `properties` at all — worse than losing the type, JSON Schema then admits any
          # value there. The representative's own shape PLUS the members carried from a shallower hop — the
          # ancestor's shape reaches this node's property too (PRO-3399), so a carried `field :company_id,
          # type: String` claims the key exactly as one on the node's own route does, and leaving the carry
          # out would discard the declared `id_type:` one level up.
          representative = property_representative(parent_configs)
          explicit_id ||= emitted_shape_member_at(prop, representative, carried, id_field)
          # `model_configs`, every route at THIS merged node — not just `.first`: two `model:`
          # routes reaching the same wire node may each carry their own `id_type:`/`klass:`, and
          # reading only one silently dropped the other's claim.
          reject_model_id_type_conflict!(model_configs, explicit_id, id_field)
          if explicit_id
            # Deferred rather than merged here directly (see the post-loop pass in `apply_children!`):
            # this sibling's OWN entry in `children` hasn't necessarily been visited yet, so
            # `prop[:properties][id_field]` isn't guaranteed to hold its FINAL emission until every key
            # in this loop has run.
            model_id_siblings << [id_field, model_configs, explicit_id]
          elsif !prop[:properties].key?(id_field)
            id_type = reconciled_model_id_type_token(model_configs, id_field)
            _, subprop = model_id_property(model_configs.first, id_type)
            prop[:properties][id_field] ||= subprop
          end
          return if node_optional?(node, ann, model_configs)

          prop[:required] << id_field.to_s
          required_model_ids << id_field
        end

        # The `shape:` member claiming `id_field`, but ONLY where that member's property was actually EMITTED
        # — asked of `prop[:properties]` itself rather than inferred from which route declared it.
        #
        # Declaring a member and emitting one are not the same thing, and the gap is what this guards. At a
        # merged node `apply_structured_schema!` builds the property from the REPRESENTATIVE route alone, and
        # a merged ancestor member is conjoined only where the ancestor emitted one to conjoin with — so a
        # member on a later route is found by `shape_members_at` while nothing of it is in the document.
        # Treating such a member as the sibling that claims the key skipped the generated id property, and the
        # deferred `merge_model_id_type_into_sibling!` pass then found nothing at that key to merge into:
        # `id_field` came out `required` with no entry in `properties` at all, which JSON Schema reads as "any
        # value permitted" — looser than emitting nothing, and the same failure the route restriction here was
        # originally written to prevent.
        #
        # A `prop[:properties]` question rather than a route question, because it is the one the emitter can
        # actually answer at this point: a shape member's property is written by `build_property` (and the
        # ancestor merge) strictly before `apply_children!` runs, while a subfield SIBLING at the same key is
        # found through `children` above and has already set `explicit_id` by the time this is reached.
        def emitted_shape_member_at(prop, representative, carried, id_field)
          return nil unless prop[:properties].key?(id_field)

          sources = carried.empty? ? Array(representative) : Array(representative) + carried
          shape_members_at(sources, id_field).first
        end

        # An implicit node (a dotted-path intermediate with no declaration of its own) emits a bare object
        # property whose only content is its children. When a `shape:` member of any `parent_configs`
        # claims the key, merge into it only if EVERY colliding member is `nestable_as_object?` — the SAME
        # predicate on the SAME member configs that blocking_ancestor? uses (it scans ALL of
        # the node's configs), so emission and the drop pass agree: a non-nestable member (a scalar, or a
        # mixed union like `type: [Hash, Array]`) on ANY route blocks and its deep configs stay in
        # dropped_deep_subfields rather than forcing a self-contradictory property. The block is judged from
        # the member configs directly, NOT from a pre-seeded property: at a merged node the object property
        # is built from the first non-model config, so a scalar member declared on a LATER config seeds
        # nothing to collide with, yet must still block (matching SubfieldTree, which scans every config).
        #
        # A blocked merge omits the deep SHAPE but not the deep OBLIGATION: runtime validates the dropped
        # subfields regardless of representability, so when the dropped subtree requires presence
        # (subtree_requires_presence? — the same predicate used everywhere) the colliding member's own
        # property still inherits that obligation. The member is forced required and its `null` admission
        # stripped (reject_null! handles both `type:` arrays and `anyOf` unions) — because a nil/absent
        # member strands the required descendant (PRO-2857). Nothing else about the member is touched (no
        # forced object type, no properties — its shape stays dropped). An all-optional dropped subtree
        # strands nothing, so the member keeps its declared flags (runtime accepts omission/nil there).
        def apply_implicit_node!(prop, key, node, parent_configs, ann)
          members = shape_members_at(parent_configs, key)
          if members.any? { |member| !nestable_as_object?(member) }
            if subtree_requires_presence?(node, ann)
              prop[:required] << required_key(key)
              reject_null!(prop[:properties][key]) if prop[:properties][key]
            end
            return
          end

          # Carry the (all-nestable) colliding members as the parent configs for this node's own children,
          # so a deeper implicit hop tests their NESTED shape members (a member-of-a-member). Same members
          # the drop pass carries, so the two agree at depth.
          existing = prop[:properties][key]
          target = existing || {}
          target.delete(:format)
          target[:properties] ||= {}
          target[:required] ||= []
          apply_children!(target, node.children, members, ann)
          target[:required] = target[:required].uniq
          # A fresh implicit intermediate is nullable exactly when nothing beneath requires presence (a nil
          # parent digs every descendant to nil, PRO-2857) — the precomputed annotation's bare nullable (an
          # implicit node has no config of its own to collide against). A shape-member collision additionally
          # caps it by the members' OWN nil-tolerance — nullable only when EVERY colliding member tolerates
          # nil (runtime enforces all routes), read from each config via nil_allowed? (the same predicate the
          # parent nesting uses) never sniffed off the emitted property: an untyped nil-tolerant member emits
          # no `type`, so a null branch is invisible there and property-sniffing would force it non-nullable
          # though runtime accepts a nil member. With no colliding member, an existing merge target (e.g. a
          # Data placeholder property with no shape member) falls back to non-nullable (stricter than
          # runtime), while a genuinely fresh node (no property, no member) follows its subtree.
          nullable = ann[node].nullable &&
                     (members.any? ? members.all? { |m| nil_allowed?(m) } : existing.nil?)
          target[:type] = nullable ? %w[object null] : "object"
          target[:required] = nil if target[:required].empty?
          prop[:properties][key] = target.compact
          prop[:required] << required_key(key) if ann[node].required
        end

        # An ancestor `shape:` member's already-emitted property, conjoined with the one this node's OWN
        # declaration built. Both are enforced at runtime and JSON Schema keywords at one node are conjoined
        # too, so keeping both sides' keywords IS the runtime conjunction — the node's own stand (it is the
        # more specific declaration at the position) and the member contributes everything the node does not
        # state: the object contents this branch used to drop, and with them a map's `additionalProperties`
        # and `propertyNames`, which a contents-only merge would still have lost.
        #
        # Taken from the emitted property rather than rebuilt from the member's declaration, which is what
        # makes "what the member contributes" one answer rather than two: a `Data` member's INFERRED
        # properties (shape_property_plan's base_properties) and a map's contents are not in its `members:`
        # list at all, and rebuilding would also restart guard_contents_descent's depth/cycle budget from
        # zero for a graph this walk has already descended.
        #
        # Three keys are not a plain overlay. `properties` and `required` are unioned, since each side names
        # contents the other does not — and a NAME both sides declare (PRO-3405) is not a collision to
        # resolve by precedence either: each of the two schemas at that child key is itself conjoined,
        # recursively, via merge_emitted_maps's own use of conjoin_shape_member_property, rather than one
        # replacing the other. And a size bound declared on BOTH sides takes the STRICTER of the two: a
        # value satisfying only the looser one is rejected at runtime by the other, and that is the one
        # direction a plain overlay emits too loosely.
        #
        # Taken from what is AT the key rather than from the member config, which is also why the caller guards
        # on its presence: at a merged node `apply_structured_schema!` only ever emits the REPRESENTATIVE
        # route's shape, so a member declared on a later route is found by shape_members_at and yet has nothing
        # emitted to conjoin with. Such a member still caps nullability and still blocks at depth — it simply
        # contributes no contents here, exactly as at an implicit child (see apply_implicit_node!).
        #
        # `propertyNames` is deliberately NOT re-exempted (exempt_shaped_keys_from_property_names runs inside
        # `apply_structured_schema!`, before this): the runtime's own exemption is derived per declaration
        # from THAT declaration's `shape:` (Core::Contract#_derive_shaped_keys!), so a member carried from an
        # ancestor exempts no key at this node's map validator either. Re-running it would admit a key the
        # runtime rejects — measured, both spellings reject one.
        def merge_shape_member_property(member_prop, own_prop, member_configs: [], own_configs: [])
          merged = member_prop.merge(own_prop)
          # `:type` is RECONCILED, not left to the shallow merge's "second side wins" default — a nullable
          # `["object", "null"]` on either side must not silently overwrite the OTHER side's non-nullable
          # `"object"`: an ancestor `deep` Hash member that REQUIRES `a` (non-nullable) beside a colliding
          # node's OWN `deep` declared `allow_nil: true` (nullable) let `own_prop[:type]` — merged in
          # SECOND — win outright, so the merged schema admitted `deep: null` even though the ancestor's
          # own (unconditional, raw-value) check rejects null there. Both routes are enforced, so null
          # survives only when BOTH tolerate it. This function also runs for a side that is simply EMPTY
          # (own_prop.empty?/member_prop.empty? in conjoin_shape_member_property), not only a genuine
          # object-vs-object merge, so the reconciliation must not hardcode "object" — it keeps whichever
          # REAL base type either side names.
          merged[:type] = merge_emitted_type(member_prop[:type], own_prop[:type]) if member_prop[:type] || own_prop[:type]
          # `:format` describes a SCALAR "string"-typed value — never an object — so it is dropped only
          # when the RECONCILED type above actually ended up "object" (where it would be a meaningless
          # keyword sitting beside `properties`), not unconditionally: this function also runs for a side
          # that is simply EMPTY (see the type comment above), not only a genuine object-vs-object merge,
          # and an unconditional delete here discarded a SCALAR member's own real format in that case too
          # — a `type: :uuid` shape member beside an Integer node with an opaque `preprocess: ->(_) { 1 }`
          # (stripped down to `{}` by pass 1) is satisfiable only for a valid UUID string at runtime, but
          # the merged property dropped `format: "uuid"` entirely, accepting any non-empty string. The
          # plain `merge` above already carries over whichever side's `:format` survives (at most one
          # non-empty side ever has one, since a `:format` and `:properties` are mutually exclusive on any
          # one side) — deleting it here just needs to be conditional, not removed.
          merged.delete(:format) if object_property?(merged)
          # Reassigned only when at least one side actually HAS the key — both sides bare (e.g. two
          # colliding `type: Hash` declarations with no children on either) means merge_emitted_maps/
          # merge_emitted_required return nil (nothing to merge), and writing that nil through would leave
          # an explicit `properties: nil`/`required: nil` in the document: JSON Schema requires `properties`
          # to be an object and `required` to be an array, so a null-valued keyword is an invalid document,
          # not merely a permissive one (the OUTER `.compact` calls this property eventually passes through
          # are all shallow, so a nil written INTO this property here survives every one of them).
          if member_prop[:properties] || own_prop[:properties]
            merged[:properties] = merge_emitted_maps(member_prop[:properties], own_prop[:properties], member_configs:, own_configs:)
          end
          merged[:required] = merge_emitted_required(member_prop[:required], own_prop[:required]) if member_prop[:required] || own_prop[:required]
          merged[:minProperties] = [member_prop[:minProperties], own_prop[:minProperties]].compact.max if merged[:minProperties]
          merged[:maxProperties] = [member_prop[:maxProperties], own_prop[:maxProperties]].compact.min if merged[:maxProperties]
          # A map's `values:`/`keys:` axes (`additionalProperties`/`propertyNames`) are their OWN nested
          # schema, both enforced when both sides declare one — the shallow `merge` above lets the SECOND
          # side simply overwrite the first, the same bug `:properties`/`:type` already needed reconciling:
          # an ancestor `deep` Hash member whose values axis requires `> 0` beside a colliding node's own
          # `deep` values axis requiring `< 10` emitted only the `< 10` constraint, so `deep: { x: -1 }`
          # passed the schema though the ancestor's own (unconditional) validator rejects it. Conjoined via
          # the SAME `conjoin_shape_member_property` recursion used everywhere else two schemas at one
          # position both apply — with the AXIS's own klass token(s) threaded through (not the outer
          # field's), because an approximate axis (`values: Object`) needs the SAME
          # `unknown_class_approximate?` stripping an approximate FIELD gets: an ancestor axis with `klass:
          # Object` beside a colliding node's axis with `klass: Hash` initially called this conjunction
          # with no axis configs at all, so the emitted `{type: "string"}` HINT (`single_type_for`'s
          # permissive Object fallback) was treated as an EXACT, competing type assertion rather than the
          # approximation it is — conjoined via `allOf` with the real `{type: "object"}` schema into a node
          # nothing satisfies (a value can never be both a string and an object), though `{ x: {} }` passes
          # both runtime axis validators. An axis never carries `coerce:`/`preprocess:` at all (refused at
          # declaration — "of: does not support coerce:"/"preprocess:"), so `axis_config_view` only ever
          # needs to expose the axis's declared klass token, never a transform.
          if member_prop[:additionalProperties] || own_prop[:additionalProperties]
            merged[:additionalProperties] = merge_emitted_nested_schema(
              member_prop[:additionalProperties], own_prop[:additionalProperties],
              axis_configs_for(member_configs, :values), axis_configs_for(own_configs, :values)
            )
          end
          if member_prop[:propertyNames] || own_prop[:propertyNames]
            merged[:propertyNames] = merge_emitted_nested_schema(
              member_prop[:propertyNames], own_prop[:propertyNames],
              axis_configs_for(member_configs, :keys), axis_configs_for(own_configs, :keys)
            )
          end
          merged
        end

        # A nested map axis schema present on only one side is carried through as-is; present on both, it
        # is conjoined the same way any other two-declarations-at-one-position collision is (see
        # conjoin_shape_member_property) rather than letting either side simply win.
        def merge_emitted_nested_schema(member_schema, own_schema, member_axis_configs = [], own_axis_configs = [])
          return own_schema if member_schema.nil?
          return member_schema if own_schema.nil?

          conjoin_shape_member_property(member_schema, own_schema, member_configs: member_axis_configs, own_configs: own_axis_configs)
        end

        # A minimal stand-in for a field config, exposing only what `unknown_class_approximate?` reads
        # (`.validations`) — enough to reuse that function UNCHANGED for an axis bag, which is never
        # itself an `Internal::FieldConfig`. Deliberately has NO `preprocess` method at all, so
        # `respond_to?(:preprocess)` reads false exactly as a shape member's does — `transforms_wire_
        # value?`'s own doc explains why that must be the answer here: an axis bag can NEVER declare
        # `coerce:`/`preprocess:` (both refused at declaration — "of: does not support coerce:"/
        # "preprocess:"), so unlike an ordinary field's bare-coercible-klass case (ambient
        # `coerce_input_types` MIGHT still coerce it, so reflection conservatively assumes it could), an
        # axis's klass being coercible IN PRINCIPLE is never evidence it actually transforms here — the
        # axis mechanism itself has no coercion seam at all, ambient setting or not. Defining `preprocess`
        # to return nil would have made `respond_to?(:preprocess)` true, wrongly reusing the
        # ambient-uncertainty conservatism a coercible axis klass (e.g. `values: Integer`) does not earn.
        AxisConfigView = Struct.new(:validations) do
          # So a view can be PROJECTED like any other config (`gate_resolved_sides`): an axis's own validators
          # carry nested gates, and reflecting those by what always runs needs the same re-emission.
          def with(validations:) = self.class.new(validations)
        end
        private_constant :AxisConfigView

        # The `axis_key` (`:values`/`:keys`) axis's own declared klass token(s), one view per outer config
        # that declares an `of:` bag at all — empty for a config with none, which `unknown_class_
        # approximate?`/`transforms_wire_value?` both already read as "nothing to distrust here."
        def axis_configs_for(configs, axis_key)
          configs.filter_map do |config|
            bag = Axn::Internal::ShapeGraph.hash_or_nil(config.validations[:of])
            next nil if bag.nil?

            raw = bag[axis_key]
            axis = Axn::Internal::ShapeGraph.hash_or_nil(raw)
            token = axis ? axis[:klass] : raw
            nested_of = axis && axis[:of]
            nested_shape = axis && axis[:shape]
            # A CLASSLESS axis (legally `klass:`-free — e.g. `values: { shape: { members: [...] } }`,
            # constraining only via its named members) still has a `:shape`/`:of` worth keeping even
            # though it names no token at all: skipping the whole view whenever `token.nil?` — that gate
            # — discarded that classless axis's `shape:` too, so when two colliding axes respectively
            # described a child `a` as `Object` and `Hash`, the recursive `shape_members_at` lookup
            # found NOTHING for either side, and the `Object` child's approximate hint was conjoined as
            # exact all over again. Only a TRULY empty axis (no token, no `:of`, no `:shape` — nothing
            # here distrusts or recurses into anything) is skipped now.
            next nil if token.nil? && nested_of.nil? && nested_shape.nil?

            # `:of` and `:shape` are carried forward alongside the synthesized `:type`, not just the axis's
            # own `:klass` — needed so a DEEPER collision inside the axis (another map bag nested in `:of`,
            # or named members declared via the axis's own `shape:`) can still be reconciled: outer
            # `klass: Hash` axes whose NESTED values are respectively `Object` and `Hash` lost that inner
            # structure here, since only the outer klass survived into the view — so
            # when `merge_shape_member_property` recursed one level deeper for the INNER axis,
            # `axis_configs_for` found no `:of` to read at all, and the inner `Object` axis's approximate
            # hint was conjoined as exact all over again. `shape_members_at` reads
            # `config.validations.dig(:shape, :members)` the same way for a NAMED child inside the axis's
            # own `shape:` block — two `values: { klass: Hash, shape: { … } }` axes colliding needs the
            # SAME per-child config lookup `merge_emitted_maps` already does for an ordinary object, and
            # without `:shape` on the view it found nothing, so a child typed `Object` in one axis's shape
            # collided with `Hash` in the other's as though BOTH were exact. Threading both through is what
            # lets every recursive lookup this file already has (`shape_members_at`, `axis_configs_for`
            # itself) keep working exactly as it does for an ordinary field's configs.
            # The axis's OWN validators come across too, derived by subtracting the three bag keys this
            # view maps itself rather than by naming Core's positional-validator list — a view that carried
            # only the klass hid an axis's `inclusion:`/bounds AND the nested gates on them, so a
            # conditional axis constraint was conjoined as though it always applied.
            validations = axis ? axis.except(:klass, :of, :shape) : {}
            validations[:type] = token if token
            validations[:of] = nested_of if nested_of
            validations[:shape] = nested_shape if nested_shape
            AxisConfigView.new(validations)
          end
        end

        # The reconciled `:type` for a merged property — nullable only when BOTH sides admit null, since
        # either side rejecting it (its own unconditional check, at runtime) forbids it here regardless of
        # what the other declares. `nil` on one side (that side is simply absent, not "typeless") returns
        # the OTHER side's type untouched, so this is safe to call whenever EITHER side has a `:type` at
        # all, not only when both are the SAME base type.
        def merge_emitted_type(member_type, own_type)
          return own_type if member_type.nil?
          return member_type if own_type.nil?

          base = (Array(member_type) + Array(own_type)).reject { |t| t == "null" }.uniq
          base = base.first if base.size == 1
          nullable = [member_type, own_type].all? { |type| Array(type).include?("null") }
          nullable ? Array(base) + ["null"] : base
        end

        # Two emitted properties at ONE wire position, both enforced at runtime (PRO-3405): a shape member's
        # own emission and the node's — or, recursively, two child properties a name collided on inside
        # merge_emitted_maps. Neither may simply win: a name both sides declare means the runtime enforces
        # both, so the document must say so too.
        #
        # Where both sides are already object-shaped, their keywords share a surface worth unioning
        # (`properties`/`required`/the size bounds) — that IS merge_shape_member_property, unchanged since
        # PRO-3399. Everywhere else — a scalar collides with a scalar, a union with an object, anything that
        # doesn't share that surface — there is no keyword-by-keyword reading that means the same thing for
        # every pair (the approach PRO-2877's pulled detectors already rejected: it invents an
        # intersection-semantics per keyword, and every keyword nobody thought of stays silently wrong). JSON
        # Schema already has the honest, keyword-agnostic spelling for "both of these apply" — `allOf`, free
        # at a property (the same trick write_pattern! uses to compose two patterns) — so the member rides
        # alongside as a sibling branch instead.
        #
        # `own_prop` being genuinely EMPTY (an explicit node with no type or shape of its own — the member is
        # then the whole story) also routes through merge_shape_member_property rather than a bare `.dup`: a
        # shallow dup would share `member_prop[:properties]` — the SAME nested Hash `apply_nested_subfields!`
        # is about to add the node's own children into — mutating the ancestor's already-emitted property in
        # place. merge_shape_member_property never has that problem (merge_emitted_maps dups the properties
        # map whenever one side is absent), so routing every combination through the one function is what
        # keeps this conjoin from being the aliasing bug AGENTS.md already names.
        #
        # `member_configs`/`own_configs` are the declarations each emitted property came from — a LIST,
        # mirroring `shape_members_at`'s own return shape, since a merged node can carry more than one route
        # to the same name. Empty (or omitted) on a side whose config is unknown at the call site, which
        # reads as "trustworthy" (the conservative, pre-existing answer) rather than crashing.
        #
        # A side is CONJOINABLE only where its emitted keywords describe the same value everything else at
        # this position reads, and two separate things can make them not — kept apart because the honest
        # response differs:
        #
        # TRANSFORM (`transforms_wire_value?`: `preprocess:`, or a coercible declared type with no explicit
        # `coerce: false`). EVERY keyword on that side judges the transform's output, while the wire carries
        # its input. `allOf` asserts every branch of ONE instance, so conjoining such a side states a
        # contract that never runs — and translating it back means inverting an arbitrary Proc, which
        # reflection cannot do and must not try. So the side stands down whole: the other one is emitted
        # alone and what this one still enforces is reported as a residue, in the property's `description`
        # and to the once-per-class warning. That is looser than the runtime here — the direction reflection
        # otherwise may not take — and it is the deliberate trade: a named, reported, bounded gap in place of
        # an unbounded approximation no guard could trust anyway.
        #
        # UNKNOWN CLASS (`unknown_class_approximate?`: an `Object`/`Enumerable`-style token, for which
        # `single_type_for` emits a permissive `{type: "string"}` hint rather than a claim). Nothing here
        # transforms anything, so every OTHER keyword still describes the same raw value — only the
        # fabricated type is untrustworthy, and only against a side making a real competing claim. So this
        # drops `type`/`anyOf` and conjoins the rest, rather than discarding constraints that are exact.
        # Two sides that are both unknown-class hints fall back to the same permissive shape and cannot
        # contradict each other, so neither is stripped.
        def conjoin_shape_member_property(member_prop, own_prop, member_configs: [], own_configs: [])
          sides, residues = gate_resolved_sides([[member_prop, member_configs], [own_prop, own_configs]])
          prop, carried = left_of(sides.reduce { |left, right| combine_two(left, right) })
          (carried + residues).reduce(prop) { |acc, r| record_residue(acc, r.summary, kind: r.kind) }
        end

        # Every side to be combined, with each CONDITIONAL one replaced by the always-run property of each
        # config that contributed to it — and the residues naming what those conditions still enforce.
        #
        # A conditional side expands to one side PER config rather than being collapsed here, which is the
        # whole point of the shape: the combination then runs through `combine_two` exactly as any other
        # pair does, so a fabricated type is reconciled, an empty side is merged rather than branched, and a
        # transform stands down — none of it reimplemented. Combining projections with bespoke logic beside
        # the real conjunction is what diverged from it three times.
        def gate_resolved_sides(sides)
          residues = []
          expanded = sides.flat_map do |prop, configs|
            next [[prop, configs]] if configs.none? { |config| conditional_checks?(config) }

            projections = configs.map { |config| [config, build_property(config, subfield: true)] }
                                 .map { |config, full| [config, projected_property(config, full), full] }
            residues.concat(gating_residues(projections))
            projections.map { |config, projected, _full| [carry_metadata(projected, prop), [config]] }
          end
          [expanded, residues]
        end

        # Two sides combined: the one place that decides what "both of these apply" emits, whatever the
        # sides came from.
        def combine_two((left_prop, left_configs), (right_prop, right_configs))
          left_transforms = transforms_wire_value?(left_configs)
          right_transforms = transforms_wire_value?(right_configs)

          if left_transforms ^ right_transforms
            kept, dropped = left_transforms ? [right_prop, left_prop] : [left_prop, right_prop]
            return [stand_down_from(kept, dropped, TRANSFORM_RESIDUE), left_configs + right_configs]
          end

          left_unknown = unknown_class_approximate?(left_configs)
          right_unknown = unknown_class_approximate?(right_configs)
          left_prop = drop_fabricated_type(left_prop) if left_unknown && !right_unknown && !asserts_nothing?(right_prop)
          right_prop = drop_fabricated_type(right_prop) if right_unknown && !left_unknown && !asserts_nothing?(left_prop)

          # Residues belong to the POSITION, not to whichever branch happened to raise them: a reader looks
          # at the property, and a sentence buried in one `allOf` entry reads as a note about that entry.
          # So they come off both sides here and are re-recorded on the finished node.
          carried = residues_on(left_prop) + residues_on(right_prop)
          left_prop = left_prop.except(RESIDUE_KEY)
          right_prop = right_prop.except(RESIDUE_KEY)

          # A side stripped down to nothing is not a branch either — an `allOf` entry asserting no keyword
          # constrains nothing — so it routes through the merge, which already handles an absent side.
          combined =
            if asserts_nothing?(left_prop) || asserts_nothing?(right_prop) ||
               (object_property?(left_prop) && object_property?(right_prop))
              merge_shape_member_property(left_prop, right_prop, member_configs: left_configs, own_configs: right_configs)
            else
              right_prop.merge(allOf: Array(right_prop[:allOf]) + [left_prop])
            end

          [carried.reduce(combined) { |acc, r| record_residue(acc, r.summary, kind: r.kind) }, left_configs + right_configs]
        end

        # The finished property and the residues still riding on it.
        def left_of((prop, _configs))
          [prop.except(RESIDUE_KEY), residues_on(prop)]
        end

        # One config's property as emitted from the checks that run on every call.
        #
        # A gated `type:` is the awkward case, because a type is not only a claim — it is also what gives
        # every OTHER validator a JSON spelling. Strip it from the bag and an UNCONDITIONAL `length:` loses
        # its `minItems`, an unconditional `presence:` loses its floor, and the position comes back
        # admitting values the runtime rejects on every call.
        #
        # So the type stays in the bag for EMISSION and is then subtracted from the result — and subtracted
        # by rebuilding from the type alone (`type_only`) rather than by naming keywords, because which
        # keywords a type asserts for itself is exactly the enumeration that would go stale. A `TrueClass`
        # asserts `enum: [true]`, a `:uuid` asserts `format`; those are the gated claim and must not
        # survive. What `length:`/`presence:` contributed THROUGH the type is not in that set and does.
        def projected_property(config, full)
          ungated = ungated_validations(config)
          type = config.validations[:type]
          return restore_blank_floor(build_property(config.with(validations: ungated), subfield: true), ungated, full) if
            type.nil? || ungated.key?(:type)

          typeless = build_property(config.with(validations: ungated), subfield: true)
          emitted = build_property(config.with(validations: ungated.merge(type:)), subfield: true)
          type_only = build_property(config.with(validations: { type: }), subfield: true)

          # Three builds, because two sources can write ONE keyword and subtracting by key loses both: a
          # gated `TrueClass` and an unconditional `inclusion:` each emit `enum`, and removing the type's
          # `enum` removed the inclusion's with it. So the always-run property is what the other validators
          # say WITHOUT the type (`typeless`), plus the keywords they could only spell THROUGH it — which is
          # every key the type does not claim for itself.
          restore_blank_floor(typeless.merge(emitted.reject { |key, _| type_only.key?(key) }), ungated, full)
        end

        def ungated_validations(config)
          gates = declaration_gates(config)
          config.validations.reject do |key, opt|
            next false if Internal::FieldConfig::CONDITIONAL_GATE_KEYS.include?(key)

            Axn::Validation::Base.entry_effectively_gated?(opt, gates)
          end
        end

        # What GATING removed, and nothing else. Rendering the whole pre-projection property instead named
        # a position's unconditional constraints inside prose saying they apply only when a condition opens
        # — contradictory guidance, and the residue exists to give a reader something it can act on. So the
        # summary is the difference between what each config emits and what its always-run subset emits.
        #
        # One residue PER config rather than one merged hash across them: two routes at a position can gate
        # the SAME keyword, and merging their fragments by key silently kept only the last — the report then
        # enumerated one conditional constraint and omitted the other, which is worse than reporting neither
        # since a caller rejected by the omitted one has been told the list was complete.
        def gating_residues(projections)
          projections.filter_map do |_config, projected, full|
            removed = full.except(*RESIDUE_UNGATEABLE_KEYS).reject { |key, value| projected[key] == value }
            next nil if removed.empty?

            Residue.new(summary: "#{GATED_RESIDUE} (#{render_constraint(removed)})", kind: :conditional)
          end
        end

        def conditional_checks?(config)
          return false unless config.respond_to?(:validations)

          gates = declaration_gates(config)
          config.validations.any? do |key, opt|
            next false if Internal::FieldConfig::CONDITIONAL_GATE_KEYS.include?(key)

            Axn::Validation::Base.entry_effectively_gated?(opt, gates)
          end
        end

        def declaration_gates(config) = config.validations.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)

        # A projection keeps the `description` and pending residues of the property it replaces: those
        # describe the POSITION, and nothing about them is conditional.
        def carry_metadata(projected, original)
          projected = projected.merge(RESIDUE_KEY => residues_on(original)) if residues_on(original).any?
          description = original[:description]
          description.nil? ? projected : projected.merge(description:)
        end

        # The one thing a projection can lose that is NOT conditional. `minLength`/`minItems`/`minProperties`
        # are derived from the TYPE, so when the gated entry is the `type:` itself, stripping it also strips
        # the JSON spelling of an UNGATED `presence:` — the node comes back admitting `""`/`[]`/`{}` on every
        # call, which the runtime rejects on every call. That is this file's own rule that a missing bound is
        # a missing EMISSION first, so the floor is restated as a value-level one, the only spelling left
        # once no type survives to hang a size keyword on.
        def restore_blank_floor(projected, ungated, original)
          return projected unless projected[:type].nil? && projected[:anyOf].nil?
          return projected if original[:type].nil? && original[:anyOf].nil?
          return projected unless presence_rejects_blank?(ungated)

          projected.merge(not: { enum: BLANK_WIRE_VALUES })
        end

        # Whether a property constrains nothing — genuinely empty, or holding only the metadata an emitted
        # node carries without narrowing it (`description`, and the residues waiting to be rendered into it).
        def asserts_nothing?(prop) = prop.except(:description, RESIDUE_KEY).empty?

        # Drop an unknown-class side's fabricated type, and with it the keywords that only had a meaning
        # BECAUSE of it. `minLength`/`maxLength`/`pattern`/`format` exist in JSON Schema only for a string
        # instance, and `single_type_for` chose "string" as a permissive stand-in rather than because the
        # declaration says so — so once the collision reveals the position is really an object or an array,
        # those keywords are not merely wrong, they are INERT: JSON Schema ignores a `minLength` beside an
        # object, and the real size validator behind it (which measures whatever the value actually is)
        # would go unstated while the document looked constrained. Restating it would mean choosing the
        # keyword for a type only the collision revealed; it is reported as a residue instead.
        #
        # `enum` and the other value-level keywords stay: they name literals, which carry their own type
        # and mean the same thing whatever this side's type was guessed to be.
        FABRICATED_STRING_KEYS = %i[minLength maxLength pattern format].freeze

        def drop_fabricated_type(prop)
          stripped = prop.except(:type, :anyOf)
          inert = stripped.slice(*FABRICATED_STRING_KEYS)
          return stripped if inert.empty?

          record_residue(stripped.except(*FABRICATED_STRING_KEYS),
                         "the declared type is not one JSON can carry, so this position's own " \
                         "#{render_constraint(inert)} cannot be stated against it")
        end

        # Emit the trustworthy side alone, carrying over anything the dropped side already had to report and
        # naming what it still enforces. The dropped fragment IS the constraint, so it is rendered verbatim
        # rather than described: a reader (or an LLM choosing an argument) can act on `{"type":"integer",
        # "const":5}` in a way it cannot act on "some other constraint also applies".
        #
        # The kept side is detached from its nested `properties` map before it leaves here: that map may be
        # the ancestor's own already-emitted one, which `apply_nested_subfields!` is about to add this
        # node's children into — the aliasing merge_shape_member_property avoids by duping, and which a
        # bare hand-back would reintroduce on this path.
        def stand_down_from(kept, dropped, reason)
          kept = kept.dup
          kept[:properties] = kept[:properties].dup if kept[:properties].is_a?(::Hash)
          kept[:description] = carried_description(kept[:description], dropped[:description])
          kept.delete(:description) if kept[:description].nil?
          result = residues_on(dropped).reduce(kept) { |acc, r| record_residue(acc, r.summary, kind: r.kind) }
          constraint = dropped.except(:description, RESIDUE_KEY).compact
          summary = constraint.empty? ? reason : "#{reason} (#{render_constraint(constraint)})"
          record_residue(result, summary)
        end

        # The fragment a residue MENTIONS, rendered without requiring the caller's literals to be
        # JSON-encodable. They need not be: `normalize_scalar_literal` deliberately keeps a
        # `Float::INFINITY` default and its kind, so ordinary reflection does not fail on one — and a path
        # that merely NAMES such a value must not be the one that fails instead.
        def render_constraint(prop)
          JSON.generate(json_mentionable(prop))
        end

        # `value` reduced to something JSON can carry WITHOUT asking it anything. Reducing first rather than
        # encoding and rescuing is the point: `JSON.generate` dispatches `to_json`, so encoding a caller's
        # own object runs its code — which this layer may never do, and which a `StandardError` rescue does
        # not contain anyway (a `to_json` raising `NotImplementedError` escaped one and took `input_schema`
        # down while it was merely composing a report).
        #
        # Everything that reaches the encoder is a plain primitive: a String through `Text.renderable`, so
        # neither a subclass's `to_json` nor bytes with no UTF-8 rendering reach it, and anything else
        # through `Rendering`, whose reads are bound.
        def json_mentionable(value)
          case value
          when nil, true, false, ::Integer then value
          when ::Float then value.finite? ? value : mentionable_rendering(value)
          when ::String, ::Symbol then Axn::Internal::Text.renderable(value.to_s)
          when ::Array then value.map { |element| json_mentionable(element) }
          when ::Hash then value.to_h { |key, nested| [json_mentionable(key), json_mentionable(nested)] }
          else mentionable_rendering(value)
          end
        end

        def mentionable_rendering(value)
          Axn::Internal::Rendering.value_rendering(value) || Axn::Internal::Rendering.class_name(value)
        end

        # An authored `description:` survives a stand-down even though the declaration's constraints do not:
        # it describes the POSITION for a reader, not the value for a validator, so nothing about it is
        # untrustworthy across a transform or a closed gate. Dropping it silently lost the explicit node's
        # own prose in the ordinary case — a shape member cannot transform, so the node is nearly always the
        # side that stands down, and its description was published before this. Both are kept when both
        # exist, and an identical pair collapses.
        def carried_description(kept, dropped)
          return kept if dropped.nil? || kept == dropped
          return dropped if kept.nil?

          join_prose(kept, dropped)
        end

        # Two pieces of prose joined through the text seam, either of which may be caller-supplied and in
        # an encoding the other cannot be concatenated with.
        def join_prose(*parts)
          rendered = parts.compact.map { |part| Axn::Internal::Text.renderable(part.to_s) }
          rendered.empty? ? nil : rendered.join(" ")
        end

        # "object", nullable or not, at the TOP of a property — the one shape merge_shape_member_property's
        # keyword union actually reads (`properties`/`required`/the size bounds). Anything else — a scalar
        # `type:`, a bare `anyOf`/`enum` with no top-level `type` — has no such surface, so conjoin_shape_
        # member_property falls back to allOf rather than guessing at a per-keyword meaning.
        def object_property?(prop)
          type = prop[:type]
          type == "object" || (type.is_a?(::Array) && type.include?("object"))
        end

        # Whether ANY config in this route list transforms the wire value it judges — a Proc
        # (`preprocess:`), or a declared type with a coercible branch and no explicit `coerce: false`.
        #
        # A shape member (`Core::Contract::ShapeConfig`) can do NEITHER — `_reject_member_coerce!` refuses
        # `coerce:`/`coerce: true` on one at declaration ("it has no reader for a coerced value to resolve
        # onto"), and the same is true of `preprocess:` (`_reject_model_transform!`'s sibling guard). Both
        # rejections are declaration-time GUARDS, not evidence the ambient `coerce_input_types` flag could
        # somehow still apply where the explicit spelling cannot: coercion is fundamentally a FIELD/reader
        # mechanism (`ContractForSubfields.resolve_value`'s read path), and a member never has one — so an
        # `Integer`-typed member is never coerced, ambient flag or not, and treating it as approximate
        # wrongly discarded its OWN exact constraints (`inclusion:`'s `enum` included) against a colliding
        # node that cannot coerce it either (`type: Integer, inclusion: { in: [5] }` on a member, `type: {
        # klass: Integer, coerce: false }` on the colliding node — NEITHER side can coerce, yet the
        # member's own type being merely "coercible in principle" forced it to `{}`, dropping the `enum` a
        # plain, un-coercing collision needed no protecting from at all). `respond_to?(:preprocess)` is
        # reused as the "can this config transform at all" signal, since a shape member and a
        # subfield/field config already differ on it for the identical reason.
        #
        # For a config that COULD carry either: `Coercion::SUPPORTED` is checked directly rather than
        # through a bare `coerce:` key — a bare `coerce: <Type>` is sugar for `type: { klass:, coerce: true
        # }`, `_expand_coerce_sugar!` settles it into the bag form before `validations` ever holds it, so
        # there is no separate bare spelling left to check. An ABSENT `coerce:` on a coercible type is not
        # evidence of no transform — the class/global `coerce_input_types` setting (always on under
        # `Axn::Tools::Invoker`) coerces every such field whose own `coerce:` is silent, and reflection
        # cannot resolve that per-call/per-class flag (the same conservatism
        # `boolean_coercion_can_flip_truthiness?` already applies) — so only an explicit `coerce: false`
        # rules a coercible token out, mirroring `Coercion.field_coerces?`'s own explicit-wins semantics.
        def transforms_wire_value?(configs)
          configs.any? do |config|
            next false unless config.respond_to?(:preprocess) # a shape member has no reader, hence neither coerces nor preprocesses
            next true if config.preprocess

            type_opt = config.validations[:type]
            next false if type_opt.is_a?(::Hash) && type_opt[:coerce] == false

            !Axn::Internal::Coercion.coercible_klasses(type_opt).empty?
          end
        end

        # Whether `single_type_for`'s INPUT branch for this token falls through to its permissive `{type:
        # "string"}` fallback ("a JSON client can't send a Ruby object anyway") rather than asserting a real
        # JSON type — the OTHER reason (beside a transform) an emitted property is untrustworthy, and
        # deliberately UNRELATED to coercibility: `unknown_class_approximate?` (below) is asked only once
        # `transforms_wire_value?` has already had first say, so a coercible token is never re-litigated
        # here. Derived from the SAME branches `single_type_for` checks, in the same order, so the two
        # cannot disagree about which classes are "known": boolean/uuid/params, a `TYPE_MAP` entry, or a
        # Numeric excluding Complex (which falls through to the fallback on input too, exactly as
        # `single_type_for` itself does).
        def unknown_class_token?(token)
          return false if Axn::Internal::Identity.same?(token, ::TrueClass)
          return false if Axn::Internal::Identity.same?(token, ::FalseClass)
          return false if Axn::Internal::Identity.same?(token, :uuid)
          return false if Axn::Internal::Identity.same?(token, :params)
          return false unless nil.equal?(map_type_for(token))

          !numeric_but_not_complex?(token)
        end

        # Whether ANY branch of a config's declared type is an unknown-class hint. `.any?`, not `.all?`: a
        # mixed union like `type: [Object, String]` has one exact branch, but `Object` alone already admits
        # everything the union could ever narrow to, so the union as a whole asserts nothing more precise
        # than the approximate branch does (a `.all?` reading let a union with an approximate branch
        # through as "exact"). Untyped (no declared type at all) is NOT approximate: it emits no `:type`
        # key at all rather than a misleading one, which is the `own_prop.empty?` case
        # `conjoin_shape_member_property` already handles on its own terms. And `.all?` across MULTIPLE
        # configs (a merged node's routes) — the opposite quantifier from the per-config `.any?`, because
        # the two lists mean opposite things: a config's own tokens are a UNION (an OR — any branch is
        # enough to widen toward "everything"), while multiple ROUTES at one key are each independently
        # enforced (an AND — one exact route already narrows the combined constraint regardless of an
        # approximate route beside it), so the side counts as approximate only when NONE of its routes
        # assert anything real. An empty list is NOT approximate — the conservative, pre-existing answer
        # for a side this walk cannot judge.
        def unknown_class_approximate?(configs)
          !configs.empty? && configs.all? do |config|
            tokens = declared_type_tokens(config.validations)
            !tokens.empty? && tokens.any? { |t| unknown_class_token?(t) }
          end
        end

        # Duped when only one side has them: `apply_nested_subfields!` mutates the map it is handed as it adds
        # children, and the member's own emission must not be written through. A name BOTH sides declare is
        # conjoined rather than let the second (`own_props`, the node's own child) win outright — PRO-3405;
        # `apply_structured_schema!`'s own `base_properties.merge(member_props)` is a different question (an
        # INFERRED property deferring to a DECLARED one), not two declarations colliding, and is unchanged.
        #
        # `member_configs`/`own_configs` — the routes each side's PARENT config came from — are re-resolved
        # PER COLLIDING KEY via `shape_members_at`, the same locator emission and the drop pass already share:
        # a name colliding one level down was declared by a DIFFERENT (nested) config than the one that
        # produced `member_props`/`own_props` themselves, so the parent's approximateness says nothing about
        # the child's (a real `type: String` and the `Object` fallback emit the byte-identical property, so
        # only the declaration distinguishes them).
        def merge_emitted_maps(member_props, own_props, member_configs: [], own_configs: [])
          return own_props if member_props.nil?
          return member_props.dup if own_props.nil?

          member_props.merge(own_props) do |key, member_prop, own_prop|
            conjoin_shape_member_property(
              member_prop, own_prop,
              member_configs: shape_members_at(member_configs, key),
              own_configs: shape_members_at(own_configs, key)
            )
          end
        end

        def merge_emitted_required(member_required, own_required)
          return own_required if member_required.nil?
          return member_required.dup if own_required.nil?

          member_required | own_required
        end

        # Every `shape:` member declared at `key` across `parent_configs` (the implicit node collides with
        # them). Each config is a top-level field config OR a shape-member config carried through implicit
        # descent; both respond to `.validations` and expose nested members via `dig(:shape, :members)`.
        # Written to allocate nothing on the overwhelmingly common answer (no `shape:` at this node, or one
        # naming other keys), because the drop pass asks this per hop and emission asks it per child: a config
        # with no members list is skipped before `named_members` is entered at all, and the result array is
        # built only once something matches. The previous `flat_map` spelling paid a discarded list per config
        # whether or not any shape existed.
        def shape_members_at(parent_configs, key)
          found = nil
          Array(parent_configs).each do |config|
            declared = config.validations.dig(:shape, :members)
            next if declared.nil?

            named_members(declared).each { |m, name| (found ||= []) << m if name.to_sym == key }
          end
          found || NO_SHAPE_MEMBERS
        end

        # Every exposed field is always present in the serialized output: Values.serialize_exposed iterates
        # every outbound config and emits its key (value nil when unset). JSON Schema `required` means
        # property PRESENCE, not non-nullness, so every exposed field is `required`; nullability is carried
        # by the property `type` ("null").
        def build_output(field_configs)
          properties = {}
          required = []

          field_configs.each do |config|
            properties[config.field] = build_property(config, for_output: true).compact
            required << required_key(config.field)
          end

          schema = { type: "object", properties: }
          schema[:required] = required.uniq unless required.empty?
          schema
        end

        # Deep-copy a reflected literal (a `default:` value or an inclusion enum member) and normalize any
        # leaf whose JSON wire form differs from its Ruby form — Time/DateTime/Date → iso8601 String,
        # Symbol → String, non-Integer/Float Numeric (BigDecimal/Rational) → Float — so the emitted
        # `default`/`enum` matches the property's advertised type. Scalar wire coercion is delegated to
        # Values.serialize_value (the single source of truth for it), so the two never drift. Mutable
        # String leaves are duped so a consumer mutating the returned schema can't reach the stored
        # contract; an unrecognized object is left as-is (schema literals are already simple values,
        # so this deliberately does NOT follow Values.serialize_value's as_json/to_h coercion).
        def normalize_schema_literal(value)
          # Only EXACT built-in containers are traversed/duped (instance_of?, not is_a?): an Array/Hash/
          # String SUBCLASS could override map/each_with_object/dup with user code, and reflection must stay
          # side-effect-free — so a subclass (like any other unrecognized object) is left opaque.
          if value.instance_of?(Hash)
            # Dup mutable String keys too (leaving them shared would let a consumer mutating a returned key
            # in place corrupt FieldConfig#default).
            value.each_with_object({}) { |(k, v), h| h[k.instance_of?(String) ? k.dup : k] = normalize_schema_literal(v) }
          elsif value.instance_of?(Array)
            value.map { |v| normalize_schema_literal(v) }
          elsif value.instance_of?(String)
            value.dup
          elsif value.is_a?(Symbol) || value.is_a?(Time) || value.is_a?(Date) || value.is_a?(Numeric)
            normalize_scalar_literal(value)
          else
            value
          end
        end

        # A literal the serializer refuses outright — a non-finite `default: Float::INFINITY`, which no JSON
        # `default` could carry — is reported exactly as declared. Reflection describes a declaration and must
        # never raise on user data, and a reflected literal makes no encodability promise; `serialize_exposed`'s
        # output, which does make one, is where that refusal belongs.
        def normalize_scalar_literal(value)
          Values.serialize_value(value)
        rescue Axn::Extensions::Serialization::UnserializableValue
          value
        end

        # The `enum:` member list for an inclusion set. `nullable` (nil_allowed?) is the runtime truth: when
        # false, a literal `nil` member is dropped (an explicit nil is rejected there); when true, `nil` is
        # added if not already present.
        def enum_for_inclusion(enum_values, nullable:)
          members = normalize_schema_literal(enum_values)
          return members.compact unless nullable

          # Identity check, not include?/==: an enum member with a custom `==` must not run during reflection.
          members.any? { |m| m.equal?(nil) } ? members : members + [nil]
        end

        # On OUTPUT an enum names what the action may PRODUCE, so it has to hold the wire form of every value the
        # runtime accepts — and the runtime accepts by Ruby `==`, which can identify values that SERIALIZE
        # differently. Two DateTimes for one instant in different offsets are `==` and render as different
        # ISO-8601 strings; a Date is `==` to a DateTime at midnight and renders shorter; `1 == 1.0` renders as
        # `1` and `1.0`. Each emits a set that rejects the action's own successful output.
        #
        # A member settles this for itself wherever its equality admits only its own type: a String, a Symbol,
        # `true`, `false` and `nil` can only be `==` to a value that serializes identically, whatever class the
        # position declares. A numeric member cannot, Ruby's tower crossing types, so it asks the position to pin
        # exactly one numeric class — which is what keeps `type: Integer, inclusion: { in: [200, 404] }`
        # reflecting. Anything else — a Time, a Date, an arbitrary object — stands the set down.
        #
        # INPUT needs no gate: there the emitted set is the values a client may SEND, and a set narrower than the
        # runtime's equality is stricter, which is the licensed direction.
        def output_enum_exact?(members, validations, declared_klass)
          members.all? do |member|
            case member
            when ::String, ::Symbol, ::TrueClass, ::FalseClass, ::NilClass then true
            when ::Numeric then numeric_enum_pinned?(member, validations, declared_klass)
            else false
            end
          end
        end

        # Whether the position admits exactly the numeric class this member already is, so that no OTHER numeric
        # type can be `==` to it and serialize differently. A position naming no class at all admits the whole
        # tower and cannot pin anything.
        def numeric_enum_pinned?(member, validations, declared_klass)
          tokens = declared_type_tokens(validations, declared_klass)
          return false if tokens.empty?

          tokens.all? { |token| Internal::Identity.same?(token, Internal::Identity.class_of(member)) }
        end

        # The classes a position declares: a `type:` bag's `klass:` where a bag was declared, the bare spelling
        # otherwise, and a `declared_klass` handed in directly by a CONTENTS position — a bag names its classes
        # under `klass:`, which `bag_value_constraints` deliberately drops from the validator set, so that
        # caller has them already and passes them through.
        #
        # Every branch classifies through `ShapeGraph.type_tokens` rather than `Kernel#Array`, which DISPATCHES
        # `to_ary`/`to_a` on whatever it is handed: a declared token is a caller's own Class or Module, and one
        # carrying a singleton `to_ary` would have that method RUN from here — at declaration, and again from
        # every reflection — which reflection may never do. Measured on a token whose `to_ary` returns
        # `[String]`: it ran, and the emitted node became `{type: ["string", "null"]}` for a field declared as
        # that token. The bag is unwrapped through `ShapeGraph.hash_or_nil` for the same reason, so a Hash
        # subclass denying its own class cannot pick how it is read.
        def declared_type_tokens(validations, declared_klass = nil)
          return Axn::Internal::ShapeGraph.type_tokens(declared_klass) unless nil.equal?(declared_klass)

          type_opt = validations[:type]
          bag = Axn::Internal::ShapeGraph.hash_or_nil(type_opt)

          Axn::Internal::ShapeGraph.type_tokens(nil.equal?(bag) ? type_opt : bag[:klass])
        end

        # The literal membership set of an `inclusion:` validator, whether declared as the hash long form
        # ({ in: [...] } / { within: [...] }) or the equivalent bare-Array shorthand (inclusion: %w[a b c]).
        # The two enforce the same set at runtime, so reflection treats them identically (PRO-2944). Exact
        # Array only (instance_of?, not is_a?): an Array subclass could override the map/each the enum and
        # type inference downstream depend on, and reflection must never run user code — a subclass set (or a
        # dynamic Symbol/Proc source) simply reflects no enum (returns nil).
        def inclusion_enum_values(inclusion)
          values = Axn::Validation::Base.declared_set_collection(inclusion)
          values if values.instance_of?(Array)
        end

        def build_property(config, for_output: false, subfield: false, ancestry: nil)
          prop = {}
          # `#description` is beyond the documented member contract (see declared_attribute).
          description = declared_attribute(config, :description)
          prop[:description] = description if description

          # OUTPUT safety runs the other direction from input: the property must admit a SUPERSET of
          # what the serializer can emit. A closed outbound gate skips EVERY validator (not just
          # presence), so the exposed value can be anything the action assigned — no type/format/enum/
          # default is assertable. Leave the property untyped (description only): untyped is the only
          # superset of an unconstrained value. Mirrors the module's output doctrine of leaving a value
          # untyped rather than asserting a type the serialized value could contradict.
          return prop if for_output && conditionally_gated?(config)

          # OUTPUT-EFFECTIVE validations (see effective_validations, the one derivation of them): everything
          # below reads the config through that subset, so a per-validator gate drops the same entry here as
          # in the plan every property-name rule is charged against. Rebuild the config only when an entry
          # actually drops, judged against the SAME read of `validations` the reduction was given — a
          # caller-supplied member's reader may mint a fresh Hash per read, so comparing against a second read
          # would rebuild every config (and a duck-typed member answers no `with` at all).
          declared = config.validations
          effective = effective_validations(declared, for_output:)
          config = config.with(validations: effective) unless effective.equal?(declared)

          type_info = json_type_for(config.validations, for_output:)
          nullable = nil_allowed?(config)
          apply_type_info!(prop, type_info, config, nullable:)

          declared_default = declared_attribute(config, :default)
          if !declared_default.nil? && !declared_default.is_a?(Proc)
            # Only a truthy subfield default is applied at runtime, so a falsey `default: false` subfield
            # must not advertise a default the runtime never applies. Top-level defaults apply by key-presence.
            emit_default = subfield ? config.applied_default? : true
            prop[:default] = normalize_schema_literal(declared_default) if emit_default
          end

          apply_structured_schema!(prop, config, for_output:, ancestry:)

          # LAST, because the floor's KEY is chosen from the property's type (`minItems`/`minProperties`/
          # `minLength`) and a shape block is what establishes that type: a custom class or module carrying one
          # holds the permissive fallback until `apply_structured_schema!` rewrites it to `object`. Deriving
          # the key any earlier reads an intermediate type and lands the floor under a key that cannot express
          # it. Nothing above depends on the constraint already being there.
          apply_value_constraints!(prop, config.validations, nullable:, for_output:)

          prop
        end

        # Writes the resolved JSON type (and nullability/format/singleton-enum) from json_type_for into prop.
        def apply_type_info!(prop, type_info, config, nullable:)
          if type_info[:anyOf]
            members = type_info[:anyOf]
            members = drop_uuid_format(members) if type_allows_blank?(config)
            members = union_with_nullability(members, nullable:)
            # Dropping a token-derived null branch can leave a single member, and a one-branch `anyOf` is a
            # gratuitous shape change for a declaration whose node was a plain `type:` before. Collapse it back
            # onto the single-type path, which is also what lets the emptiness floor land at the node rather than
            # inside a lone branch. Only reachable when NOT nullable — a nullable union always keeps two.
            if members.size == 1
              apply_single_type!(prop, members.first, config, nullable: false)
            else
              prop[:anyOf] = members
            end
          elsif type_info[:type]
            apply_single_type!(prop, type_info, config, nullable:)
          elsif type_info[:enum]
            # A type_info carrying only an enum names no type and still constrains the value — which is how a
            # contract nothing satisfies reaches the node, as `enum: []`. Nullability joins it exactly as it
            # joins a singleton's enum above: a narrowing that empties every TYPE branch has said nothing about
            # nil, which the validators SKIP wherever the field tolerates one. So `type: String, numericality:
            # { only_numeric: true }, optional: true` admits nil and nothing else — measured, it exposes nil
            # successfully — and the bare empty set rejected the very value it accepts.
            prop[:enum] = nullable ? type_info[:enum] + [nil] : type_info[:enum]
          end
        end

        def apply_single_type!(prop, type_info, config, nullable:)
          if unsatisfiable_type?(type_info[:type], nullable:)
            prop[:enum] = EMPTY_ENUM
            return
          end

          prop[:type] = type_with_nullability(type_info[:type], nullable:)
          # A `type: :uuid, allow_blank: true` field accepts "" at runtime (TypeValidator treats a blank
          # uuid as valid under allow_blank), but a strict `format: "uuid"` validator would reject "".
          # Drop the uuid format there so the schema doesn't reject a value the contract accepts.
          prop[:format] = type_info[:format] if type_info[:format] && !(type_info[:format] == "uuid" && type_allows_blank?(config))
          # A singleton type (TrueClass/FalseClass) constrains the value via enum; nil joins it when nullable.
          prop[:enum] = nullable ? type_info[:enum] + [nil] : type_info[:enum] if type_info[:enum]
          # A pattern the TYPE resolution put there (`only_integer:` on a string branch) travels with it. Without
          # this it survived a union and was dropped the moment the union collapsed to one branch — the same node,
          # reached by two paths, saying two different things. A declared `format:` still overwrites it later,
          # one schema object having only the one slot.
          prop[:pattern] = type_info[:pattern] if type_info[:pattern]
        end

        # Whether the emitted type admits `null` is the NULLABILITY question (`nil_allowed?`), never something a
        # type token decides. A declared `NilClass` contributes a branch like any other token; this is where that
        # branch is kept or dropped, so the two cannot disagree. Without it a REQUIRED `type: [String, NilClass]`
        # would advertise `null` while its own `presence:` entry rejects nil, and a nullable one would advertise
        # it twice.
        def union_with_nullability(members, nullable:)
          without_null = members.reject { |member| member[:type] == "null" }
          return without_null + [NULL_BRANCH] if nullable

          # A union of nothing BUT null cannot arise (`json_type_for` uniq's, so it would be a single type), but
          # stripping to an empty `anyOf` would emit a node no value satisfies, so the guard is kept rather than
          # left to an argument about reachability.
          without_null.empty? ? members : without_null
        end

        # A lone `NilClass` keeps its `"null"` only where nullability would have added it anyway. NOT nullable,
        # the contract admits nothing at all — nothing is a NilClass except nil, and the check that makes it
        # non-nullable rejects nil — and `"null"` then advertised the single value the contract rejects, which is
        # schema LOOSER than runtime, the one direction reflection may never err in. See `unsatisfiable_type?`.
        def type_with_nullability(type, nullable:)
          return type if type == "null"

          nullable ? [type, "null"] : type
        end

        # Whether the emitted type names a contract no value satisfies, which is true of exactly one pairing: a
        # lone `"null"` that is not nullable. `enum: []` is the faithful node for it — the spelling this emitter
        # already uses wherever a contract admits nothing (an `only_integer:` narrowing that empties a union,
        # two disagreeing `equal_to:` bounds) — and it is emitted INSTEAD of the type rather than beside it, so
        # none of the keyword passes that key off a type can land on a node nothing reaches. Refusing such a
        # declaration outright stays PRO-3220's, exactly as it does for the other two.
        def unsatisfiable_type?(type, nullable:) = type == "null" && !nullable

        # The emptiness axis, as JSON Schema sees it: `minItems`/`minProperties`/`minLength` keyed off the
        # emitted type. A field rejects empty when it carries an explicit length minimum, or when the default
        # presence check applies without blank-tolerance — `presence` is `!blank?`, so it forbids the empty value
        # too. Only `allow_blank` is consulted, never `allow_nil`: nil-tolerance is the other axis and says
        # nothing about whether an empty value is admissible. Emitting this is what keeps a required
        # collection's schema from advertising `[]` as acceptable when the runtime rejects it — which is why it
        # follows the emitted type into a union's `anyOf` branches as well as a single `type:`.
        # For a String under `presence:` the runtime also rejects whitespace-only values, which
        # `minLength` cannot express, so the emitted constraint stays a floor rather than an exact mirror.
        # Every validator-derived keyword for ONE position's node, in one place. `build_property` runs it for a
        # named position (a field, a subfield, a shape member) and `contents_node_schema` for an unnamed one (an
        # Array's element, a map's axis), so a keyword cannot land at one position and be forgotten at another —
        # which is what a mirrored copy would eventually become. The keyword each one lands on is decided by the
        # node's own emitted `type:`, so the same call does the right thing wherever the node sits.
        def apply_value_constraints!(node, validations, nullable:, for_output:, property_names: false, declared_klass: nil)
          apply_inclusion_enum!(node, validations, nullable:, for_output:, property_names:, declared_klass:)
          apply_size_constraints!(node, validations, for_output:, property_names:, declared_klass:)
          apply_numeric_bounds!(node, validations, nullable:, for_output:, declared_klass:)
          apply_pattern!(node, validations, for_output:, property_names:, declared_klass:)
        end

        # `enum` is INTERSECTED with whatever the node already carries, never assigned over it: a singleton type
        # constrains itself by enum too (`TrueClass` emits `enum: [true]`, because the runtime accepts only the
        # singleton), so overwriting it advertised `false` on a `klass: TrueClass` position the runtime rejects.
        # Both are enforced, so the emitted set is the values that satisfy both.
        #
        # On a `propertyNames` node the members must additionally be renderable AS a property name — every JSON
        # object key is a string. A Symbol has a faithful form; an Integer does not, and the runtime really does
        # accept `{ 1 => v }`, so a set with any unrenderable member stands the ENUM down (leaving the axis's
        # other, string-shaped constraints in place) rather than emit a set no key can satisfy.
        def apply_inclusion_enum!(node, validations, nullable:, for_output:, property_names:, declared_klass: nil)
          inclusion = validations[:inclusion]
          return unless inclusion

          values = inclusion_enum_values(inclusion)
          return unless values

          if property_names
            values = property_name_enum(values, for_output:)
            return if values.nil?
          else
            return if for_output && !output_enum_exact?(values, validations, declared_klass)

            values = enum_for_inclusion(values, nullable:)
          end

          existing = node[:enum]
          node[:enum] = existing ? existing & values : values
        end

        # Whether a JSON key — always a String — could satisfy this axis's declared class. An axis naming none
        # constrains no class and so admits one. `:uuid` is the one pseudo-type whose values ARE Strings;
        # `:boolean` and `:params` are not, and neither is any other class unless String descends from it.
        # The keys-axis validators whose subject is the key OBJECT rather than the property name it serializes
        # to. See `own_wire_form?` for why these three and not the rest.
        #
        # `presence:` belongs here for the same reason `length:` does, and it is easy to miss because what it
        # emits is a LENGTH keyword: ActiveModel asks the key object's own `blank?`, so an object that is present
        # can still render as the empty property name — measured, a key whose `to_s` is `""` satisfies
        # `presence: true`, serializes the map as `{"" => 1}`, and the emitted `propertyNames: { minLength: 1 }`
        # rejects it. `absence:` needs no entry: it emits nothing into a `propertyNames` node at all. `format:`
        # is deliberately absent, being the one validator whose subject IS the wire string — ActiveModel matches
        # `value.to_s`, which is what `canonical_wire_key` dispatches for a key.

        # `ShapeGraph.type_tokens`, not `Kernel#Array` — `klass` is a caller-declared axis token here, and
        # `Array()` would dispatch `to_ary`/`to_a` on it (see `declared_type_tokens` above).
        def axis_admits_string_key?(klass)
          tokens = Axn::Internal::ShapeGraph.type_tokens(klass)
          return true if tokens.empty?

          tokens.any? { |token| string_reachable_key_token?(token) }
        end

        # Whether a String key could satisfy this token — String itself, or any SUPERTYPE of it. A `klass: Object`
        # axis answers yes, correctly: a JSON client really can send a key that satisfies it.
        def string_reachable_key_token?(token)
          case token
          when ::Symbol then token == :uuid
          # `String <= token` asked the same question, but reversing it to satisfy the linter would dispatch
          # `>=` on a caller-supplied Module. This reads String's OWN ancestry natively instead, which is the
          # undispatched form and the seam the error-path rules already point at.
          else Internal::Identity.kind?(token, ::Module) && Internal::NativeMethods.includes_module?(::String, token)
          end
        end

        # Whether every value this token admits IS the string it serializes to — String itself, or a SUBTYPE of
        # it, plus Symbol, whose `#to_s`, `#length` and `==` are all its name's. The opposite ancestry direction
        # from the predicate above, and deliberately not shared with it: reachability asks "could a String
        # satisfy this position", and a broad token answers yes to that while admitting values that are not
        # Strings at all. `Object` is the case that separates them.
        def own_wire_string_token?(token)
          return token == :uuid if Internal::Identity.kind?(token, ::Symbol)
          return false unless Internal::Identity.kind?(token, ::Module)

          Internal::Identity.same?(token, ::Symbol) || Internal::NativeMethods.includes_module?(token, ::String)
        end

        # Whether the axis guarantees a key that IS the property name the serializer writes. Two of the projected
        # keywords ask about the key OBJECT rather than its wire form, and both are wrong when the two come apart:
        #
        #   `length:`    ActiveModel measures the object's `#length`, `minLength`/`maxLength` measure the property
        #                name. A path whose `#length` counts segments serializes to "a/b" — runtime 2, wire 3.
        #   `inclusion:` the runtime matches by Ruby `==`, which can identify values with DIFFERENT wire forms.
        #                `1 == 1.0`, so a `{ in: [1] }` axis accepts a `1.0` key that serializes to "1.0" while
        #                the emitted set holds only "1".
        #
        # Both reduce to one question — is the key its own wire form — so one gate answers both rather than a
        # keyword-by-keyword table that has to be re-argued for each new keyword. `format:` is exempt by
        # construction, not by omission: ActiveModel matches `value.to_s` and the serializer writes the same
        # `to_s`, so its subject is the wire form already.
        # `ShapeGraph.type_tokens`, not `Kernel#Array` — `klass` is sometimes a raw axis token here too (see
        # `axis_admits_string_key?`), and `type_tokens` is idempotent on the callers that already pass an Array.
        def own_wire_form?(klass)
          tokens = Axn::Internal::ShapeGraph.type_tokens(klass)
          return false if tokens.empty?

          tokens.all? { |token| own_wire_string_token?(token) }
        end

        # A property-name set, or nil to stand down — and the two directions are different questions.
        #
        # On OUTPUT the members are rendered by `Values.canonical_wire_key`, the SAME function the map's own
        # serializer uses for a key. Reading them through the VALUE serializer instead was wrong for any type
        # whose two renderings differ: a Time value serializes as `iso8601` and a Time KEY as `to_s`, so the
        # emitted set named a key the map never produces.
        #
        # On INPUT only a String member survives. A JSON client can send nothing but string keys, and a
        # non-String axis rejects one — measured, a `keys: Symbol` axis refuses `{ "a" => 1 }` while accepting
        # `{ a: 1 }` — so advertising the rendered form there would tell a client to send a key axn will refuse.
        # That is PRO-3165's "a `keys: Symbol` would be a lie on the wire", which holds for a SET exactly as it
        # held for a bare type.
        def property_name_enum(values, for_output:)
          return values.map { |value| Values.canonical_wire_key(value) } if for_output

          # Inbound, the REACHABLE subset rather than all-or-nothing. A JSON key is a String, so it can only
          # ever equal a String member — which makes `["a", 1]` project to exactly `["a"]`: not an
          # approximation, but the precise set of JSON-supplied keys the runtime accepts. Standing down from
          # the whole constraint instead admitted every key the document said nothing about.
          reachable = values.grep(::String)
          # Nothing reachable, and the axis's CLASS already admits a String key — the whole inbound projection
          # is gated on that before this runs — so the position is reachable from JSON while its set holds
          # nothing a JSON key could equal: no key satisfies it, and `enum: []` is what says so. Standing down
          # instead advertised every key the document was silent about, and `keys: { klass: [String, Integer],
          # inclusion: { in: [1] } }` accepted `{"x" => 1}` while the runtime rejected it.
          #
          # The axis whose class excludes String is a DIFFERENT case and keeps its stand-down: there the wire
          # cannot reach the position at all, a Ruby caller satisfies it perfectly well, and PRO-3165 already
          # turns that whole projection away above rather than emitting a set no client can satisfy.
          return EMPTY_ENUM if reachable.empty?

          # Detached, never the inclusion array's own Strings: reflection hands these to a consumer, and one
          # mutating a member in place would change which keys the DECLARED action accepts. The value-enum path
          # dups through the same normalizer.
          normalize_schema_literal(reachable)
        end

        # A declared `format:` reflects as `pattern` when the regex translates faithfully — `Reflection::Pattern`
        # owns that judgment and returns nil to stand down, which is what the emitter did for every regex
        # before this. Only `with:` is read: `without:`'s honest spelling is `not: { pattern: ... }`, and `not:`
        # is a single slot `reject_null!` already writes into, so a second writer would silently clobber the
        # first. Booked as unemitted alongside `exclusion:`, which has the same shape.
        def apply_pattern!(prop, validations, for_output:, property_names: false, declared_klass: nil)
          entry = Axn::Validation::Base.validator_entries(validations)[:format]
          return unless entry
          # ActiveModel matches `value.to_s`, and on OUTPUT that is not always the string the wire carries: the
          # VALUE serializer renders a Time as `iso8601` and a Date as its own ISO form, so a pattern the runtime
          # measured against `"2026-08-25 12:00:00 UTC"` is measured against `"2026-08-25T12:00:00Z"` instead and
          # rejects output the action produced. Emitted outbound only where the value IS the string it serializes
          # to. A KEY is exempt: `canonical_wire_key` dispatches `to_s`, the same subject the validator used.
          return if for_output && !property_names && !own_wire_form?(declared_type_tokens(validations, declared_klass))

          pattern = Pattern.ecma_source(Axn::Validation::Base.validator_entry_options(entry)[:with], for_output:)
          write_pattern_to_string_nodes!(prop, pattern) if pattern
        end

        # A union leaves the node's own `type:` unset and its branches under `anyOf`, so a pattern written at the
        # node would sit on nothing — the same shape `write_numeric_bound!` follows for a bound, and the reason a
        # union `format:` reflected nowhere at all while a single-type one reflected fine, leaving the string
        # branch of `type: [String, Integer], format: …` advertising values the validator rejects.
        def write_pattern_to_string_nodes!(node, pattern)
          return write_pattern!(node, pattern) if Array(node[:type]).include?("string")
          return unless node[:anyOf].is_a?(Array)

          node[:anyOf] = node[:anyOf].map do |branch|
            next branch unless Array(branch[:type]).include?("string")

            branch.dup.tap { |composed| write_pattern!(composed, pattern) }
          end
        end

        # Both patterns are enforced, so both are emitted. A node has one `pattern` slot, and a declared `format:`
        # landing beside the one `only_integer:` installs had been overwriting it — `type: String,
        # numericality: { only_integer: true }, format: { with: /\A[0-9a-z]+\z/ }` then advertised `"abc"`, which
        # the runtime rejects on the integer test. `allOf` is JSON Schema's spelling for the conjunction, and it
        # is free at a property: the conditional `allOf` this emitter writes is at the schema ROOT.
        def write_pattern!(node, source)
          existing = node[:pattern]
          return node[:pattern] = source if existing.nil? || existing == source

          node.delete(:pattern)
          node[:allOf] = [{ pattern: existing }, { pattern: source }]
        end

        # The bound twin of the emptiness floor/ceiling: a declared `numericality:`/`comparison:` bound reflects
        # as the JSON Schema keyword that means the same thing. Read through `Base.declared_numeric_bounds`, the
        # same reader the runtime bound comes from, so the two cannot disagree about one declaration.
        #
        # Emitting only ever shrinks the schema-valid set, so it preserves the documented direction (stricter
        # than the runtime, never looser) by construction — and every case a bound cannot be carried exactly
        # stands down to emitting nothing, which is where this started.
        # An `enum` is INTERSECTED with whatever the node already carries rather than assigned over it, the same
        # rule `apply_inclusion_enum!` follows and for the same reason: both sets are enforced.
        def merge_enum!(prop, values)
          existing = prop[:enum]
          prop[:enum] = existing ? existing & values : values
        end

        def apply_numeric_bounds!(prop, validations, nullable:, for_output:, declared_klass: nil)
          return unless numeric_node?(prop)
          return if for_output && !numeric_serialization_exact?(declared_type_tokens(validations, declared_klass))

          entries = Axn::Validation::Base.validator_entries(validations)
          # Both entries are enforced, so their bounds are INTERSECTED into one set before any keyword is
          # written — assigning per entry let whichever the iteration reached last win, and emitted the weaker
          # bound of the two (`numericality: { greater_than: 10 }, comparison: { greater_than: 0 }` advertised
          # `exclusiveMinimum: 0` while the runtime rejected 5).
          bounds = {}
          NUMERIC_BOUND_ENTRIES.each do |key, ranged|
            entry = entries[key]
            next unless entry

            Axn::Validation::Base.declared_numeric_bounds(entry, ranged:).each do |operator, bound|
              next unless Axn::Validation::Base.emittable_numeric_bound?(bound)

              Axn::Validation::Base.intersect_numeric_bound(bounds, operator, bound)
            end
          end

          # An intersection with no solution resolves to a sentinel rather than a bound
          # (`Base::CONTRADICTORY_BOUND`), and the node then says NOTHING SATISFIES THIS rather than saying less.
          #
          # That is the faithful projection, and standing down here would be the papering-over PRO-3220 warns
          # against: the corollary in guards-and-projections.md forbids an unsatisfiable node for a SATISFIABLE
          # contract, this contract admits nothing, and the emitter already projects that family unsatisfiably
          # elsewhere (`length: { maximum: 0 }` on a required Array emits `minItems: 1, maxItems: 0`). Refusing
          # the declaration outright stays PRO-3220's; being honest about it is this layer's job.
          #
          # `enum: []` is the spelling: it is satisfied by no value, and it composes rather than collides —
          # intersecting it with an enum the node already carries yields `[]` either way, where `not: {}` would
          # contend for a slot `reject_null!` already writes.
          wrote_bound = false
          bounds.each do |operator, bound|
            if Axn::Validation::Base.contradictory_bound?(bound)
              # Nullable, nil is still a passing value — the validators skip it — so the node that admits
              # nothing ELSE must say that rather than admit nothing at all.
              merge_enum!(prop, nullable ? [nil] : EMPTY_ENUM)
              next
            end
            next unless Axn::Validation::Base.emittable_numeric_bound?(bound)

            # `const` names exactly one value, so it cannot say "this number OR null", and a nullable position
            # really does admit nil: `type: Integer, comparison: { equal_to: 1 }, optional: true` exposes nil
            # successfully while `const: 1` rejected it, even beside a `"null"` in the node's own `type:`. The
            # enum spelling says both, and intersects with any set the node already carries.
            if operator == :equal_to && nullable
              merge_enum!(prop, [bound, nil])
              wrote_bound = true
              next
            end

            write_numeric_bound!(prop, NUMERIC_BOUND_KEYS.fetch(operator), bound)
            wrote_bound = true
          end

          # Only where a bound was actually written: a union merely CONTAINING a numeric branch is what
          # `numeric_node?` answers, and narrowing on that would drop the string branch of a plain
          # `type: [String, Integer]` that declares no bound at all.
          restrict_union_to_bounded_branches!(prop) if wrote_bound && !for_output
        end

        # A bound can only be written onto a branch that carries a numeric type, which leaves a union's other
        # branches advertising values the validator rejects: `type: [String, Integer], numericality: { greater_than: 0 }`
        # accepted `"abc"` through the string branch while ActiveModel rejected it on every call. Input reflection
        # may be STRICTER than the runtime but never looser (`docs/reference/class.md`), and a narrowing is the
        # licensed direction — so the branches that cannot carry the bound are dropped rather than left lying.
        # ActiveModel does accept a numeric STRING here (`"5"` passes), so this says less than the runtime allows;
        # it cannot say more, since no `minimum` applies to a JSON string and a pattern cannot carry the bound.
        #
        # Output is not narrowed: there the schema describes what the action produces, and dropping a branch
        # would reject a value axn serialized. It has no bound to drop anyway — `numericality_type_provable?`
        # already stands the whole projection down outbound unless the validator proves the value is numeric.
        def restrict_union_to_bounded_branches!(prop)
          return unless prop[:anyOf].is_a?(Array)

          kept = prop[:anyOf].select do |branch|
            types = Array(branch[:type])
            # The nullability branch stays: a nil is SKIPPED by the validator rather than bounded by it, so
            # dropping it would reject a value the contract admits.
            types.intersect?(NUMERIC_TYPES) || types.include?(NULL_BRANCH[:type])
          end
          return if kept.empty? || kept.size == prop[:anyOf].size

          return prop[:anyOf] = kept unless kept.size == 1

          # One survivor is no longer a union.
          prop.delete(:anyOf)
          prop.merge!(kept.first)
        end

        # Whether any part of this node carries a numeric type — the node's own, or a branch of a union.
        def numeric_node?(prop)
          return true if Array(prop[:type]).intersect?(NUMERIC_TYPES)

          prop[:anyOf].is_a?(Array) && prop[:anyOf].any? { |branch| Array(branch[:type]).intersect?(NUMERIC_TYPES) }
        end

        # A union leaves `prop[:type]` unset and its branches under `anyOf`, so a bound written at the node
        # would sit on nothing. It follows the emitted type into the branches instead — the same shape
        # `apply_member_size_constraints` already gives the size bounds, and the reason a union `length:`
        # reflected while a union `numericality:` silently did not.
        def write_numeric_bound!(prop, key, bound)
          return prop[key] = bound unless prop[:anyOf].is_a?(Array)

          prop[:anyOf] = prop[:anyOf].map do |branch|
            Array(branch[:type]).intersect?(NUMERIC_TYPES) ? branch.merge(key => bound) : branch
          end
        end

        # Emit what a container holds: the `of:` baseline — an Array's `items:`, a Hash map's
        # `additionalProperties:` — and a `shape:`'s typed member contracts as `properties:`.
        # Precedence: shape: enriches/overrides the of: baseline. On an ARRAY the two describe one node from two
        # angles, so the shape's members overwrite the element type's. On a MAP they describe different keys of
        # one object — `properties` beside `additionalProperties` — and neither displaces the other.
        def apply_structured_schema!(prop, config, for_output:, ancestry: nil)
          return unless config.validations[:of] || config.validations[:shape]

          plan = shape_property_plan(config, for_output:, ancestry:)
          # The shape the PLAN carries, never a second read of the config: one answer to which members are
          # emitted here, so a rule charged against the plan and this emission cannot walk different lists.
          shape = plan.shape

          if plan.map?
            # A map's contents land under `additionalProperties` at this very node, so the plan's type schema is
            # merged in whole. Empty for a keys-only map, which merges nothing — `keys:` has no JSON Schema
            # spelling worth emitting (see shape_property_plan).
            prop.merge!(plan.type_schema)
            return unless shape && plan.emitted

            # A shape beside a map names the SAME node's `properties`, which is the one place the two options
            # describe different things: `additionalProperties` governs only the keys `properties` does not
            # match, and the runtime mirrors that by exempting them (Core::Contract#_derive_shaped_keys!).
            # `prop[:type]` is left as `build_property` derived it from `type: Hash` — already `object`, and
            # already carrying the `null` branch where the field admits one.
            member_props, required = member_properties(shape[:members], for_output:, ancestry:)
            prop[:properties] = plan.base_properties.merge(member_props)
            prop[:required] = required unless required.empty?
            prop.replace(exempt_shaped_keys_from_property_names(prop))
          elsif plan.in_items?
            # The plan's own type schema, not a second `contents_schema_for` call: one build, and the plan is
            # then literally what gets emitted rather than a parallel derivation of it.
            items = plan.type_schema
            if shape && plan.emitted
              member_props, required = member_properties(shape[:members], for_output:, ancestry:)
              items = items.merge(type: "object", properties: plan.base_properties.merge(member_props))
              items[:required] = required unless required.empty?
            end
            prop[:items] = items unless items.empty?
          elsif shape
            return unless plan.emitted

            prop[:type] = nil_allowed?(config) ? %w[object null] : "object"
            prop.delete(:format)
            member_props, required = member_properties(shape[:members], for_output:, ancestry:)
            prop[:properties] = plan.base_properties.merge(member_props)
            prop[:required] = required unless required.empty?
          end
        end

        # Whether a config's `shape:` members become object PROPERTIES, at which node, and which property names
        # its declared TYPE contributes alongside them.
        #
        # Single source for the two layers that must agree exactly: `apply_structured_schema!` above, which
        # emits, and `Core::Contract`'s property-claim collector, which rejects a declaration whose emitted
        # property names would collapse onto one. The guard has to claim precisely what is emitted — a claim for
        # a property the schema omits rejects a declaration the author is entitled to write, and a missing claim
        # lets two names collapse silently. A guard that MIRRORED these rules did both at once, so they live
        # here, where the emission decision already lived, and are read rather than restated.
        #
        # `in_items?` distinguishes the two nodes a shape's members can land at: an ARRAY's element properties
        # are their own namespace (a non-object parent's subfields are not emitted there, so nothing else can
        # name a property alongside them), while everything else lands in the field's own `properties`.
        #
        # `emitted` false means the shape contributes no properties at all, for one of four reasons:
        #   - the config is wholly gated on output, so `build_property` leaves it untyped before reaching here;
        #   - the config is a `model:` route on INPUT, where the client sends `<field>_id` and the record's own
        #     structure is never emitted — `build_input` (and the nested analog) emit the id property INSTEAD of
        #     calling `build_property` at all, at top level and at any subfield depth alike;
        #   - a SCALAR `of:` (`of: String` + `field :length`) reads members off the element, which stays a
        #     string — so the members are validated but never become properties;
        #   - on OUTPUT, the value is not provably member-keyed (a custom `as_json`/`to_h` that
        #     `serialize_value` would follow instead), so the property is left untyped rather than promising an
        #     object shape the serializer will not produce.
        #
        # `type_schema` is what the declared TYPE contributes, as the emitter's own Hash: for an array, exactly
        # what `contents_schema_for` seeded from the `of:` element type; for a map, that same seed for the
        # `values:` axis, wrapped in the `additionalProperties` key it lands under; for anything else, a `Data`
        # field's own members. Carried whole rather than reduced to one property list, because the emitter does
        # not put all of it at one node — a multi-class `of:` becomes one `anyOf` BRANCH per element type, each
        # with its own `properties`. `base_properties` is the part that lands at the node itself, which is all the
        # emitter merges the shape's members into; a consumer that must account for EVERY name (the projection
        # size cap) walks the whole schema instead. Reducing this to `base_properties` alone is what let a
        # contract naming 26,000 properties across 26 branches charge zero.
        #
        # `container` is the container an `of:` bag names — `::Array`, `::Hash`, or nil where there is no `of:`
        # at all. It is what tells the two `of:` grammars apart AFTER canonicalization, since a map's bag names
        # its axes (`keys:`/`values:`) where an array's names one element type (`klass:`), and the two land at
        # different nodes. `in_items` is the neighbouring question and not the same one: it asks where a SHAPE's
        # members go, and is answered from the emitted JSON type, so an array with no `of:` still answers true.
        #
        # `shape` is the shape the plan was DERIVED from — the effective one (see effective_validations), which on
        # output is not always the declared one. Carried so that "which members does this emit" has a single
        # answer: `apply_structured_schema!` emits these members, and a rule charged against the plan walks the
        # same list rather than re-reading the config it came from. A plan whose `emitted` is false still carries
        # it (nothing about that decision changes which shape was consulted), so every consumer gates on `emitted`.
        ShapePropertyPlan = Data.define(:emitted, :in_items, :type_schema, :shape, :container) do
          def in_items? = in_items

          # A map puts its `of:` contents under `additionalProperties` at the field's own node. Asked of the
          # container the declaration named rather than of the schema that was built, so a values axis with
          # nothing to say is still recognizably a map.
          def map? = ::Hash.equal?(container)

          def base_properties = type_schema[:properties] || {}
        end

        def shape_property_plan(config, for_output:, ancestry: nil)
          # THE reason the charge and the emitter cannot start from different configs: the effective derivation
          # happens HERE, on the way in, so no caller can hand this a config the emitter would not have used.
          # `build_property` applies the same derivation before it emits, which makes the one here idempotent
          # (nothing left to drop) rather than a second opinion.
          validations = effective_validations(config.validations, for_output:)
          of = validations[:of]
          shape = validations[:shape]
          in_items = Array(json_type_for(validations, for_output:)[:type]).include?("array")
          container = of_container(validations)
          nothing = ShapePropertyPlan.new(emitted: false, in_items:, type_schema: {}, shape:, container:)

          # The same two gates `apply_structured_schema!` opens with, in the same order. A declaration with
          # neither `of:` nor `shape:` contributes no object properties AT ALL — not even its type's own members —
          # so a `Data` used purely as a `type:` names nothing, and a rule keyed on these names must not fire on
          # it. Likewise a wholly gated outbound config, which `build_property` leaves untyped before reaching
          # emission.
          return nothing unless of || shape
          return nothing if for_output && gated_validations?(validations)
          # An INPUT model route emits `<field>_id` in place of the field, so `apply_structured_schema!` is never
          # reached for one — stated here rather than only in the emitter's branch, so a consumer deriving from this
          # plan (the projection size cap; collision attribution) cannot charge or attribute a property the schema
          # names nowhere. On OUTPUT the field itself is emitted, so its shape is emitted with it.
          return nothing if !for_output && validations[:model]

          if in_items
            # Overlay the shape's object properties onto items only when the ELEMENTS are objects.
            emitted = shape_overlay_applies?(of, for_output:)
            # `contents_node_schema` seeds an element type's own members whenever there is an `of:`, shape or not —
            # and, where the element is itself a container, everything inside it too.
            return ShapePropertyPlan.new(emitted:, in_items:, shape:, container:,
                                         type_schema: of ? contents_node_schema(of, for_output:, ancestry:) : {})
          end

          # A map's `of:` names its VALUES, which every JSON object key maps to — so the axis reflects as
          # `additionalProperties` at the field's own node. The `keys:` axis contributes nothing: every JSON
          # object key is a string, so `keys: String` would say nothing a client can act on and `keys: Symbol`
          # would be a lie on the wire. The values schema is the declared TYPE's contribution, charged and
          # emitted regardless of any shape, exactly as an array's items are.
          #
          # `emitted` answers only whether a SHAPE's members become properties here, and beside a map they do:
          # the two options name different keys of one object, so both land at this node. Settled on the same
          # rule the non-array branch settles it on — a client is always expected to send the members, and on
          # OUTPUT they are promised only where the value provably serializes member-keyed.
          if ::Hash.equal?(container)
            return ShapePropertyPlan.new(emitted: !for_output || shape_serializes_to_object?(validations),
                                         in_items:, shape:, container:,
                                         type_schema: map_values_schema(of, for_output:, ancestry:))
          end

          # Only the `elsif shape` branch emits object properties for a non-array, non-map field: `of:` without a
          # shape on such a type reaches neither branch.
          return nothing unless shape

          # A shaped object field IS an object, even when its declared type: (e.g. a Data.define subclass) isn't
          # in TYPE_MAP — on input unconditionally, on output only when the value serializes member-keyed.
          emitted = !for_output || shape_serializes_to_object?(validations)
          type_klass = validations.dig(:type, :klass)
          base = emitted && strict_descendant?(type_klass, ::Data) ? type_klass.members.to_h { |m| [m, {}] } : {}
          # A non-array type contributes at ONE node (a multi-class `type:` reflects as `anyOf` branches of
          # scalar types, which name no properties), so its schema is just those properties.
          ShapePropertyPlan.new(emitted:, in_items:, shape:, container:, type_schema: { properties: base })
        end

        # THE ONE derivation of the validations a projection is BUILT from, and the reason it is a function rather
        # than a step inside `build_property`: a per-validator (nested) gate can skip an INDIVIDUAL check on a
        # given call (`type: { klass: Integer, if: :flag }` with `flag` falsey lets a nonblank wrong-typed value
        # through), so its constraint can't be promised outbound — and every rule DERIVED from what the projection
        # emits has to start from the same reduced view, or it describes a schema the emitter never emits. The
        # projection size cap charged 25,000 properties for a gated `type: SomeData` whose members `build_property`
        # drops before it emits anything, because "exact given the plan" says nothing when the plan's input differs.
        #
        # What survives with EVERY gate closed: entries carrying a gate of their own (entry_self_gated?) drop, ungated
        # entries stay (a gated `inclusion:` alongside an ungated `type:` still emits the type), and
        # declaration-level gate keys stay too (inert to this reduction — a wholly gated outbound config is
        # already left untyped by its own earlier return, in both `build_property` and `shape_property_plan`).
        # INPUT is untouched and returns the SAME Hash: static-maximal is the safe direction there (a gate can
        # only relax enforcement at runtime), and identity is what lets `build_property` skip rebuilding a config.
        def effective_validations(validations, for_output:)
          return validations unless for_output

          effective = validations.reject { |_key, opt| entry_self_gated?(opt) }
          effective.size == validations.size ? validations : effective
        end

        # Whether a shape block should overlay object properties onto an array's items. OUTPUT: each element
        # must provably serialize to a member-keyed object (a plain Data/Struct/Hash `of:`). INPUT: the
        # elements must be object-typed (Hash/`:params`/Data/Struct) or untyped (no `of:` — the client sends
        # objects). A scalar `of:` (String/Integer/…) reads members off the scalar, so it is NOT overlaid.
        # A bag that NAMES no class is the same case as no bag at all — untyped elements, which on input a client
        # sends as objects carrying the shape's members (`of: { shape: … }`, PRO-3166). On OUTPUT it stays
        # unproven, and so unemitted, for the reason any unnamed class does.
        #
        # `of_validations[:klass]` is the raw `of:` bag's own klass, so both this and its OUTPUT twin below read
        # it through `ShapeGraph.type_tokens` rather than `Kernel#Array`.
        def shape_overlay_applies?(of_validations, for_output:)
          return shaped_items_serialize_to_object?(of_validations) if for_output
          return true unless of_validations # untyped elements: client sends objects with the shape members

          klasses = Axn::Internal::ShapeGraph.type_tokens(of_validations[:klass])
          klasses.empty? || klasses.all? { |k| object_typed_element?(k) }
        end

        # Whether an `of:` element type provably serializes to a member-keyed object (output items). Needs `of:`.
        def shaped_items_serialize_to_object?(of_validations)
          return false unless of_validations

          klasses = Axn::Internal::ShapeGraph.type_tokens(of_validations[:klass])
          klasses.any? && klasses.all? { |k| member_keyed_object_type?(k) }
        end

        # The container an `of:` bag names — `::Array` for an element list, `::Hash` for a map, nil where there
        # is no `of:` at all. THE one read of it, so the emitter deciding which node an `of:` lands at and the
        # declaration guard deciding whether a map may carry subfields cannot disagree about what a map is.
        #
        # Read through the same tolerant Hash test the declaration guards use: `of:` is canonicalized into a bag
        # long before either caller, but a config ASSIGNED onto a class can still carry the bare spelling the
        # DSL would have expanded, and asking a String for `[:container]` raises where an honest answer of "no
        # container named" is what both callers want. A `::Hash` answer therefore also PROVES the bag is a Hash,
        # which is what lets the map branches read `[:values]` off it without asking again.
        def of_container(validations)
          bag = Axn::Internal::ShapeGraph.hash_or_nil(validations[:of])
          bag && bag[:container]
        end

        # Whether an element type is an OBJECT on the wire a client sends (input): Hash/`:params`/Data/Struct.
        def object_typed_element?(klass)
          return true if Axn::Internal::Identity.same?(klass, :params)
          return false unless class_token?(klass)

          Axn::Internal::NativeMethods.includes_module?(klass, ::Hash) ||
            strict_descendant?(klass, ::Data) || strict_descendant?(klass, ::Struct)
        end

        def json_type_for(validations, for_output: false)
          if validations[:type]
            tokens = declared_type_tokens(validations)
            type_hashes = tokens.map { |k| single_type_for(k, for_output:) }.uniq
            node = type_hashes.size == 1 ? type_hashes.first : { anyOf: type_hashes }
            return narrow_node_under_numericality(node, validations, tokens, for_output:)
          end

          # Outbound, the SET names a type only where it passes the same equality-safety test the `enum` itself
          # is gated on — one predicate for both emissions, since both turn on whether a member can be `==` to a
          # value that serializes differently. It can: `Integer#==` falls back to `other == self`, so a value
          # object comparing equal to `1` satisfies `inclusion: { in: [1] }` and serializes as its own string,
          # which an inferred `"integer"` then rejects. A String/Symbol/boolean/nil member settles it alone —
          # their `==` never matches a foreign class — while a numeric member asks the position to pin its class,
          # which nothing reaching here has declared (a `type:` returns above, and a bag with a `klass:` takes the
          # other branch), so a numeric set always stands down outbound. Input needs no gate: a set narrower than
          # the runtime's equality is the licensed direction there.
          if validations[:inclusion]
            enum_values = inclusion_enum_values(validations[:inclusion])
            if enum_values&.any? && (!for_output || output_enum_exact?(enum_values, validations, nil))
              types = enum_values.map { |v| enum_scalar_type(v) }.uniq
              return { type: types.first } if types.size == 1 && types.first

              # mixed (or unrecognized) value types → let `enum` constrain; emit no `type`
              return {}
            end
          end

          if (numericality = validations[:numericality]) && numericality_type_provable?(numericality, for_output:)
            return { type: "integer" } if Axn::Validation::Base.declared_only_integer?(numericality)

            return { type: "number" }
          end

          {}
        end

        # A `numericality:` entry reaches a node's branches four different ways, and each is decided from the
        # DECLARED token rather than from the emitted type alone — reading the type alone retagged branches no
        # value of the declared class can occupy.
        #
        #   a non-numeric type  drops, under EVERY spelling of the validator. `is_number?` runs before any
        #                       option is read, so no Array, Hash or boolean can satisfy it.
        #   a "number" branch   narrows to "integer" under `only_integer:`, and only where some declared token
        #                       ADMITS an Integer (`Numeric` does; `Float` does not). Retagging a Float branch
        #                       advertised the JSON integer `2`, which `is_a?(Float)` rejects — and no Float
        #                       satisfies `only_integer:` anyway (`2.0.to_s` is "2.0"), so the branch is
        #                       unreachable and drops out.
        #   a "string" branch   drops under `only_numeric:`, which demands a Numeric OBJECT. Otherwise it stays
        #                       — the validator parses a numeric STRING — and carries ActiveModel's own integer
        #                       test translated where `only_integer:` gives it one, so `"2"` passes where `"abc"`
        #                       does not and leaving the branch unconstrained advertised both.
        #   anything else       is left exactly as built.
        #
        # Narrowing both branches of `[Integer, Float]` converges them, so the node collapses; deduping is a
        # CONSEQUENCE of that convergence and never a tidy-up of its own, so a union that narrows nothing comes
        # back untouched, duplicate branches included.
        def narrow_node_under_numericality(node, validations, tokens, for_output:)
          entry = Axn::Validation::Base.validator_entries(validations)[:numericality]
          return node unless entry

          # The ENTRY's presence is the whole gate, and the two options below decide only what they alone can.
          # ActiveModel asks `is_number?` before it reads any option, and `only_numeric:` is one more restriction
          # INSIDE that check rather than the thing that establishes it — so no spelling of the validator can be
          # satisfied by a value that does not parse as a number, and a branch naming such values is unreachable
          # under all of them. Gating the pass on the options instead left the branch standing wherever neither
          # was given: `type: [TrueClass, Integer], numericality: true` accepts neither boolean and advertised
          # both. What the options still decide is the string branch (`only_numeric:` alone can drop it) and the
          # retag of a numeric branch to "integer" (`only_integer:`).
          # Resolved across BOTH tiers, the way `validates` builds a validator's options
          # (`defaults.merge(_parse_validates_options(options))`): a declaration-level `optional:`/`allow_blank:`
          # is recorded once on the declaration rather than copied into each entry, so an entry-only read answers
          # a field's tolerance wrongly. Every other tolerance judgment here goes through this same seam
          # (`presence_rejects_blank?`, `declared_size_minimum`), which is what keeps the branch and the size
          # floor from disagreeing about one declaration.
          options = Axn::Validation::Base.effective_entry_options(entry, Axn::Validation::Base.shared_validation_options(validations))
          only_integer = Axn::Validation::Base.declared_only_integer?(entry)
          numeric_only = options[:only_numeric] ? true : false
          # A tolerated BLANK never reaches the validator at all — ActiveModel skips a blank value before
          # `is_number?` runs — so a branch the numeric check excludes may still be occupied by its own blank,
          # and dropping it outright refused output the action produced (`type: :boolean, numericality:
          # { allow_blank: true }` exposes `false` successfully). Read off the options resolved above, so the
          # declaration-level `optional:` and an entry's own `allow_blank:` are covered by one read. Truthiness is
          # the whole test, exactly as it is for `only_numeric:` — ActiveModel reads `options[:allow_blank]` truthily
          # rather than resolving it per call, so a Proc tolerates a blank on every call.
          blank_tolerated = options[:allow_blank] ? true : false
          # Skipping the validator is only half of it: the value still has to get PAST the position. A required
          # position rejects an empty container on its own, so `type: [Array, Integer], numericality:
          # { allow_blank: true }` admits no `[]` however blank-tolerant the entry is, and treating the entry's
          # tolerance as the whole answer emitted a branch nothing satisfies (`enum: [[]]` beside the `minItems: 1`
          # the same declaration writes). This is the very predicate the size FLOOR is derived from, so the branch
          # and the floor cannot disagree about one declaration. It governs the EMPTY witnesses only — `false` is
          # blank without being empty, which is why a required `:boolean` really does expose it.
          empty_rejected = empty_value_rejected?(validations)

          union = node[:anyOf].is_a?(Array)
          admits = integer_admitted_by?(tokens)
          branches = union ? node[:anyOf] : [node]
          # A branch may only be DROPPED where the declared tokens prove no Numeric can occupy the position.
          # See `numeric_reachable_through_broad_token?` — the emitted type is not evidence on its own.
          drop = !numeric_reachable_through_broad_token?(tokens)
          mapped = branches.filter_map do |branch|
            numericality_branch(branch, admits, numeric_only:, only_integer:, for_output:, drop:, blank_tolerated:,
                                                empty_rejected:)
          end
          # Every branch dropping is the CONTRACT, not a case to fall back from: `type: Float, numericality:
          # { only_integer: true }` admits nothing at all — no Float's `to_s` is an integer literal, and a JSON
          # integer is not a Float — so restoring the node advertised `1.5` at a position that rejects it. A node
          # nothing satisfies is the faithful projection here, on the same terms two disagreeing `equal_to:`
          # bounds already emit `enum: []`. Refusing the declaration outright stays PRO-3220's.
          return { enum: EMPTY_ENUM } if mapped.empty?
          return node if mapped == branches

          deduped = mapped.uniq
          return deduped.first if deduped.size == 1

          union ? node.merge(anyOf: deduped) : node
        end

        # What each narrowing does to ONE branch. `only_numeric:` is the blunter of the two: it makes ActiveModel
        # demand a Numeric OBJECT rather than parse anything, so every branch naming values that are not Numerics
        # is unreachable — a string branch (the one that existed to carry `"2"`), and equally an array, object or
        # boolean branch, each measured as rejected. `only_integer:` is the finer one, retagging a numeric branch
        # and translating ActiveModel's integer test onto a string branch that survived.
        #
        # The `"null"` branch is exempt from both, and not by omission: NULLABILITY owns it. ActiveModel skips a
        # nil before any validator sees it wherever the field tolerates one, so neither option says anything
        # about nil — measured, `type: [String, Integer, NilClass], numericality: { only_numeric: true },
        # optional: true` accepts nil while rejecting every String.
        # Whether some declared token is a SUPERTYPE of Numeric — `Object`, `Comparable`, `Kernel`. Such a token
        # admits a Numeric value while `single_type_for` renders it APPROXIMATELY (`type: Object` emits a
        # `"string"` branch), so that branch's emitted type says nothing about what the position holds, and
        # dropping it as "names non-Numerics" emptied a contract `1` satisfies: `type: Object, numericality:
        # { only_numeric: true }` went to `enum: []` while accepting the Integer.
        #
        # The same lesson as the untyped branch above, one step further: an ABSENT type is not evidence, and
        # neither is an APPROXIMATE one. A token that is itself numeric is excluded — it emits a numeric branch,
        # which this pass narrows rather than drops.
        def numeric_reachable_through_broad_token?(tokens)
          tokens.any? do |token|
            next false unless Internal::Identity.kind?(token, ::Module)

            Internal::NativeMethods.includes_module?(::Numeric, token) &&
              !Internal::NativeMethods.includes_module?(token, ::Numeric)
          end
        end

        def numericality_branch(branch, admits_integer, numeric_only:, only_integer:, for_output:, drop: true, blank_tolerated: false,
                                empty_rejected: false)
          # A branch `only_numeric:` may drop is one whose emitted type NAMES values that are not Numerics.
          # Everything else is left exactly as built — including the `"null"` branch nullability owns, a branch
          # already tagged `"integer"`, and any branch whose type is ABSENT. That last is load-bearing: a missing
          # type is not evidence of anything. `type: Numeric` deliberately emits `{}` on output, its values
          # having more than one wire form, and reading that absence as proof emptied a position the action
          # satisfies with `1` — the schema rejecting output it had produced.
          # EVERY spelling of the validator drops it, which is why no option is consulted here: `is_number?` runs
          # before any of them, and no Array, Hash or boolean survives it — `[1].to_s` is `"[1]"` and `true.to_s`
          # is `"true"`, neither a numeric literal. Reading the options here left `of: { klass: :boolean,
          # numericality: true }` advertising an element the validator rejects on every call. The test stays on
          # types that NAME non-Numerics; an absent or unrecognized type still falls through to "keep".
          #
          # Exact for a boolean: `Class.new(TrueClass)` is legal and can never be instantiated (`new` AND
          # `allocate` both raise), so no value of a `"boolean"` branch is anything but `true`/`false`. For the
          # containers it rests on the same footing every spelling has always stood on — a subclass
          # reimplementing BOTH `to_s` and `to_i` to impersonate a number does satisfy the validator, and one
          # overriding `to_s` alone raises inside ActiveModel rather than passing.
          if NON_NUMERIC_BRANCH_TYPES.include?(branch[:type])
            return drop ? blank_witness_branch(branch, blank_tolerated, empty_rejected) : branch
          end

          case branch[:type]
          when "number" then only_integer ? number_branch_as_integer(branch, admits_integer) : branch
          when "string" then string_branch_under_numericality(branch, numeric_only:, only_integer:, for_output:, drop:)
          else branch
          end
        end

        # The emitted types that name values no Numeric can be, and so the only branches `only_numeric:` may
        # drop. Listed rather than derived by exclusion for exactly the reason above — an absent or unrecognized
        # type has to fall through to "keep", not to "drop".
        NON_NUMERIC_BRANCH_TYPES = %w[array object boolean].freeze
        private_constant :NON_NUMERIC_BRANCH_TYPES

        # The one blank each of those types can hold. Every branch the numeric check excludes has exactly one, so
        # a blank-tolerant position narrows the branch TO it rather than losing the branch: the result names the
        # only value that can occupy the position there, which is right in both directions at once — outbound it
        # accepts the blank the action can expose, inbound it accepts nothing else, and the runtime agrees on
        # both counts. `enum` is the spelling because a singleton boolean branch already uses it (`TrueClass`
        # emits `enum: [true]`) and because `merge_enum!` composes it by intersection.
        #
        # Each witness is FROZEN, on the same terms `EMPTY_ENUM` and `NULL_BRANCH` already are: this value is
        # handed to a consumer inside a schema, schemas are rebuilt per call and caller-mutable, and a shared
        # mutable `[]`/`{}` let one consumer's mutation reach every schema the process emitted afterwards —
        # measured, appending to one action's witness changed a DIFFERENT action class's `enum` to `[[99]]`.
        # Freezing rather than copying is what the neighbours do and buys the same property (AGENTS.md: an
        # already-frozen container needs no copy), with the difference that a mutating consumer now gets a
        # FrozenError instead of silently corrupting every later schema.
        BLANK_BRANCH_WITNESS = { "array" => [].freeze, "object" => {}.freeze, "boolean" => false }.freeze
        private_constant :BLANK_BRANCH_WITNESS

        # `nil` — drop the branch — wherever no tolerated blank can occupy it. Two ways that happens: the
        # position tolerates no blank at all, or the branch already names values that exclude this type's blank.
        # The second is the `TrueClass` case and it matters: its branch is `enum: [true]`, and `true` is not
        # blank, so nothing skips the validator there and the branch really is unreachable — while `FalseClass`
        # names `false`, which is, and survives.
        def blank_witness_branch(branch, blank_tolerated, empty_rejected)
          return nil unless blank_tolerated
          return nil unless BLANK_BRANCH_WITNESS.key?(branch[:type])

          witness = BLANK_BRANCH_WITNESS.fetch(branch[:type])
          # An EMPTY witness has to clear the position's own emptiness check, and so does an explicitly-named
          # `false`. The one exemption is the `:boolean` pseudo-type, whose blank a REQUIRED position really does
          # admit — measured, `expects :n, type: :boolean` accepts `false`, while `type: FalseClass` accepts
          # nothing at all — and its branch is the one carrying no `enum`, a `FalseClass` branch naming `[false]`
          # explicitly.
          return nil if empty_rejected && !(false.equal?(witness) && branch[:enum].nil?)

          existing = branch[:enum]
          return nil if existing && !existing.include?(witness)

          branch.merge(enum: [witness])
        end

        # A numeric branch under `only_integer:`: retagged where some declared token admits an Integer, and
        # dropped where none does — no Float satisfies the option (`2.0.to_s` is "2.0"), so the branch is
        # unreachable rather than merely narrower.
        def number_branch_as_integer(branch, admits_integer) = admits_integer ? branch.merge(type: "integer") : nil

        def string_branch_under_numericality(branch, numeric_only:, only_integer:, for_output:, drop: true)
          return nil if numeric_only && drop
          return branch unless only_integer

          merge_integer_literal_pattern(branch, for_output:)
        end

        def merge_integer_literal_pattern(branch, for_output:)
          source = Pattern.ecma_source(Axn::Validation::Base.integer_literal_regexp, for_output:)
          return branch unless source

          composed = branch.dup
          write_pattern!(composed, source)
          composed
        end

        # Whether the position's numbers reach the wire unchanged. A Ruby Integer and Float serialize exactly;
        # every other Numeric is rendered through `Float()`, which ROUNDS — `BigDecimal("0.099999999999999999")`
        # satisfies `less_than: 0.1` and then serializes AS `0.1`, which the emitted `exclusiveMaximum` rejects.
        # A bound is outbound-honest only where that rounding cannot happen.
        def numeric_serialization_exact?(tokens)
          return false if tokens.empty?

          tokens.all? do |token|
            Internal::Identity.same?(token, ::Integer) || Internal::Identity.same?(token, ::Float)
          end
        end

        # Whether a JSON integer could satisfy any of the declared tokens. Asked of Integer's OWN ancestry, the
        # undispatched form, for the reason the key-axis gates give. No declared token at all means the caller is
        # not describing a class union, and the narrowing behaves as it did before this distinction existed.
        def integer_admitted_by?(tokens)
          return true if tokens.empty?

          tokens.any? do |token|
            Internal::Identity.kind?(token, ::Module) && Internal::NativeMethods.includes_module?(::Integer, token)
          end
        end

        # Whether a `numericality:` entry proves the value will SERIALIZE as a JSON number. Two different
        # things can stop it, and it takes both options to exclude them.
        #
        # ActiveModel accepts a numeric STRING unless `only_numeric: true` is given — `"1"` passes
        # `greater_than: 0`, and passes `only_integer:` too, since that reads the string form — so an exposed
        # value may well be a String. And `only_numeric:` alone proves only that the value is a NUMERIC, which
        # is not the same as a JSON number: `Complex(1, 2)` is a Numeric and serializes as `"1+2i"`, so the
        # inferred `"number"` rejected output the action had produced successfully.
        #
        # `only_integer:` is what excludes it, and excludes it exactly: among Numerics only an Integer's `#to_s`
        # is an integer literal (a Float's carries `.`, a Rational's `/`, a BigDecimal's `e`, a Complex's `i`),
        # so the two options together pin the value to an Integer and the emitted type is "integer" rather than
        # "number". It has to be a STATIC `only_integer:`, which is exactly what `declared_only_integer?` asks;
        # `only_numeric:` needs no such test, being the one option here ActiveModel reads truthily instead of
        # resolving per call.
        #
        # On INPUT none of this applies: an inferred numeric type is merely STRICTER there, which is licensed —
        # a client is told to send `1` rather than `"1"`, and the runtime would have taken either. A declared
        # `type:` is unaffected in both directions, being read before this and proving the class itself.
        def numericality_type_provable?(numericality, for_output:)
          return true unless for_output
          return false unless Axn::Validation::Base.validator_entry_options(numericality)[:only_numeric]

          Axn::Validation::Base.declared_only_integer?(numericality)
        end

        def enum_scalar_type(value)
          return "string" if value.is_a?(String)
          return "integer" if value.is_a?(Integer)
          return "number" if value.is_a?(Float)

          nil
        end
      end
    end
  end
end
