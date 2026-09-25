# frozen_string_literal: true

# SEGMENT_JUDGED_SCALARS names DateTime/Time.
require "date"
require "time"

require "axn/internal/identity"
require "axn/internal/native_methods"
require "axn/internal/shape_graph"
require "axn/internal/reflection/values"

module Axn
  module Internal
    module Reflection
      module Schema
        # Whether a position can hold JSON object PROPERTIES at all — the question the drop pass and the
        # emitter must answer identically, which is why they call the same predicates here rather than
        # each deciding for itself. A `type: Array` parent, a mixed union, a `model:` route and a class
        # serializing through its own `as_json`/`to_h` all answer differently, and the reasons are not
        # interchangeable.
        module Nestability
          # Whether a field's declared type can be represented as a JSON object (so its subfields can nest
          # as object properties): Hash, `:params`, or untyped. A `type: Array` (or other non-object) parent
          # is not — its subfields are extracted differently at runtime and have no object-property shape.
          # ANY admissible branch is object-shaped (Hash/`:params`/untyped) — so runtime's `{}` synthesis from
          # subfield defaults can satisfy the parent type (`{}` is a Hash, matching an object branch).
          def object_shaped?(config)
            object_type_branches(config).any? { |k| [Hash, :params].include?(k) }
          end

          # Whether an object (`{}`) could stand in for this config's value: its declared type must admit an
          # object AND it must not be a `model:` route (a `{}` there is rejected by ModelValidator and would
          # be preferred by the model resolver over a caller-supplied `<field>_id`). `required_child?` uses
          # this to decide whether the parent's OWN applied default materializes an object that would then
          # enforce its required shape members.
          def synthesizable?(config)
            object_shaped?(config) && !config.validations[:model]
          end

          # ALL admissible branches are object-shaped — so the subfields may nest as `properties` without
          # rejecting a valid non-object branch. A mixed union (`type: [Hash, Array]`) is NOT nestable: at
          # runtime the subfield can be read from the Array branch too (e.g. `Array#length`), so forcing
          # `type: object` would disallow a valid array input.
          def nestable_as_object?(config)
            object_type_branches(config).all? { |k| [Hash, :params].include?(k) }
          end

          # Whether the configs declared at a subfield node forbid nesting its children as object properties:
          # a `model:` route (the client sends `<field>_id`, not the object) or a non-nestable type (a
          # non-object type or a mixed union) on ANY config. Single source of truth for the drop pass
          # (blocking_ancestor?, via path_blocked?) and emission (apply_nested_subfields!), so the two never
          # disagree on which deep structure is representable — a node the tree drops from is never re-nested
          # in the schema. Every route is enforced at runtime, so any one non-nestable route defeats nesting.
          def node_configs_block_nesting?(configs)
            configs.any? { |c| c.validations[:model] || !nestable_as_object?(c) }
          end

          # The config a subfield node's own object property is BUILT from: the first route that is not a `model:`
          # one (a model route emits `<leaf>_id` in place of the object, so it shapes no object property). Nil at a
          # pure-model node, which emits no object property at all.
          #
          # One owner for three readers, because each of them has to name the SAME config: `apply_children!`, which
          # emits the property; `annotate_node!`, which decides its nullability; and the projection size cap, which
          # charges that config's shape and must charge no other — a second route to one wire path is enforced at
          # runtime but its `shape:`/`of:` is never emitted, so charging it rejected a contract over a schema it
          # does not have.
          def property_representative(configs) = configs.reject { |c| c.validations[:model] }.first

          def object_type_branches(config)
            type_opt = config.validations[:type]
            return [Hash] unless type_opt # untyped parent — object-shaped for both any?/all?

            declared_type_tokens(config.validations)
          end

          # The builtin scalars whose reader-method surface we judge as the class's own public methods:
          # an instance answers a segment read iff the declared class publicly defines the method
          # (post-PRO-2886 extraction: a Hash-like source reads any key; everything else is a
          # public_send). Anything outside this list — Data/Struct/custom classes, model records —
          # may answer dynamically, so it is never judged (optimistic: rejection needs proof).
          #
          # ACCEPTED DIVERGENCE from the strict no-false-rejection doctrine. TypeValidator is `is_a?`, so
          # a `type: String` value can be a String SUBCLASS that adds methods, or a plain String carrying a
          # singleton method — either is contract-valid yet answers a segment this judgment refutes. We
          # judge anyway, deliberately: the approved design takes the DECLARED class's method surface as the
          # contract (`type: String` promises the String surface, not whatever an exotic subclass bolts on),
          # so a subclass adding readers doesn't hold the declaration hostage. The conventional instance of
          # each listed class IS exactly that class, so the judgment matches real inputs; the subclass/
          # singleton case is the narrow, documented exception. The membership test below is `k <= s`, so a
          # declared class equal to (or a subclass of) a judged entry is judged on that entry's surface.
          #
          # `Numeric` and `Date` are excluded — the boundary is drawn narrower there for a different reason:
          # every contract-valid `type: Numeric` value is a STRICT subclass (Integer/Float/Rational/
          # BigDecimal/…) whose surface is wider than `Numeric` itself (`Integer#bit_length` exists but
          # `Numeric.public_method_defined?(:bit_length)` is false), and `type: Date` admits `DateTime`
          # (adding `hour`/`minute`/…). There the subclass IS the conventional instance, so judging on the
          # abstract class would refute a segment ordinary valid input answers — a real false positive — so
          # both stay optimistic, same as Data/Struct/unknown classes.
          SEGMENT_JUDGED_SCALARS = [String, Symbol, Integer, Float, Array, DateTime, Time, TrueClass, FalseClass].freeze

          # Whether ONE admissible declared branch can answer reading `segment` off its value.
          def branch_answers_segment?(branch, segment)
            return true if branch == :params

            klasses = case branch
                      when :uuid then [String]
                      when :boolean then [TrueClass, FalseClass]
                      else [branch]
                      end
            klasses.any? do |k|
              next true unless Axn::Internal::Identity.kind?(k, ::Class)
              next true if k <= Hash

              # Read from the method table, on the same terms as `Values.displacing_projection` and
              # `framework_generated_reader?` — the three sites that ask this class of question now ask it one
              # way. (The `<=` comparisons around it stay dispatched: those are declared-type checks whose
              # failure mode is a self-correcting declaration error.)
              judged = SEGMENT_JUDGED_SCALARS.any? { |s| k <= s }
              !judged || Axn::Internal::NativeMethods.public_instance_method?(k, segment)
            end
          end

          # Whether a config's declared type admits SOME branch that can answer `segment`. A `model:`
          # route resolves to a record, whose method surface is never statically refutable.
          def config_answers_segment?(config, segment)
            return true if config.validations[:model]

            object_type_branches(config).any? { |branch| branch_answers_segment?(branch, segment) }
          end

          # Whether a shaped field's value serializes to a member-keyed JSON object (so advertising `object` +
          # the shape's properties on OUTPUT matches serialize_exposed). Only asserted for types with a
          # language-guaranteed member-keyed serialization: `:params`, an untyped shape (caller supplies a
          # Hash), Hash, or a Data/Struct that does NOT define its OWN `as_json`. Values.serialize_value
          # follows a value's own `as_json` before `to_h`, so a Data/Struct that overrides `as_json` may emit
          # a scalar/array/differently-keyed hash — treat it (like any reader-only or custom-`to_h` class) as
          # statically unknowable and leave it untyped on output.
          #
          # Takes VALIDATIONS rather than a config because its one caller (shape_property_plan) has already
          # reduced the config to the validations the projection is built from — see effective_validations.
          def shape_serializes_to_object?(validations)
            type_klass = validations.dig(:type, :klass)
            return true if type_klass.nil?

            Axn::Internal::ShapeGraph.type_tokens(type_klass).all? { |k| member_keyed_object_type?(k) }
          end

          def member_keyed_object_type?(klass)
            return true if Axn::Internal::Identity.same?(klass, :params)
            return false unless class_token?(klass)
            return true if Axn::Internal::Identity.same?(klass, ::Hash)
            return false unless strict_descendant?(klass, ::Data) || strict_descendant?(klass, ::Struct)

            # A Data/Struct serializes member-keyed via its built-in to_h — unless the DECLARED class carries
            # a projection of its own that Values.serialize_value would follow instead. Asks the identical
            # question Values asks again at render time, of the runtime value in hand — see its own comment
            # for why one predicate answers both and what each visibility rule means.
            Axn::Internal::Reflection::Values.displacing_projection(klass).nil?
          end
        end
      end
    end
  end
end
