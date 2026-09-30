# frozen_string_literal: true

require "date"
require "time"
require "bigdecimal"
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

# Merge conjoins two emitted properties that meet at one wire position — every collision the builder finds.
require "axn/internal/reflection/schema/merge"

# Requiredness decides whether a position may be omitted or be null — the `required` list and every nullability.
require "axn/internal/reflection/schema/requiredness"

# Nesting walks a subfield tree into its parent's property, reading Requiredness's annotations and handing each
# collision to Merge.
require "axn/internal/reflection/schema/nesting"

# RenderGuards builds the render-time position map (PRO-3284) — reuses this module's own emission
# predicates rather than re-deriving them, so it must load after everything it calls.
require "axn/internal/reflection/schema/render_guards"

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
      # fails at runtime (as is a Proc default, which reflection cannot run). Requiredness is exact in both
      # directions otherwise; this looser case only arises from a self-contradictory contract and surfaces as
      # a normal, recoverable validation error. A required subfield at ANY depth forces its whole ancestor chain
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

        # A constraint the contract enforces and the emitted document cannot state, recorded where it is
        # declined so the gap is reported rather than silent. `summary` is one clause naming what still
        # applies ("must equal 5 after coercion to Integer"); `kind` separates a limit of JSON Schema
        # itself (`:inherent`) from one axn has simply not taught the emitter yet (`:unfixed`), so the
        # audit's exclusion list can shrink as the latter are closed and can never silently grow.
        #
        # `per_type` marks a report `report_unexpressed_checks` derived from the property's surviving JSON types.
        # A collision recomputes those against the combined node (`project_collision_checks`), where the types
        # may have narrowed, so a side's own copies are dropped rather than carried: a `length:` unstatable on
        # an untyped side is fully stated once the conjunction narrows it to a String.
        Residue = Data.define(:summary, :kind, :per_type) do
          def initialize(summary:, kind:, per_type: false) = super
        end

        RESIDUE_PREFACE = "Additional constraints apply that JSON Schema cannot express: "

        # The container reads the residue reduction makes, held UNBOUND. Exact class is not enough on its
        # own: an exact Array or Hash can still carry a singleton `map`/`each_pair`, so the reduction reaches
        # for Array's and Hash's own.
        MENTIONABLE_MAP = ::Array.instance_method(:map)
        MENTIONABLE_EACH_PAIR = ::Hash.instance_method(:each_pair)
        SAME_STRING = ::String.instance_method(:==)
        ARRAY_SIZE = ::Array.instance_method(:size)
        ARRAY_AT = ::Array.instance_method(:[])
        HASH_TO_A = ::Hash.instance_method(:to_a)
        private_constant :MENTIONABLE_MAP, :MENTIONABLE_EACH_PAIR

        # PRO-3441. A map's `of: { values: }` axis governs every key `properties` does NOT itself name
        # (`additionalProperties`'s own JSON Schema meaning) — except the keys the axis's OWN `shape:`
        # names, which `_derive_shaped_keys!` exempts because the runtime does (`of_validator.rb`'s
        # `shaped_keys:` skip). A key `properties` names for a DIFFERENT reason — a colliding shape member,
        # a node's own explicit child, a dotted `on:` reaching through it — is not in that exempt set, so
        # the axis still enforces it at runtime, but nothing conjoined its schema there: `additionalProperties`
        # only ever governs KEYS IT DOESN'T MATCH, so a value the axis would refuse sailed through the
        # `properties` entry unchecked.
        #
        # A declaration-time guard used to refuse this outright (`check_subfields_under_map!`, since
        # removed) — but only within ONE declaration (a subfield reading through a config that also
        # declares `of:`); it could never see a NAME arriving from a DIFFERENT declaration at the same
        # wire position — a colliding shape member's `of:` beside a node's own child, or a shape member's
        # named key beside a node's own `of:` — since a shape member is invisible to the subfield tree
        # that guard walked. This emits the honest document instead of refusing the declaration.
        #
        # `map_values_schema` (`Vocabulary::MAP_VALUE_EXEMPT_KEY`) cannot conjoin the axis into `properties`
        # itself: at a merged node, the keys a colliding declaration or a later `apply_nested_subfields!`
        # pass adds are not there yet — nesting is layered on AFTER a shape member's own map axis is built.
        # So this rides on the property, under that key, as a LIST of `{schema:, exempt:}` pairs (a merged
        # node can carry more than one `of:` axis — `merge_shape_member_property`'s existing
        # `additionalProperties` conjunction), until `finalize_residues!`'s own whole-tree descent — the one
        # pass every property, at any depth, newly-added or original, is guaranteed to still be present for
        # — conjoins each pair into every `properties` entry its own `exempt` set does not name, and strips
        # the key. The same "ride until the one pass that sees everything, then strip" shape `RESIDUE_KEY`
        # already uses, for the same reason: nothing earlier in the build can promise it has seen the FINAL
        # `properties` map.

        # Metadata is not a validator contribution. In particular, a default applies independently
        # of validator gates and must never be included in a conditional fragment.
        SIBLING_DEPENDENT_KEYWORDS = %i[additionalProperties].freeze
        RESIDUE_UNGATEABLE_KEYS = [:description, :default, Vocabulary::RESIDUE_KEY, Vocabulary::MAP_VALUE_EXEMPT_KEY].freeze

        PROC_DEFAULT_RESIDUE = "its `default:` is computed on the call when it is omitted, and the computed value must " \
                               "still pass this contract"

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
        extend Merge
        extend Requiredness
        extend Nesting
        extend RenderGuards

        module_function

        # Attach a residue to the property it qualifies, returning the property. Deduplicated by summary —
        # a collision judged at two depths reports the same clause once.
        def record_residue(prop, summary, kind: :inherent, per_type: false)
          return prop if summary.nil?

          existing = prop[RESIDUE_KEY] || []
          return prop if existing.any? { |r| r.summary == summary }

          prop.merge(RESIDUE_KEY => existing + [Residue.new(summary:, kind:, per_type:)])
        end

        # A side's residues as a collision carries them: its per-type reports are recomputed on the combined
        # node instead (see `Residue`).
        def carried_residues(prop) = residues_on(prop).reject(&:per_type)

        def residues_on(prop) = prop.is_a?(::Hash) ? (prop[RESIDUE_KEY] || []) : []

        # Render every residue in a finished schema into its property's `description` and strip the
        # carrier key, collecting `[path, residue]` pairs for the once-per-class warning. The rendering
        # APPENDS: an author's own `description:` is the field's documentation and this is a footnote to
        # it, never a replacement.
        #
        # A FROZEN node is skipped whole: the emitter hands out shared frozen constants for the fixed
        # shapes (NULL_BRANCH, EMPTY_ENUM) and for the witnesses a consumer must not be able to mutate
        # into another action's schema, and none of them can carry a residue — so descending into one
        # could only ever raise. With copy: true, detach only schema nodes and their child maps/lists;
        # default/enum/const literals remain data and are neither traversed nor mutated.
        def finalize_residues!(schema, path: [], collected: [], copy: false)
          return [schema, collected] unless schema.is_a?(::Hash)
          return [schema, collected] if schema.frozen?

          schema = schema.dup if copy
          residues = schema.delete(RESIDUE_KEY)
          if residues&.any?
            residues.each { |r| collected << [path.dup, r] }
            clause = "#{RESIDUE_PREFACE}#{residues.map(&:summary).join('; ')}."
            # Each part is rendered BEFORE the join. An author's `description:` is caller-supplied text and
            # may be valid in an encoding this generated prose cannot concatenate with (a UTF-16 String
            # raises outright); joining first and rendering after would raise from inside the composition.
            schema[:description] = join_prose(as_sentence(schema[:description]), clause)
          end

          # PRO-3441. This node's own `properties` is now FINAL — every subfield, colliding member and
          # dotted `on:` child this position will ever hold has already been added by every earlier pass —
          # so this is the one place a map's `of: { values: }` axis can be conjoined into a NAMED key that
          # arrived from somewhere other than the axis's own `shape:` (see `MAP_VALUE_EXEMPT_KEY`).
          map_value_axes = schema.delete(MAP_VALUE_EXEMPT_KEY)

          # Only the keywords that HOLD a subschema are descended into. Walking every Hash and Array
          # instead reaches a declaration's own literals — a `default:`/`enum:`/`const:` value is the
          # author's data, not a node — and a literal `{ __axn_residues: [...] }` there was deleted and
          # then read as residues, raising `NoMethodError` on a String mid-reflection. The three shapes
          # below are the ones this emitter actually writes; a keyword it does not emit is not listed,
          # since a position nothing writes is one nothing has to be protected from.
          SUBSCHEMA_MAPS.each do |key|
            node = schema[key]
            next unless node.is_a?(::Hash)

            node = conjoin_map_value_axes(node, map_value_axes) if map_value_axes
            # The segment is carried RAW, never rendered here: a declared name is caller-supplied and
            # reflection may not dispatch on one (a `to_s` that raises took the whole reflection down
            # once already, and one that counts its calls sees this walk as a second ask). Whoever
            # reports a residue renders the path through PropertyNames' own escaping labeler.
            node = node.dup if copy && !map_value_axes
            node.each { |name, sub| node[name] = finalize_residues!(sub, path: path + [name], collected:, copy:).first }
            schema[key] = node
          end

          SUBSCHEMA_NODES.each do |key|
            schema[key] = finalize_residues!(schema[key], path:, collected:, copy:).first if schema.key?(key)
          end

          SUBSCHEMA_LISTS.each do |key|
            node = schema[key]
            next unless node.is_a?(::Array)

            schema[key] = node.map { |sub| finalize_residues!(sub, path:, collected:, copy:).first }
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
                id_type = reconciled_model_id_type_token([config])
                _, id_prop = model_id_property(config, id_type)
                properties[id_field] ||= id_prop
              end
            else
              prop = build_property(config)
              apply_nested_subfields!(prop, node, ann)
              prop = emitted_input_property(prop, config)

              properties[config.field] = prop.compact
              unless field_optional?(config, node.children, ann)
                properties[config.field] = apply_field_requiredness!(properties[config.field], config, tree, node, ann, klass,
                                                                     required:, conditionals:)
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
        # Every route contributes, because every route is ENFORCED and a non-nestable member on any of them must
        # block whether or not it is emitted.
        def merged_shape_members(node, key, carried)
          child = node.children[key]
          return NO_SHAPE_MEMBERS unless child

          members = shape_members_at(carried.empty? ? node.configs : node.configs + carried, key)
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

        # Every `shape:` member declared at `key` across the node's own configs AND the members carried from
        # a shallower hop — via shape_members_at, the same locator emission uses, so the two sides can't
        # disagree on which members collide with the implicit child at `key`.
        def colliding_shape_members(node, key, carried)
          return shape_members_at(node.configs, key) if carried.empty?

          shape_members_at(node.configs + carried, key)
        end

        private_class_method :compute_dropped, :blocking_ancestor?, :merged_shape_members, :colliding_shape_members,
                             :merged_explicit_members

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

        # Only type assertions are needed here, not a satisfiability prover. Ignoring enum, not,
        # and value bounds can add a scoped warning, never remove a constraint or reject a call.
        # Number includes integers in JSON Schema, so expand it before intersecting assertions.
        def projected_types(prop)
          universe = WIRE_TYPE_CONTEXTS.flat_map { |token| Array(single_type_for(token, for_output: false)[:type]) }.uniq
          types = prop[:type] ? Array(prop[:type]) : universe
          types |= ["integer"] if types.include?("number")
          types &= prop[:anyOf].flat_map { |branch| projected_types(branch) } if prop[:anyOf]
          Array(prop[:allOf]).each { |branch| types &= projected_types(branch) }
          types
        end

        # Length and format can validate a non-string's Ruby string form. Their JSON keywords
        # cannot: ask their actual emitters per surviving type rather than assume a keyword
        # somewhere in an anyOf covers every branch. Numeric bounds likewise cannot constrain
        # numeric strings; enum/const constraints apply to all JSON types.
        # Absence is exact on non-strings through project_collision_checks; strings and gated
        # absence still need a report rather than a different interpretation of blankness.
        PER_TYPE_REPORTED_KEYS = (%i[length format absence] + NUMERIC_BOUND_ENTRIES.keys).freeze

        def report_unexpressed_checks(prop, configs)
          keys = PER_TYPE_REPORTED_KEYS
          sources = configs.select { |config| keys.any? { |key| config.validations[key] } }
          return prop if sources.empty?

          types = projected_types(prop)
          sources.reduce(prop) do |projected, config|
            applicable_types = nil_allowed?(config) ? types - ["null"] : types
            Axn::Validation::Base.validator_entries(config.validations).slice(*keys).reduce(projected) do |reported, (key, options)|
              if NUMERIC_BOUND_ENTRIES.key?(key)
                bounds = Axn::Validation::Base.declared_numeric_bounds(options, ranged: NUMERIC_BOUND_ENTRIES.fetch(key))
                next reported if bounds.empty?
              end
              conditional = Axn::Validation::Base.entry_effectively_gated?(options, declaration_gates(config))
              missing = applicable_types.reject do |type|
                key == :absence ? !conditional && type != "string" : value_check_emitted?(type, key, options)
              end
              next reported if missing.empty?

              prefix = conditional ? "#{GATED_RESIDUE}; " : ""
              prefix += "after transformation, " if definitely_transforms_wire_value?([config])
              subject = key == :absence ? "blankness" : "the runtime value or its string form"
              record_residue(reported, "#{prefix}#{key} checks #{subject} for #{missing.join(', ')} values; " \
                                       "JSON Schema cannot fully express this check " \
                                       "(#{render_constraint({ key => reported_options(options) })})",
                             kind: conditional ? :conditional : :inherent, per_type: true)
            end
          end
        end

        # A gate is a Proc or method name, not a constraint: rendering one puts an object address into the
        # document. The residue's prefix already says the check is conditional.
        def ungated_options(options)
          return options unless Axn::Internal::Identity.kind?(options, ::Hash)

          options.except(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
        end

        # An entry's options as a residue renders them: the check, not the exemptions around it. A tolerance is
        # pushed into every entry from the declaration (`optional:` → `allow_nil`/`allow_blank`), and the node's own
        # nullability already says what it admits, so repeating it in each sentence only buries the constraint. An
        # entry left with no option of its own reads as the bare switch it is.
        def reported_options(options)
          options = ungated_options(options)
          return options unless Axn::Internal::Identity.kind?(options, ::Hash)

          options = options.except(:allow_nil, :allow_blank)
          options.empty? ? true : options
        end

        # Whether the value these configs check is certainly not the wire value — a `preprocess:`, or a type that
        # opts into coercion itself. A coercible type that says nothing is checked as sent unless the action turns
        # `coerce_input_types` on, which is also the reading its emitted `type` rests on, so residue prose does not
        # qualify every Integer's check with a transformation that by default never happens.
        def definitely_transforms_wire_value?(configs)
          configs.any? do |config|
            next false unless config.respond_to?(:preprocess)
            next true if config.preprocess

            type_opt = config.validations[:type]
            Axn::Internal::Identity.kind?(type_opt, ::Hash) && type_opt[:coerce] == true &&
              !Axn::Internal::Coercion.coercible_klasses(type_opt).empty?
          end
        end

        # Asks whether this TYPE can carry the check's keyword at all, so a tolerance is left out: whether a blank
        # stands the check aside is the property's question (`declared_size_minimum`), not the keyword's.
        def value_check_emitted?(type, key, options)
          prop = { type: }
          options = options.except(:allow_blank, :allow_nil) if Axn::Internal::Identity.kind?(options, ::Hash)
          validations = { key => options }
          case key
          when :length then apply_size_constraints!(prop, validations)
          when :format then apply_pattern!(prop, validations, for_output: false)
          else apply_numeric_bounds!(prop, validations, nullable: false, for_output: false)
          end
          prop.keys != [:type]
        end

        # Every entry that runs on every call, and no gate key: an entry a declaration gate reaches is dropped,
        # so what is left is ungated whether or not the gate keys ride along — and leaving them would have
        # `build_property` read the survivors as gated all over again. The declaration's other shared options
        # (`allow_nil:`/`allow_blank:`/`strict:`) are not entries and are never judged as one: they govern how
        # every surviving entry runs, and dropping them turned an `optional:` field non-nullable.
        def ungated_validations(config)
          gates = declaration_gates(config)
          shared = Axn::Validation::Base.shared_validation_option_keys
          config.validations.reject do |key, opt|
            next true if Internal::FieldConfig::CONDITIONAL_GATE_KEYS.include?(key)
            next false if shared.include?(key)

            Axn::Validation::Base.entry_effectively_gated?(opt, gates)
          end
        end

        # Project each gated validator in isolation. Comparing full and ungated schemas confuses
        # composition with ownership: two patterns become allOf, while one remains a plain pattern.
        # No unconditional validator participates in the fragment reported here.
        #
        # A pair the `enforced` node already states on every call is not a gap, whatever else also
        # contributed it conditionally, so it is left out — and a fragment left empty reports nothing.
        # Only for a config that judges the wire value: after a transform, the fragment describes a
        # different value from the one the node constrains.
        def gating_residues(configs, enforced: {})
          configs.flat_map do |config|
            transforms = transforms_wire_value?([config])
            stated = transforms ? {} : enforced
            gates = declaration_gates(config)
            shared = shared_validation_options(config.validations)
            Axn::Validation::Base.validator_entries(config.validations).filter_map do |key, opt|
              next unless Axn::Validation::Base.entry_effectively_gated?(opt, gates)

              context = shared.except(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
                              .merge(config.validations.slice(:type).transform_values { |type| ungated_options(type) })
              context = context.except(:type) if key == :type
              baseline = build_property(config.with(validations: context), subfield: true)
              fragment = build_property(config.with(validations: context.merge(key => ungated_options(opt))), subfield: true)
              fragment = fragment.except(*RESIDUE_UNGATEABLE_KEYS).reject { |name, value| same_schema_value?(baseline[name], value) }
              # A check no keyword states even with its gate open is still left out, so it is named — unless it is
              # one `report_unexpressed_checks` already names per surviving type, which runs over the same declared
              # entries wherever this does. It is named in `report_unstated_checks`' own words, so where both passes
              # run (a field's own property) `record_residue` keeps one, and a callable is never rendered.
              if fragment.empty?
                next if PER_TYPE_REPORTED_KEYS.include?(key)

                next Residue.new(summary: gated_unstated_summary(config, key, opt), kind: :conditional)
              end
              fragment = fragment.reject { |name, value| unconditionally_enforced?(stated, name, value) }
              next if fragment.empty?

              phase = definitely_transforms_wire_value?([config]) ? "after transformation, " : ""
              Residue.new(summary: "#{phase}#{GATED_RESIDUE} (#{render_constraint(fragment)})", kind: :conditional)
            end
          end
        end

        # Whether `node` asserts `name: value` on every call: at its top level, or in any `allOf` conjunct.
        # An `anyOf` branch asserts nothing on its own. A keyword whose reach depends on its siblings is
        # never matched: `additionalProperties` constrains the keys nothing else names, and a values axis
        # also reaches named keys outside its own `shape:`, so equal spellings can govern different keys.
        def unconditionally_enforced?(node, name, value)
          return false unless node.is_a?(::Hash)
          return false if SIBLING_DEPENDENT_KEYWORDS.include?(name)
          return true if node.key?(name) && same_schema_value?(node[name], value)

          Array(node[:allOf]).any? { |conjunct| unconditionally_enforced?(conjunct, name, value) }
        end

        # Equality of two schema values that neither loses information nor asks a caller's literal anything.
        # Rendering would do the first (`Float::INFINITY` and `"Infinity"` render alike) and `==` the second.
        # Primitives compare by exact class and value, a NaN matching itself; exact containers compare
        # positionally through their own unbound methods; anything else is equal only to itself. A false
        # "different" costs a redundant report; a false "same" would hide a real one.
        def same_schema_value?(one, other)
          return true if Axn::Internal::Identity.same?(one, other)

          klass = Axn::Internal::Identity.class_of(one)
          Axn::Internal::Identity.same?(klass, Axn::Internal::Identity.class_of(other)) && same_instance_value?(klass, one, other)
        end

        def same_instance_value?(klass, one, other)
          if Axn::Internal::Identity.same?(klass, ::Integer) then one == other
          elsif Axn::Internal::Identity.same?(klass, ::Float) then one == other || (one.nan? && other.nan?)
          elsif Axn::Internal::Identity.same?(klass, ::String) then SAME_STRING.bind_call(one, other)
          elsif Axn::Internal::Identity.same?(klass, ::Array) then same_elements?(one, other)
          elsif Axn::Internal::Identity.same?(klass, ::Hash) then same_elements?(HASH_TO_A.bind_call(one), HASH_TO_A.bind_call(other))
          else
            false
          end
        end

        def same_elements?(one, other)
          size = ARRAY_SIZE.bind_call(one)
          size == ARRAY_SIZE.bind_call(other) &&
            (0...size).all? { |i| same_schema_value?(ARRAY_AT.bind_call(one, i), ARRAY_AT.bind_call(other, i)) }
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

        # Whether a property constrains nothing — genuinely empty, or holding only the metadata an emitted
        # node carries without narrowing it (`description`, and the residues waiting to be rendered into it).
        def asserts_nothing?(prop) = prop.except(:description, RESIDUE_KEY).empty?

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
          kept.delete(:description) if Axn::Internal::Identity.nil_value?(kept[:description])
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
          # A mentioned subtree no longer participates in the final schema walk. Finalize its
          # reports now, on a copy, while schema nodes can still be distinguished from literals.
          finalized, = finalize_residues!(prop, copy: true)
          JSON.generate(json_mentionable(finalized))
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
        #
        # EVERY test and read here is undispatched, because a reduction is only a defence if the reduction
        # itself runs nothing. `nil?`, `==`, `instance_of?` and `map` are all overridable by the literal, so
        # identity comes from `Identity.same?`, the class from `Identity.class_of`, and the two container
        # walks from Array's and Hash's own unbound methods. Only an EXACT built-in is traversed, the rule
        # `normalize_schema_literal` already follows: a subclass is opaque and renders as one.
        #
        # Integer/Float/Symbol need no bound read beyond the class test — none of the three can carry a
        # singleton method, so an exact one answers with its own implementation or not at all.
        def json_mentionable(value)
          return value if Axn::Internal::Identity.nil_value?(value) || Axn::Internal::Identity.same?(value, true) || Axn::Internal::Identity.same?(value, false)
          return value if exactly?(value, ::Integer)
          return value.finite? ? value : mentionable_rendering(value) if exactly?(value, ::Float)
          # `Text.renderable` reads the bytes through bound methods, so the String itself goes in — asking it
          # for `to_s` first would dispatch, which is the thing this method exists not to do.
          return Axn::Internal::Text.renderable(value) if exactly?(value, ::String)
          return Axn::Internal::Text.renderable(value.name) if exactly?(value, ::Symbol)
          return MENTIONABLE_MAP.bind_call(value) { |element| json_mentionable(element) } if exactly?(value, ::Array)
          return mentionable_pairs(value) if exactly?(value, ::Hash)
          # A declared class, named through `Module#to_s` bound rather than its own `to_s`.
          return Axn::Internal::Rendering.module_name(value) if Axn::Internal::Identity.kind?(value, ::Module)

          mentionable_rendering(value)
        end

        # `value` is an instance of `klass` ITSELF, asking neither the value nor its class. A subclass
        # answers false: it may override the reads a traversal would make.
        def exactly?(value, klass) = Axn::Internal::Identity.same?(Axn::Internal::Identity.class_of(value), klass)

        # An exact Hash walked through Hash's own `each_pair`. Every reduced key is a plain primitive, so the
        # `[]=` that collects them hashes something axn built rather than something it was handed.
        def mentionable_pairs(value)
          MENTIONABLE_EACH_PAIR.bind_call(value).each_with_object({}) do |(key, nested), reduced|
            reduced[json_mentionable(key)] = json_mentionable(nested)
          end
        end

        # A callable is named by what it is, never rendered: its only rendering is an object address, which would
        # change the document on every boot.
        PER_CALL_RENDERING = "(resolved per call)"

        # The literal classes whose rendering says what the value is, each read through its OWN class's `to_s`
        # bound to the value — the exact class only, so the text is the built-in one and no override can run.
        # Anything else, a callable object included, is named by its class: its own `to_s` is caller code, which
        # reflection may never run, and Ruby's default one is an address that would change on every boot.
        LITERAL_RENDERINGS = {
          ::Float => ::Float.instance_method(:to_s), ::Regexp => ::Regexp.instance_method(:to_s),
          ::Rational => ::Rational.instance_method(:to_s), ::Complex => ::Complex.instance_method(:to_s),
          ::BigDecimal => ::BigDecimal.instance_method(:to_s), ::Date => ::Date.instance_method(:to_s),
          ::DateTime => ::DateTime.instance_method(:to_s), ::Time => ::Time.instance_method(:to_s)
        }.freeze
        RANGE_EXCLUDE_END = ::Range.instance_method(:exclude_end?)
        RANGE_BEGIN = ::Range.instance_method(:begin)
        RANGE_END = ::Range.instance_method(:end)
        private_constant :LITERAL_RENDERINGS, :RANGE_EXCLUDE_END, :RANGE_BEGIN, :RANGE_END

        def mentionable_rendering(value)
          # A String (a subclass included) is read through `Text.renderable`, whose reads are bound.
          return Axn::Internal::Text.renderable(value) if Axn::Internal::Identity.kind?(value, ::String)
          return PER_CALL_RENDERING if Axn::Internal::Identity.kind?(value, ::Proc) || Axn::Internal::Identity.kind?(value, ::Method)
          return range_rendering(value) if exactly?(value, ::Range)

          to_s = LITERAL_RENDERINGS[Axn::Internal::Identity.class_of(value)]
          return Axn::Internal::Text.renderable(to_s.bind_call(value)) if to_s

          Axn::Internal::Rendering.class_name(value)
        end

        # A Range's endpoints are reduced like any other value, so an endpoint of a caller's class runs nothing.
        def range_rendering(range)
          ends = [RANGE_BEGIN.bind_call(range), RANGE_END.bind_call(range)].map do |endpoint|
            Axn::Internal::Identity.nil_value?(endpoint) ? "" : JSON.generate(json_mentionable(endpoint))
          end
          ends.join(RANGE_EXCLUDE_END.bind_call(range) ? "..." : "..")
        end

        # An authored `description:` survives a stand-down even though the declaration's constraints do not:
        # it describes the POSITION for a reader, not the value for a validator, so nothing about it is
        # untrustworthy across a transform or a closed gate. Dropping it silently lost the explicit node's
        # own prose in the ordinary case — a shape member cannot transform, so the node is nearly always the
        # side that stands down, and its description was published before this. Both are kept when both
        # exist, and an identical pair collapses.
        # Both descriptions are the AUTHOR'S OWN prose, so neither is asked anything: each is reduced through
        # the rendering seam first, and the equal-pair collapse then compares two plain Strings axn owns
        # rather than dispatching a `==` the description's class may define.
        #
        # `nil?` is overridable too, so every nil test this reporting path makes of a caller's own object —
        # here, in `carry_metadata`, and in `stand_down_from` — goes through `Identity.nil_value?`. The rule
        # is the region's, not this method's: a value reaches the guarded rendering seam WITHOUT having been
        # asked anything on the way.
        def carried_description(kept, dropped)
          return kept if Axn::Internal::Identity.nil_value?(dropped)
          return dropped if Axn::Internal::Identity.nil_value?(kept)

          kept_prose = mentionable_rendering(kept)
          dropped_prose = mentionable_rendering(dropped)
          kept_prose == dropped_prose ? kept_prose : join_prose(kept_prose, dropped_prose)
        end

        # Two pieces of prose joined through the text seam, either of which may be caller-supplied and in
        # an encoding the other cannot be concatenated with.
        #
        # Reduced through `mentionable_rendering`, never `to_s`: a String SUBCLASS description can override
        # `to_s`, and one that raises took `input_schema` down from inside the append. The seam reads a
        # String's bytes through bound methods and guards everything else.
        # An author's description, rendered, and closed as a sentence where it is not already, so the residue
        # sentence appended after it reads as its own ("ID of the User record. Additional constraints…").
        SENTENCE_END = /[.!?:;]["')\]]*\s*\z/

        def as_sentence(prose)
          return prose if Axn::Internal::Identity.nil_value?(prose)

          rendered = mentionable_rendering(prose)
          rendered.empty? || rendered.match?(SENTENCE_END) ? rendered : "#{rendered}."
        end

        def join_prose(*parts)
          rendered = parts.reject { |part| Axn::Internal::Identity.nil_value?(part) }.map { |part| mentionable_rendering(part) }
          rendered.empty? ? nil : rendered.join(" ")
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

        # Ask the emitter whether this token reached its fallback; a parallel classifier missed
        # :boolean and mistook a real boolean constraint for another unknown-class hint.
        def unknown_class_token?(token) = known_type_for(token, for_output: false).nil?

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
        # INPUT needs no gate: a value a client sends is a JSON primitive, whose Ruby equality with a member is
        # JSON Schema's own (`1 == 1.0` both ways), so the set is exact for everything the wire can carry.
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

          # A gated check is reflected by what it enforces with its gate CLOSED, in both directions: the schema
          # never promises what the runtime skips on some calls. Outbound, a declaration-level gate leaves the
          # property untyped outright (the action may expose whatever it assigned). Inbound, each entry is judged
          # by its EFFECTIVE gate (`ungated_validations`), so a declaration gate drops every entry it reaches while
          # one whose blank nested gate overrides it — `type: { klass: Integer, if: nil }, if: :enabled?` runs on
          # every call — is still stated. What the open gate would enforce is named as a residue, and a
          # `default:` still applies (a gate governs validation, not the pipeline).
          return prop if for_output && conditionally_gated?(config)

          # GATE-CLOSED validations (see effective_validations, the one derivation of them): everything below
          # reads the config through that subset, so a per-validator gate drops the same entry here as in the
          # plan every property-name rule is charged against. Rebuild the config only when an entry actually
          # drops, judged against the SAME read of `validations` the reduction was given — a caller-supplied
          # member's reader may mint a fresh Hash per read, so comparing against a second read would rebuild
          # every config (and a duck-typed member answers no `with` at all).
          declared_config = config
          declared = config.validations
          effective = for_output ? effective_validations(declared) : gate_closed_validations(config, declared)
          config = config.with(validations: effective) unless effective.equal?(declared)

          type_info = json_type_for(config.validations, for_output:)
          nullable = nil_allowed?(config)
          apply_type_info!(prop, type_info, config, nullable:)

          prop = with_input_default(prop, config, subfield:, for_output:)

          apply_structured_schema!(prop, config, for_output:, ancestry:)

          # LAST, because the floor's KEY is chosen from the property's type (`minItems`/`minProperties`/
          # `minLength`) and a shape block is what establishes that type: a custom class or module carrying one
          # holds the permissive fallback until `apply_structured_schema!` rewrites it to `object`. Deriving
          # the key any earlier reads an intermediate type and lands the floor under a key that cannot express
          # it. Nothing above depends on the constraint already being there.
          if !for_output && type_info.empty? && declared_config.validations[:type] && !structured?(config)
            apply_untyped_value_constraints!(prop, config.validations, nullable:)
          else
            apply_value_constraints!(prop, config.validations, nullable:, for_output:)
          end

          return prop if for_output

          prop = report_unstated_checks(prop, config, declared_config)
          effective.equal?(declared) ? prop : with_gating_residues(prop, declared_config)
        end

        # A `preprocess:` runs before any check, so every keyword `build_property` writes describes the Proc's
        # output, not what the wire carries — and the wire form is unknowable (a Proc may parse, map or replace
        # it). The property keeps only its description and default and names what applies after the transform,
        # exactly as a transforming side stands down at a collision (`stand_down_from`). Applied where a property
        # is emitted on its own, and only once its subtree is complete: its children read the Proc's output too,
        # so their `properties` and `required` stand down with it. A colliding one reaches that stand-down
        # through the collision instead. Requiredness and nullability are decided elsewhere and stay as declared
        # (the stated exception at `apply_explicit_child!`). A `coerce:` does not stand down: coercion accepts a
        # wire String as a courtesy the declared type still describes, which is how the `coerce:` DSL has always
        # reflected.
        def emitted_input_property(prop, config)
          return prop unless config.respond_to?(:preprocess) && config.preprocess

          stand_down_from(prop.slice(:description, :default), prop.except(:description, :default), TRANSFORM_RESIDUE)
        end

        # Every ungated check this property does not state, named as a residue — the other half of the promise
        # the schema makes beyond its exact core: it may say less than the runtime, never silently. Reuses the
        # collision path's own reporting (`project_collision_checks`), which asks each keyword's emitter, per
        # surviving JSON type, whether it wrote anything; the rest are checks that never have a keyword here.
        #
        # The per-type report reads the DECLARED config, gated entries included: a gated bound with no keyword
        # for a surviving type (`comparison:` on a String) is exactly what a gating residue's fragment cannot
        # show, since the fragment only differs from its baseline by whatever the entry happens to emit.
        def report_unstated_checks(prop, config, declared_config)
          validations = config.validations
          # A size ceiling of 0 states an `absence:` exactly on a declaration whose every type is a container;
          # anywhere else — a scalar, or a union a scalar branch of which the ceiling never reaches — the blank
          # axis is spelled as a value set, which is exact for every JSON type but a String.
          if absence_bounds_blankness?(validations) && !(only_blank_is_empty_types?(validations) && size_zero_stated?(prop))
            prop = prop.merge(allOf: Array(prop[:allOf]) + [{ anyOf: [{ type: "string" }, { enum: BLANK_WIRE_VALUES }] }])
          end
          prop = report_unexpressed_checks(prop, [declared_config])
          prop = report_numeric_wire_form(prop, validations)
          gates = declaration_gates(declared_config)
          unstated_entry_fragments(declared_config.validations, prop).reduce(prop) do |acc, (key, options)|
            if Axn::Validation::Base.entry_effectively_gated?(options, gates)
              record_residue(acc, gated_unstated_summary(declared_config, key, options), kind: :conditional)
            else
              record_residue(acc, unstated_check_sentence(key, options), kind: :inherent)
            end
          end
        end

        # A gated check no keyword states, in the one wording both passes that reach it use, so `record_residue`
        # keeps a single copy where both run.
        def gated_unstated_summary(config, key, options)
          phase = definitely_transforms_wire_value?([config]) ? "after transformation, " : ""
          "#{phase}#{GATED_RESIDUE}; #{unstated_check_sentence(key, options)}"
        end

        # A JSON number reaches the runtime as an Integer (`1`) or a Float (`1.5`, `1.0`), and JSON Schema's `number`
        # cannot tell the two apart. A declared numeric class is therefore exact on the wire only as `Numeric` or as
        # the Integer-and-Float pair; any other set (`Float` alone rejects `1`, and `BigDecimal` or `Rational` reject
        # every JSON number) is named. `Integer` alone is the stated exception: `"integer"` also admits `1.0`, and
        # naming that on every Integer field would say nothing a caller acts on.
        def report_numeric_wire_form(prop, validations)
          tokens = declared_type_tokens(validations)
          numeric = tokens.select do |token|
            class_token?(token) && (Internal::Identity.same?(token, ::Numeric) || strict_descendant?(token, ::Numeric))
          end
          return prop if numeric.empty?
          # Only where a JSON number still reaches a numeric branch: one a narrowing dropped admits none.
          return prop unless projected_types(prop).intersect?(%w[number integer])

          # Asked of the WHOLE union: a JSON number passes through any branch admitting its Ruby class, `Object` or
          # `Numeric` included.
          admits = ->(klass) { tokens.any? { |token| Internal::Identity.kind?(token, ::Module) && Internal::NativeMethods.includes_module?(klass, token) } }
          integer = admits.call(::Integer)
          return prop if integer && admits.call(::Float)
          return prop if integer && numeric.all? { |token| Internal::Identity.same?(token, ::Integer) }

          names = numeric.map { |token| Axn::Internal::Rendering.module_name(token) }.join(", ")
          record_residue(prop, "the runtime checks for a Ruby #{names}, and a JSON number arrives as an Integer (1) or a " \
                               "Float (1.5)")
        end

        # The property another declaration emits at a `model:` route's own key — a non-model route merged onto the
        # node, an ancestor's shape member, or another `model:` route's generated id. The route reads that key as
        # the record, and a JSON value never is one, so only a blank passes; the property says what the other
        # declaration accepts, which is more. Conditional exactly when the lookup is.
        def with_model_raw_key_residue(prop, model_configs)
          return record_residue(prop, MODEL_RAW_KEY_RESIDUE) unless model_configs.all? { |config| model_lookup_gated?(config) }

          record_residue(prop, "#{GATED_RESIDUE}; #{MODEL_RAW_KEY_RESIDUE}", kind: :conditional)
        end

        # How the runtime treats a `default:` (`FieldConfig.resolve_default`): anything answering `call` is
        # `instance_exec`ed through its `to_proc`, so it is COMPUTED when it answers both (a Proc, a Method, a
        # service class with `.to_proc`), BROKEN when it answers `call` alone (the omitted call raises converting
        # it), and LITERAL otherwise. Asked of the value's class through bound reads, so the value runs nothing —
        # for a class or module, of its singleton class, which is where its own methods live.
        def default_invocation(value)
          lookup = if Internal::Identity.kind?(value, ::Module)
                     Internal::NativeMethods.module_singleton_class(value)
                   else
                     Internal::Identity.class_of(value)
                   end
          return :literal unless Internal::NativeMethods.public_instance_method?(lookup, :call)

          Internal::NativeMethods.public_instance_method?(lookup, :to_proc) ? :computed : :broken
        end

        def computed_default?(value) = default_invocation(value) == :computed

        # A default the runtime cannot apply (it raises on the omitted call) supplies nothing to the schema.
        def broken_default?(value) = default_invocation(value) == :broken

        # A requirement a gate relaxes is named as conditional only when the gate ALONE relaxes it: where an ungated
        # check whose nil verdict is unknowable (a `validate:`) is also why the position is optional, that check's own
        # residue says so, and calling the requirement conditional would claim the check goes away with the gate.
        def with_gated_requirement(prop, configs)
          return prop if prop.nil?

          relaxed = configs.select { |config| requiredness_conditionally_relaxable?(config) }
          return prop unless relaxed.all? { |config| requiredness_conditionally_relaxable?(config, unknowable_relaxes: false) }

          record_residue(prop, GATED_REQUIRED_RESIDUE, kind: :conditional)
        end

        # A null-only id never reaches the lookup, so it has nothing to name. The lookup is conditional when every
        # model route's lookup is gated; one ungated route looks up on every call.
        def with_model_lookup_residue(prop, model_configs)
          return prop if prop.nil? || projected_types(prop) == ["null"]
          return record_residue(prop, MODEL_LOOKUP_RESIDUE) unless model_configs.all? { |config| model_lookup_gated?(config) }

          record_residue(prop, "#{GATED_RESIDUE}; #{MODEL_LOOKUP_RESIDUE}", kind: :conditional)
        end

        # Only the declaration's own gate skips the lookup: an inbound `model:` bag never carries one
        # (`Contract#_reject_model_bag_gates_and_tolerances!` refuses it).
        def model_lookup_gated?(config)
          Internal::FieldConfig::CONDITIONAL_GATE_KEYS.any? { |key| config.validations.key?(key) }
        end

        # A callable is named rather than rendered: its only rendering is an object address, and asking it for
        # one would run a caller's `to_s`.
        def unstated_check_sentence(key, options)
          return "a custom `validate:` check applies, which JSON Schema cannot express" if key == :validate

          "JSON Schema cannot express this check (#{render_constraint({ key => reported_options(options) })})"
        end

        # The `numericality:`/`comparison:` options the emitter states: the bounds (`NUMERIC_BOUND_KEYS`, and a
        # ranged `in:`), the integer/numeric narrowings, and the tolerances. Anything else — `other_than:`,
        # `odd:`, `even:` — has no keyword and is named.
        STATED_NUMERIC_OPTIONS = (NUMERIC_BOUND_KEYS.keys + %i[in only_integer only_numeric allow_nil allow_blank message if unless]).freeze

        # Whether the node itself already holds every container branch it has to size 0 — asked of what was
        # emitted rather than of the derivation, since a bag position spells its type as `klass:` and reaches no
        # ceiling through the field's.
        def size_zero_stated?(prop)
          branches = prop[:anyOf].is_a?(Array) ? prop[:anyOf] : [prop]
          containers = branches.select { |branch| Array(branch[:type]).intersect?(%w[array object]) }
          containers.any? && containers.all? { |branch| branch.values_at(:maxItems, :maxProperties).include?(0) }
        end

        def only_blank_is_empty_types?(validations)
          tokens = declared_type_tokens(validations)
          !tokens.empty? && tokens.all? { |token| blank_is_empty_class?(token) }
        end

        # The entries no keyword states at all: an exclusion set, an `inclusion:` whose members are not a literal
        # list reflection can read, a bare `numericality:` on a node admitting non-numbers, a blank-tolerant
        # `length:`, and a declared class JSON has no type for.
        # Returned as `[key, options]` pairs, gate options intact, so the caller can tell a conditional one.
        def unstated_entry_fragments(validations, prop)
          entries = Axn::Validation::Base.validator_entries(validations)
          fragments = []
          fragments << [:exclusion, entries[:exclusion]] if entries[:exclusion]
          fragments << [:inclusion, entries[:inclusion]] if entries[:inclusion] && !inclusion_enum_values(entries[:inclusion])
          fragments << [:numericality, entries[:numericality]] if entries[:numericality] && numericality_unstated?(entries[:numericality], prop)
          fragments << [:length, entries[:length]] if blank_tolerant_length_unstated?(validations)
          # No keyword states these at all: an accepted-value set, equality with a companion field, a callable.
          %i[acceptance confirmation validate].each { |key| fragments << [key, entries[key]] if entries[key] }
          NUMERIC_BOUND_ENTRIES.each_key do |key|
            unstated = unstated_numeric_options(entries[key])
            fragments << [key, unstated] unless unstated.empty?
          end
          fragments << [:type, entries[:type]] if entries[:type] && unknown_type_constrains?(validations)
          fragments
        end

        def numericality_settled_member?(value)
          Axn::Internal::Identity.nil_value?(value) || Axn::Internal::Identity.same?(value, false) ||
            (Axn::Internal::Identity.kind?(value, ::Numeric) && !Axn::Internal::Identity.kind?(value, ::Complex))
        end

        # A numeric entry's options no keyword states, gate options kept so the caller can tell a conditional one.
        # A narrowing ActiveModel resolves per call (a Symbol or callable `only_integer:` or `in:`) is stated only
        # when literal; resolved per call, the schema cannot narrow for it, so it is named like an unkeyworded one.
        # (Per-call bounds reach their residue per type, and `only_numeric:` is read truthily, not resolved.)
        PER_CALL_STATED_NUMERIC_OPTIONS = %i[only_integer in].freeze

        def unstated_numeric_options(entry)
          return {} unless Axn::Internal::Identity.kind?(entry, ::Hash)

          per_call = entry.slice(*PER_CALL_STATED_NUMERIC_OPTIONS).select { |_key, value| Axn::Validation::Base.resolved_per_call?(value) }
          unstated = entry.except(*STATED_NUMERIC_OPTIONS).merge(per_call)
          unstated.empty? ? {} : unstated.merge(entry.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS))
        end

        # The Ruby class of every value a JSON document can carry.
        JSON_VALUE_CLASSES = [::String, ::Integer, ::Float, ::Hash, ::Array, ::TrueClass, ::FalseClass, ::NilClass].freeze

        # Whether the declared type names a class with no JSON spelling that still rejects some JSON value — so
        # its untyped node says less than the runtime. `Object`/`Kernel`/`BasicObject` admit every JSON value
        # and so constrain nothing a type could have stated; `Comparable` rejects an Array, and a custom value
        # class rejects everything a client can send it that a `preprocess:` does not turn into one.
        # Asked of the WHOLE union, since a value passes a union through any branch: `[Object, Money]` admits every
        # JSON value through `Object` and so constrains nothing, whatever `Money` alone would reject.
        def unknown_type_constrains?(validations)
          tokens = declared_type_tokens(validations)
          return false unless tokens.any? { |token| unknown_class_token?(token) }

          JSON_VALUE_CLASSES.any? do |klass|
            tokens.none? { |token| Internal::Identity.kind?(token, ::Module) && Internal::NativeMethods.includes_module?(klass, token) }
          end
        end

        # `numericality:` rejects every value that is not a number or a numeric String, and no keyword says
        # "parses as a number" — so a node admitting any other JSON type says less than it does. The exception
        # is the integer-literal pattern `only_integer:` writes onto a string branch. A bounded entry is already
        # reported per type by `report_unexpressed_checks`.
        def numericality_unstated?(entry, prop)
          return false if Axn::Validation::Base.declared_numeric_bounds(entry, ranged: NUMERIC_BOUND_ENTRIES.fetch(:numericality)).any?
          # A value set the narrowing already closed to numbers (or to nothing, or to the nil/blank the position
          # skips) states the check exactly.
          return false if prop[:enum].is_a?(Array) && prop[:enum].all? { |value| numericality_settled_member?(value) }

          others = projected_types(prop) - NUMERIC_TYPES - ["null"]
          return false if others.empty?
          return true unless others == ["string"]

          branches = prop[:anyOf].is_a?(Array) ? prop[:anyOf] : [prop]
          branches.any? { |node| Array(node[:type]).include?("string") && node[:pattern].nil? }
        end

        # Whether `of:`/`shape:` establishes the property's JSON type (`apply_structured_schema!`), so an untyped
        # declared class is not left untyped after all.
        def structured?(config) = config.validations[:of] || config.validations[:shape]

        # The validations an INPUT property is built from: every entry that runs on every call. The same Hash
        # when nothing is gated, which is what lets `build_property` skip rebuilding a config — so it is handed
        # the one read of `validations` the caller made, since a member's reader may mint a fresh Hash per read.
        def gate_closed_validations(config, validations)
          return validations unless gated_validations?(validations) || conditional_checks?(config)

          ungated_validations(config)
        end

        # A non-Proc `default:`, written into `prop` (mutated and returned). Only a truthy subfield default is
        # applied at runtime, so a falsey `default: false` subfield must not advertise a default the runtime
        # never applies. Top-level defaults apply by key-presence.
        #
        # A Proc default is never emitted — reflection may not run it — but it counts toward the field being
        # omittable, and whether its value then passes the field's own checks (or a shape it materializes) is
        # unknowable here. That is named, so the omission the schema allows is never a silent looseness.
        # Outbound a Proc default is simply not emitted: the output schema carries no residues (`build_output`
        # never finalizes them, so one recorded there would leak as a raw key).
        def with_input_default(prop, config, subfield:, for_output: false)
          declared_default = declared_attribute(config, :default)
          return prop if declared_default.nil?
          return for_output ? prop : record_residue(prop, PROC_DEFAULT_RESIDUE) if computed_default?(declared_default)
          return prop if broken_default?(declared_default)

          emit_default = subfield ? config.applied_default? : true
          prop[:default] = normalize_schema_literal(declared_default) if emit_default
          prop
        end

        # Name every gated check `prop` leaves out, each rendered as the fragment it would contribute with
        # its gate open. Inbound only: the output schema carries no residues.
        def with_gating_residues(prop, config)
          # Sorted, so two spellings of one contract — entries declared in a different order — read the same.
          gating_residues([config], enforced: prop).sort_by(&:summary)
                                                   .reduce(prop) { |acc, r| record_residue(acc, r.summary, kind: r.kind) }
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
          elsif type_info.empty? && config.validations[:type] && !structured?(config)
            # A declared type with no JSON spelling (an unknown class) asserts no type, but a required position
            # still rejects a blank — nil among them — on every call. Spelled as a value set, the only form left
            # without a type to hang a size or a null branch on.
            if presence_rejects_blank?(config.validations)
              prop[:not] = { enum: BLANK_WIRE_VALUES }
            elsif !nullable
              reject_null!(prop)
            end
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

        # The value constraints of a declared type with no JSON spelling (an unknown class): the node asserts no
        # type, so each keyword is written for every JSON type it can mean something for, and JSON Schema applies
        # it only to values of that type — `minLength` to a string, `minItems` to an array, a numeric bound to a
        # number. What no keyword states for some type (a `length:` on a number's rendering) is reported by
        # `report_unstated_checks` like anywhere else.
        def apply_untyped_value_constraints!(prop, validations, nullable:)
          apply_inclusion_enum!(prop, validations, nullable:, for_output: false, property_names: false)
          Sizing::SIZE_CONSTRAINT_KEYS.each_key do |type|
            token = TypeTokens::TYPE_MAP.find { |_token, json_type| json_type == type }.first
            prop.merge!(typed_keywords(type, validations.merge(type: token)) { |node, typed| apply_size_constraints!(node, typed) })
          end
          bounds = typed_keywords("number", validations.merge(type: Float)) do |node, typed|
            apply_numeric_bounds!(node, typed, nullable:, for_output: false)
          end
          # An `equal_to:` lands as a value set (`const`/`enum`), which — unlike a bound — judges every JSON type.
          # Where the runtime also rejects every non-number that is exact; under `numericality:`, which takes the
          # numeric String `"10"`, it is scoped to numbers instead.
          if numeric_strings_admitted?(Axn::Validation::Base.validator_entries(validations))
            value_set = bounds.slice(:const, :enum)
            unless value_set.empty?
              prop[:allOf] = Array(prop[:allOf]) + [{ anyOf: [{ not: { type: "number" } }, value_set] }]
              bounds = bounds.except(:const, :enum)
            end
          end
          prop.merge!(bounds)
          prop.merge!(typed_keywords("string", validations) { |node, typed| apply_pattern!(node, typed, for_output: false) })
        end

        # The keywords an emitter writes onto a node of one JSON type, without the type itself.
        def typed_keywords(type, validations)
          node = { type: }
          yield node, validations
          node.except(:type)
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
            return node.merge!(record_residue(node, UNREACHABLE_ENUM_RESIDUE)) if !for_output && enum_unreachable?(node, values)
          end

          existing = node[:enum]
          node[:enum] = existing ? existing & values : values
        end

        # A declared set none of whose members the node's own type admits. The declaration guards refuse such a
        # set wherever it rejects every value; what reaches here is the set a tolerated BLANK rescues — `type:
        # Array, presence: false, inclusion: { in: ["a"], allow_blank: true }` accepts `[]` and nothing else — and
        # emitting it would leave a node no value satisfies, `[]` included. So the set is left out and named.
        # The node's types are read from wherever it states them — a `type` (an Array of them when nullable) and
        # each branch of a union's `anyOf` — so a union is judged like a single type. A node stating none is not
        # judged, and a member whose JSON type this cannot classify counts as admitted, so the answer errs toward
        # keeping the set. A `null` member a nullable node admits keeps the set: the node is satisfiable, and the
        # tolerated non-nil blank it still refuses is the stated blank-axis exception.
        UNREACHABLE_ENUM_RESIDUE = "only the blank value its tolerance skips can pass: no member of its `inclusion:` " \
                                   "set is of the declared type"

        def enum_unreachable?(node, values)
          types = stated_json_types(node)
          return false if types.empty?

          values.none? do |value|
            json_type = literal_json_type(value)
            json_type.nil? || types.include?(json_type) || (json_type == "integer" && types.include?("number"))
          end
        end

        # Every JSON type a node states: its own `type` (one, or an Array of them) and each `anyOf` branch's.
        def stated_json_types(node)
          Array(node[:type]) + Array(node[:anyOf]).flat_map { |branch| branch.is_a?(::Hash) ? Array(branch[:type]) : [] }
        end

        def literal_json_type(value)
          case value
          when ::NilClass then "null"
          when ::TrueClass, ::FalseClass then "boolean"
          when ::Array then "array"
          when ::Hash then "object"
          else enum_scalar_type(value)
          end
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

          pattern = Pattern.ecma_source(Axn::Validation::Base.validator_entry_options(entry)[:with])
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
        # A bound is written only onto a branch it constrains exactly, and every case a bound cannot be carried
        # exactly stands down to emitting nothing and is reported (`report_unexpressed_checks`).
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
            # A union carries its null branch separately, so the bound goes onto its numeric branches as a
            # `const`, like any other bound — a node-level set would also judge its String branch and reject the
            # numeric String `numericality:` accepts.
            if operator == :equal_to && nullable && !prop[:anyOf].is_a?(Array)
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
          restrict_union_to_bounded_branches!(prop) if wrote_bound && !for_output && !numeric_strings_admitted?(entries)
        end

        # Whether a numeric STRING can pass these entries: `numericality:` parses one (`"5"` passes a
        # `greater_than: 0`), while `comparison:` compares the String itself against a number and rejects it.
        # Only when both run does the String branch lose every value.
        def numeric_strings_admitted?(entries) = entries[:numericality] && !entries[:comparison]

        # A bound can only be written onto a branch that carries a numeric type, which leaves a union's other
        # branches advertising values the validator rejects: `type: [String, Integer], comparison: { greater_than: 0 }`
        # accepts `"abc"` through the string branch while ActiveModel rejects every String. Where the runtime
        # rejects every value of a branch, dropping it is exact. Under `numericality:` it does not — a numeric
        # String passes — so the branch stays and says more than the runtime allows (`numeric_strings_admitted?`):
        # no `minimum` applies to a JSON string, and dropping the branch would reject `"5"`, which the runtime
        # takes.
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
          validations = effective_validations(config.validations)
          of = validations[:of]
          shape = validations[:shape]
          # An `array` branch of a union counts: `items` constrains an array alone, so it is exact at the union's
          # own node beside a scalar branch it says nothing about.
          json_type = json_type_for(validations, for_output:)
          in_items = stated_json_types(json_type).include?("array")
          container = of_container(validations)
          nothing = ShapePropertyPlan.new(emitted: false, in_items:, type_schema: {}, shape:, container:)

          # The same two gates `apply_structured_schema!` opens with, in the same order. A declaration with
          # neither `of:` nor `shape:` contributes no object properties AT ALL — not even its type's own members —
          # so a `Data` used purely as a `type:` names nothing, and a rule keyed on these names must not fire on
          # it. Likewise a wholly gated config, which `build_property` leaves untyped before reaching emission.
          return nothing unless of || shape
          return nothing if gated_validations?(validations)
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
        # declaration-level gate keys stay too (inert to this reduction — a wholly gated config is already left
        # untyped by its own earlier return, in both `build_property` and `shape_property_plan`). The same in both
        # directions: inbound, a gated bound emitted as if open rejects the calls whose gate is closed, which is
        # the one thing the schema may never do. Returns the SAME Hash when nothing drops, which is what lets
        # `build_property` skip rebuilding a config.
        def effective_validations(validations)
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
            # A branch asserting nothing admits every value, so the union does too: it is untyped, and the
            # floor/nullability an untyped node carries apply to it whole rather than to one branch of it.
            type_hashes = [{}] if type_hashes.any?(&:empty?)
            node = type_hashes.size == 1 ? type_hashes.first : { anyOf: type_hashes }
            return narrow_node_under_numericality(node, validations, tokens)
          end

          # Outbound, the SET names a type only where it passes the same equality-safety test the `enum` itself
          # is gated on — one predicate for both emissions, since both turn on whether a member can be `==` to a
          # value that serializes differently. It can: `Integer#==` falls back to `other == self`, so a value
          # object comparing equal to `1` satisfies `inclusion: { in: [1] }` and serializes as its own string,
          # which an inferred `"integer"` then rejects. A String/Symbol/boolean/nil member settles it alone —
          # their `==` never matches a foreign class — while a numeric member asks the position to pin its class,
          # which nothing reaching here has declared (a `type:` returns above, and a bag with a `klass:` takes the
          # other branch), so a numeric set always stands down outbound. Input needs no gate: a wire value is a
          # JSON primitive, which no foreign `==` can reach.
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
            return numericality_input_node(validations, numericality) unless for_output
            return { type: "integer" } if Axn::Validation::Base.declared_only_integer?(numericality)

            return { type: "number" }
          end

          {}
        end

        # Inbound, `numericality:` alone admits a Number or a numeric String (a Number only under `only_numeric:`),
        # so it types the node as that union and lets the union's own narrowing say which Strings and which
        # Numbers pass. Typing it `"number"` rejected the `"5"` the validator parses.
        def numericality_input_node(validations, numericality)
          only_numeric = Axn::Validation::Base.validator_entry_options(numericality)[:only_numeric]
          tokens = only_numeric ? [::Numeric] : [::Numeric, ::String]
          type_hashes = tokens.map { |k| single_type_for(k, for_output: false) }.uniq
          node = type_hashes.size == 1 ? type_hashes.first : { anyOf: type_hashes }
          narrow_node_under_numericality(node, validations, tokens)
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
        def narrow_node_under_numericality(node, validations, tokens)
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
            numericality_branch(branch, admits, numeric_only:, only_integer:, drop:, blank_tolerated:,
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

        def numericality_branch(branch, admits_integer, numeric_only:, only_integer:, drop: true, blank_tolerated: false,
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
          when "string" then string_branch_under_numericality(branch, numeric_only:, only_integer:, drop:)
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

        def string_branch_under_numericality(branch, numeric_only:, only_integer:, drop: true)
          return nil if numeric_only && drop
          return branch unless only_integer

          merge_integer_literal_pattern(branch)
        end

        def merge_integer_literal_pattern(branch)
          source = Pattern.ecma_source(Axn::Validation::Base.integer_literal_regexp)
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
        # On INPUT none of this applies: `numericality_input_node` types the node as the Number-or-numeric-String
        # union the validator accepts. A declared `type:` is unaffected in both directions, being read before this
        # and proving the class itself.
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
