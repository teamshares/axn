# frozen_string_literal: true

require "axn/internal/reflection/schema/gates"
require "axn/internal/reflection/schema/contents"
require "axn/internal/reflection/schema/nestability"
require "axn/internal/reflection/values"
require "axn/internal/shape_graph"

module Axn
  module Internal
    module Reflection
      module Schema
        # The render-time counterpart of `build_output` (PRO-3284): which positions in a RENDERED body were
        # reflected from a Data/Struct's own members, so `Values.serialize_value` can refuse a value whose
        # own `as_json`/`to_h` would render something that position's `output_schema` does not describe.
        #
        # `output_schema` publishes a shape's members as `properties` wherever `member_keyed_object_type?`
        # (or, at an unnamed contents position with no shape, the narrower `contents_object_class?`) judges
        # the DECLARED class provably member-keyed. That judgment is a class-level approximation: a runtime
        # SUBCLASS (or an included module, or a singleton method) can override `as_json`/`to_h` and render
        # something the schema never described — silently, since the value is still contract-valid. This
        # module builds the position map the renderer walks IN LOCKSTEP WITH THE VALUE to catch that
        # divergence — one guard object per emitted position, mirroring the SAME structural traversal
        # `apply_structured_schema!`/`contents_node_schema` already take, and calling the SAME per-node
        # predicates (`shape_serializes_to_object?`, `shape_overlay_applies?`, `member_keyed_object_type?`,
        # `contents_object_class?`) rather than re-deriving them — so the schema's "this position is
        # member-keyed" verdict and the guard's "check this position at render time" verdict cannot drift
        # apart the way two independently-written walks could.
        #
        # A position's guard carries the DECLARED classes worth checking there (`Values.displacing_projection`
        # is only ever asked of a Data/Struct token — a Hash value never reaches it, since `serialize_value`'s
        # `Hash`/`Array` arms catch every subclass structurally, via `Module#===`, never dispatching that
        # subclass's own `as_json`/`to_h`), plus however the renderer descends from there: `members` for a
        # named shaped key (by wire key — a key with no guard of its own is still a member of this Hash,
        # mapped to nil, so a lookup for it does not fall through to a sibling `values` axis that does not
        # apply to it), `items` for an Array's elements, `values` for a Hash's `additionalProperties` axis.
        #
        # Built ONCE per action class (`Extensions::Serialization.render` memoizes it beside
        # `PropertyNames.validate_outbound!`) and nil whenever nothing at all needs guarding, which is the
        # ordinary case: no extra cost per render for an action with no Data/Struct shape in its `exposes`.
        module RenderGuards
          # `[guards, watched_classes]`. `guards` is one guard Hash per action class, keyed by wire key (a
          # String — `Values.canonical_wire_key`, the same canonicalization `serialize_exposed` keys its own
          # per-field walk with) — or nil when no position in this class's output is member-derived at all.
          #
          # `watched_classes` names every Data/Struct class this build found OPAQUE (owns its own `as_json`/
          # `to_h`, hence excluded from `guards` at every position it appears) — the memo this feeds
          # (`Extensions::Serialization#render_guards_for`) re-checks each one's CURRENT opacity before
          # trusting a cached build, because a class regaining member-keyed status after being reopened
          # WITHOUT its own projection can't retroactively gain a guard object that was never built for it
          # (unlike the opposite direction — a guarded class LOSING member-keyed status by GAINING a
          # projection — which needs no such check: `Values#refuse_displaced_projection!` already re-verifies
          # the declared class live on every guarded value, so an existing guard standing down safely
          # under-reaches rather than needing the whole plan rebuilt).
          #
          # THE one entry point; everything below is a helper for it, in the same style Contents/Nestability
          # keep their own helpers unenforced-but-internal rather than `private_class_method`-listed.
          def output_render_guards(field_configs)
            watched = []
            guards = field_configs.each_with_object({}) do |config, acc|
              guard = field_render_guard(config, watched:)
              next unless guard

              acc[Axn::Internal::Reflection::Values.canonical_wire_key(config.field)] = guard
            end
            [guards.empty? ? nil : guards, watched.uniq]
          end

          # THE one field/member node builder, called both for a top-level FieldConfig (ancestry: nil) and
          # recursively for each named shape member (a ShapeConfig, which carries the identical `.validations`
          # shape `build_property` already treats a member and a field identically through) — so a member's
          # own gating, `of:`, and `shape:` are read on the exact same terms a field's are.
          #
          # Mirrors `build_property`'s own gate (`conditionally_gated?`) and `shape_property_plan`'s reduction
          # (`effective_validations`) and gate (`gated_validations?`) before asking anything else, so a
          # position the emitter leaves untyped for either reason is never guarded here either — over-reach
          # (refusing at a position the schema does not actually constrain) is the unsafe direction.
          def field_render_guard(config, watched:, ancestry: nil)
            return nil if conditionally_gated?(config)

            validations = effective_validations(config.validations, for_output: true)
            of = validations[:of]
            shape = validations[:shape]
            return nil unless of || shape
            return nil if gated_validations?(validations)

            in_items = Array(json_type_for(validations, for_output: true)[:type]).include?("array")

            if in_items
              combine_render_guard(items: of ? contents_render_guard(of, ancestry, watched:) : nil)
            elsif ::Hash.equal?(of_container(validations))
              hash_field_render_guard(shape, validations, of, ancestry, watched:)
            elsif shape
              shape_field_render_guard(shape, validations, ancestry, watched:)
            end
          end

          # The non-array, non-map branch: a field (or member) whose own declared type is a single
          # structured class (a union here is refused at declaration — `_shape_compatible_klass?` — so
          # `type_tokens` always answers one token when a `shape:` is in play at this node).
          def shape_field_render_guard(shape, validations, ancestry, watched:)
            tokens = Axn::Internal::ShapeGraph.type_tokens(validations.dig(:type, :klass))
            watch_opaque_classes!(tokens, watched)
            return nil unless shape_serializes_to_object?(validations)

            classes = guarded_render_classes(tokens)
            combine_render_guard(classes:, members: member_render_guards(shape[:members], ancestry, watched:))
          end

          # The map branch: the field's OWN type (`Hash`) is never guarded — a Hash value always renders
          # through `serialize_value`'s `Hash` arm, never a displaced projection — so only the `of:` values
          # axis and any explicitly shaped (named) keys carry anything to check.
          def hash_field_render_guard(shape, validations, of_bag, ancestry, watched:)
            values = of_bag ? map_values_render_guard(of_bag, ancestry, watched:) : nil
            members = shape && shape_serializes_to_object?(validations) ? member_render_guards(shape[:members], ancestry, watched:) : nil
            combine_render_guard(members:, values:)
          end

          # The unnamed-position builder, mirroring `contents_node_schema` rung for rung: the bag's OWN
          # `klass:` (guarded on the WIDER Data-OR-Struct rule when a shape overlay applies here, and on the
          # narrower Data-only `contents_object_class?` when it does not — same asymmetry `single_contents_schema`
          # and `contents_member_schema` already draw), the bag's `shape:` (named members, when the overlay
          # applies), and the bag's own `of:` (recursing into a nested container the same way
          # `contents_node_schema` does — a map bag descends through `map_values_render_guard`, anything else
          # through this same builder).
          def contents_render_guard(bag, ancestry, watched:)
            shape = emitted_contents_edge(bag, :shape, for_output: true)
            overlay = shape && shape_overlay_applies?(bag, for_output: true)

            classes =
              if bag[:klass].nil?
                []
              elsif overlay
                guarded_render_classes(Axn::Internal::ShapeGraph.type_tokens(bag[:klass]))
              else
                contents_klass_render_classes(bag[:klass], watched)
              end
            watch_opaque_classes!(Axn::Internal::ShapeGraph.type_tokens(bag[:klass]), watched) if overlay
            members = overlay ? member_render_guards(shape[:members], ancestry, watched:) : nil

            inner = emitted_contents_edge(bag, :of, for_output: true)
            items = nil
            values = nil
            unless nil.equal?(inner)
              guard_contents_descent(inner, ancestry, edge: :of) do |child|
                if Axn::Internal::ShapeGraph.map_bag?(inner)
                  values = map_values_render_guard(inner, child, watched:)
                else
                  items = contents_render_guard(inner, child, watched:)
                end
              end
            end

            combine_render_guard(classes:, members:, items:, values:)
          end

          # A map's `values:` axis — a bag (recurses through the unnamed-position builder, same as an
          # array's `of:`) or a bare class list (guarded on the narrower Data-only rule, same as any other
          # unnamed bare position — `map_values_schema`'s own `contents_schema_for` call for a bare axis is
          # exactly `single_contents_schema` per token, with no bag-level `shape:` to overlay).
          def map_values_render_guard(bag, ancestry, watched:)
            axis = Axn::Internal::ShapeGraph.hash_or_nil(bag[:values])
            return contents_render_guard(axis, ancestry, watched:) unless nil.equal?(axis)

            classes = contents_klass_render_classes(bag[:values], watched)
            combine_render_guard(classes:)
          end

          # The bare (no shape overlay) unnamed-position rule: Data only, and — for a UNION of more than one
          # token — stood down entirely the moment any sibling branch's own `single_contents_schema` is `{}`.
          # An `anyOf` branch of `{}` matches every JSON value, which makes the WHOLE union unconstrained
          # regardless of which branch a given value happens to be — refusing a value that took the
          # member-keyed branch would then raise against a schema that never promised anything about it in
          # the first place, which is exactly the over-reach this module must not commit.
          def contents_klass_render_classes(klass, watched)
            tokens = Axn::Internal::ShapeGraph.type_tokens(klass)
            watch_opaque_classes!(tokens.select { |k| strict_descendant?(k, ::Data) }, watched)
            return [] if tokens.size > 1 && tokens.any? { |k| single_contents_schema(k, for_output: true) == {} }

            tokens.select { |k| contents_object_class?(k, for_output: true) }
          end

          # `member_keyed_object_type?`-filtered to genuinely CANDIDATE classes: a Hash or `:params` token
          # also passes that predicate (an object is always representable), but a Hash value never reaches
          # `Values.displacing_projection` at all — `serialize_value`'s `Hash` arm matches every Hash
          # SUBCLASS structurally (`Module#===`), so a Hash's own `as_json`/`to_h` is never even consulted.
          # Only a Data/Struct token is ever a real candidate for a displaced projection.
          def guarded_render_classes(tokens)
            tokens.select { |k| (strict_descendant?(k, ::Data) || strict_descendant?(k, ::Struct)) && member_keyed_object_type?(k) }
          end

          # Records every Data/Struct token among `tokens` that is CURRENTLY opaque (owns its own projection,
          # so `member_keyed_object_type?` is false) — the set `output_render_guards` hands back as
          # `watched_classes`. Called from every site that decides guarded-or-not for a Data/Struct token, so
          # the watch list and the guard-building verdict are the same computation rather than two that could
          # disagree about which tokens were examined.
          def watch_opaque_classes!(tokens, watched)
            tokens.each do |k|
              next unless strict_descendant?(k, ::Data) || strict_descendant?(k, ::Struct)

              watched << k unless member_keyed_object_type?(k)
            end
          end

          # Every named member of a shape, keyed by wire key — INCLUDING a member whose own guard is nil, so
          # that key still exists in the returned Hash (mapped to nil) rather than being absent from it. That
          # distinction is what `Values::RenderGuard#entry` depends on: it asks presence directly (`key?`),
          # so a shaped-but-untyped member is a PRESENT nil rather than an absent key, and does not fall
          # through to a sibling `values` axis that does not describe it. Empty (no named members at all)
          # collapses to nil, the ordinary case, so a node with nothing else to say costs nothing to keep.
          def member_render_guards(members, ancestry, watched:)
            hash = guard_contents_descent(members, ancestry, edge: :shape) { |child| build_member_render_guards(members, child, watched:) }
            hash.empty? ? nil : hash
          end

          def build_member_render_guards(members, ancestry, watched:)
            named_members(members).each_with_object({}) do |(member, name), acc|
              acc[Axn::Internal::Reflection::Values.canonical_wire_key(name.to_sym)] = field_render_guard(member, ancestry:, watched:)
            end
          end

          # One guard object, or nil when every axis is empty — the position needs no check at all, and
          # costs nothing to walk again at render time (the common case, for a field with no Data/Struct
          # shape anywhere beneath it).
          def combine_render_guard(classes: [], members: nil, items: nil, values: nil)
            return nil if classes.empty? && members.nil? && items.nil? && values.nil?

            Axn::Internal::Reflection::Values::RenderGuard.new(classes:, members: members || {}, items:, values:)
          end
        end
      end
    end
  end
end
