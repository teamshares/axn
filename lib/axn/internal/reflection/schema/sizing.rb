# frozen_string_literal: true

require "axn/internal/identity"

module Axn
  module Internal
    module Reflection
      module Schema
        # The SIZE axis and the BLANK axis, which overlap without being the same question: a `length:` bound
        # is a size the author wrote, while a size meaning for `absence:` is one axn infers from a check that
        # always runs.
        #
        # The six pure derivations here (`declared_size_minimum`/`_maximum`, the `absence_bounds_*` pair,
        # `blank_values_are_empty?`, `absence_ceiling_bounds_every_token?`) are what `Core::Contract`'s
        # empty-interval guard reads: it refuses exactly the pair this would have emitted, rather than
        # re-deriving the bounds beside it.
        module Sizing
          # JSON Schema spells the emptiness floor differently per type. A type absent here (integer, boolean,
          # number) has no empty state, so no floor is expressible for it.
          SIZE_CONSTRAINT_KEYS = {
            "array" => :minItems,
            "object" => :minProperties,
            "string" => :minLength,
          }.freeze

          # The ceiling half of the same mapping. A type absent here has no size to bound.
          SIZE_CEILING_KEYS = {
            "array" => :maxItems,
            "object" => :maxProperties,
            "string" => :maxLength,
          }.freeze

          def apply_size_constraints!(prop, validations, for_output: false, property_names: false, declared_klass: nil)
            minimum = declared_size_minimum(validations)
            maximum = declared_size_maximum(validations)
            return if minimum.nil? && maximum.nil?

            strings = emit_string_size?(validations, for_output:, property_names:, declared_klass:)

            if prop[:anyOf]
              prop[:anyOf] = apply_member_size_constraints(prop[:anyOf], minimum, maximum, strings:)
            else
              prop.merge!(size_bounds_for(prop[:type], minimum, maximum, strings:))
            end
          end

          # Whether a STRING size may be emitted at this position — the same question `apply_pattern!` asks, and
          # for the same reason. ActiveModel measures the value's own `#length`, and on OUTPUT that is not always
          # the string the wire carries: `Time.utc(2026, 8, 25, 12).to_s` is 23 characters and it serializes as the
          # 20-character `"2026-08-25T12:00:00Z"`, so `length: { is: 23 }` accepts the value at runtime while the
          # emitted `minLength: 23` rejects the action's own output.
          #
          # A COLLECTION size is exempt by construction: `minItems`/`maxItems`/`minProperties`/`maxProperties`
          # count the elements the serializer writes, so the runtime's measurement and the document's agree however
          # the elements themselves render. A `propertyNames` node is exempt too, exactly as it is for a pattern —
          # a KEY's wire form is the `to_s` the validator measured, and an axis whose key is not its own wire form
          # has already had `length:` removed by `key_axis_constraints`. Input needs no gate: the subject there is
          # the value that was sent.
          def emit_string_size?(validations, for_output:, property_names:, declared_klass:)
            return true unless for_output
            return true if property_names

            own_wire_form?(declared_type_tokens(validations, declared_klass))
          end

          # The size keywords whose subject is a STRING, and so the ones the wire-form gate above governs.
          STRING_SIZE_KEYS = %i[minLength maxLength].freeze
          private_constant :STRING_SIZE_KEYS

          # A union emits one branch per member type instead of a single `type:`, and the validators reject an
          # out-of-bounds value whichever branch it takes — so each bound belongs on every branch that can carry
          # it. A branch with no size (an `integer` member) and the nullability branch carry none, decided by the
          # same per-type key lookup the single-type path uses.
          def apply_member_size_constraints(members, minimum, maximum, strings: true)
            members.map do |member|
              bounds = size_bounds_for(member[:type], minimum, maximum, strings:)
              bounds.empty? ? member : member.merge(bounds)
            end
          end

          # The size keywords one emitted type can carry, for the bounds this field declares. Empty for a type
          # with no size, which is what keeps a bound off an `integer` branch and off `"null"`.
          def size_bounds_for(type, minimum, maximum, strings: true)
            bounds = {}
            if minimum && (floor_key = size_constraint_key_for(type)) && emittable_size_key?(floor_key, strings)
              bounds[floor_key] = minimum
            end
            if maximum && (ceiling_key = size_ceiling_key_for(type)) && emittable_size_key?(ceiling_key, strings)
              bounds[ceiling_key] = maximum
            end
            bounds
          end

          def emittable_size_key?(key, strings) = strings || !STRING_SIZE_KEYS.include?(key)

          # The JSON Schema floor key for an emitted type, or nil for a type with no empty state. Reads the
          # single-type String and the `[T, "null"]` nullable pair alike; `"null"` is never size-bearing.
          def size_constraint_key_for(type)
            Array(type).filter_map { |t| SIZE_CONSTRAINT_KEYS[t] }.first
          end

          # The JSON Schema ceiling key for an emitted type, or nil for a type with no size. Reads the single-type
          # String and the `[T, "null"]` nullable pair alike, exactly as the floor's own key lookup does.
          def size_ceiling_key_for(type)
            Array(type).filter_map { |t| SIZE_CEILING_KEYS[t] }.first
          end

          # The smallest size this field's validators admit, or nil when they admit an empty value. An explicit
          # `length:` floor wins over the implicit 1 that the emptiness check and the presence check each carry —
          # a caller needs the tightest of them, and all three forbid empty. The floor is read by
          # Validation::Base's shared definition, the same one the
          # emptiness reconciliation judges a declaration by, so what the runtime enforces and what the schema
          # advertises cannot drift; a per-call (Symbol/Proc) or infinite floor is unemittable and falls through
          # to the presence check.
          #
          # A blank-tolerant `length:` contributes its floor only when an empty value would be rejected ANYWAY.
          # Blank-tolerance on one entry says an empty value stands THAT entry aside, not that an empty value gets
          # through: with nothing else rejecting it the contract admits "empty or at least 3", which no floor
          # expresses, so emitting 3 would reject a value the contract accepts — but where a presence or emptiness
          # check rejects every empty value, 3 or more is all the contract admits and the floor is exact. Truthiness
          # decides the tolerance, not key presence: a nil-tolerance injects an explicit `allow_blank: false`.
          #
          # A GATED entry never reaches here: `build_property` reads the gate-closed validations, so a gated
          # floor is left out and named as a residue instead.
          #
          # Only `length:` is consulted, never a `size:`: `size` is absent from KNOWN_VALIDATION_KEYS, so a
          # declaration carrying it raises "Unknown key(s) :size" and can never reach reflection.
          # Whether a `length:` stands aside for a blank that nothing else rejects — "blank, or within these
          # bounds", which no size keyword states. Both bounds are then left out and reported.
          def blank_tolerant_length?(validations)
            return false unless validations[:length]

            length = effective_entry_options(validations[:length], shared_validation_options(validations))
            length[:allow_blank] == true && !empty_value_rejected?(validations)
          end

          def declared_size_minimum(validations)
            # Whether an empty value can get through at all decides BOTH branches below: it is the floor of 1 a
            # presence/emptiness check imposes on its own, and it is what tells a blank-tolerant `length:` apart
            # from one whose blank-tolerance is moot.
            rejects_empty = empty_value_rejected?(validations)

            length = effective_entry_options(validations[:length], shared_validation_options(validations))
            if rejects_empty || !length[:allow_blank]
              declared = Axn::Validation::Base.declared_length_floor(length)
              return declared if Axn::Validation::Base.emittable_length_floor?(declared)
            end

            rejects_empty ? 1 : nil
          end

          # The largest size this field's validators admit, or nil when they bound it nowhere. Two spellings name
          # one, and `absence:` is the tighter of them whenever it names one at all, so it answers first: it
          # rejects every non-blank value, so where a type's blank values are exactly its EMPTY ones it leaves
          # size 0 as the only admissible size — the exact statement `length: { maximum: 0 }` makes. Without it a
          # field carrying `absence:` beside a dropped floor emitted no ceiling at all, a node LOOSER than the
          # contract it projects.
          #
          # A blank-tolerant `length:` whose blank is not rejected anyway emits no ceiling: a String's blank is
          # any run of whitespace, of any length, which no `maxLength` admits — so the bound is left out and
          # named as a residue (`blank_tolerant_length?`), the same as its floor. A gated entry never reaches
          # here (see declared_size_minimum).
          def declared_size_maximum(validations)
            return 0 if absence_bounds_size?(validations)
            return nil if blank_tolerant_length?(validations)

            length = effective_entry_options(validations[:length], shared_validation_options(validations))
            declared = Axn::Validation::Base.declared_length_ceiling(length)

            declared if Axn::Validation::Base.emittable_length_ceiling?(declared)
          end

          # JSON Schema's `propertyNames` applies to EVERY key of the object, `properties`-matched ones included.
          # The runtime does the opposite for a shaped map: a key the `shape:` names is EXEMPT from both axes
          # (Core::Contract#_derive_shaped_keys!), which is what `additionalProperties` already means and what
          # makes combining the two options coherent. So a bare keys-axis constraint beside a shape would publish
          # a document the runtime contradicts — and contradict it in the direction that matters, since a member
          # is `required` and a `propertyNames` it fails forbids that key, leaving a node NO value satisfies. That
          # is exactly the corollary PRO-3192 recorded in guards-and-projections.md.
          #
          # The union is the runtime rule verbatim — a key is one the shape names, or one the axis admits — so the
          # node stays satisfiable AND stays exact, rather than being loosened to nothing or dropped.
          # Reads the exempt set off the node's OWN emitted `properties` rather than taking a member list: the
          # runtime derives its exempt set from the emitter's key computation in the first place (PRO-3166), so
          # this is the same answer asked of the same source, and one helper then serves every site where the two
          # options meet — a field's own map node, and a NESTED bag composing a `shape:` with a map `of:`, which
          # is also where the distributing block form lands (PRO-3191 folds it into that bag).
          def exempt_shaped_keys_from_property_names(node)
            axis = node[:propertyNames]
            shaped = node[:properties]
            return node if axis.nil? || axis.empty? || shaped.nil? || shaped.empty?

            node.merge(propertyNames: { anyOf: [axis, { enum: shaped.keys.map(&:to_s) }] })
          end
          # The classes whose BLANK values are exactly their EMPTY ones, so "rejects every non-blank value" and
          # "admits size 0 only" say the same thing about them. `String` is deliberately absent and is the whole
          # reason this is a list rather than `EMPTY_CONTAINER_CLASSES`: ActiveSupport gives it a `blank?` of its
          # own (`BLANK_RE`), under which `"  "` is blank while `empty?` and `length` both say otherwise — so an
          # `absence:` on a String bounds WHITESPACE, which no size key expresses, rather than size.
          #
          # `ActionController::Parameters` is not here either: it is identified by rendered name rather than by
          # constant, and a list this one is read off must be comparable by identity.
          BLANK_IS_EMPTY_CLASSES = [::Hash, ::Array].freeze

          # Whether a live `absence:` bounds this declaration's SIZE — the question `declared_size_maximum` asks,
          # and the one a guard may lean on, as opposed to the looser "is an `absence:` present".
          #
          # Three conditions, each load-bearing:
          #
          #   * the entry is LIVE — a falsy one is the disabled validator ActiveModel skips, so it forbids
          #     nothing;
          #   * every declared type is one whose blank values are its empty ones, since only there does the blank
          #     axis land on the size axis at all;
          #   * the entry is UNGATED — by a gate of its own OR by one the whole declaration carries, since either
          #     stops it running. The emitter reads gate-closed validations anyway, but the declaration guards ask
          #     this of the raw ones: `presence: { unless: :archived }, absence: { if: :archived }` is a working
          #     contract, and deriving a `maxItems: 0` from its conditional half would put a ceiling on a
          #     judgment the contract does not carry on the calls where the gate is closed — most of them.
          def absence_bounds_size?(validations)
            return false unless absence_bounds_blankness?(validations)

            blank_values_are_empty?(validations)
          end

          # The first two of those conditions on their own: a LIVE, UNGATED `absence:`, which rejects every value
          # that is not blank whatever the declared type. Split out because the blank axis is a real constraint
          # even where it lands nowhere on the size axis — for a `String`, `absence:` rejects `"ab"` while no size
          # key expresses it — so the member scan asks this to know whether a non-blank member can be a witness at
          # all (`_member_survives_the_blank_axis?`), where the ceiling derivation above needs the size question.
          # One definition, so the two cannot disagree about which `absence:` entries count.
          def absence_bounds_blankness?(validations)
            entry = Axn::Validation::Base.validator_entries(validations)[:absence]
            return false unless entry

            !Axn::Validation::Base.entry_effectively_gated?(entry, Axn::Validation::Base.shared_validation_options(validations))
          end

          # Whether every value this declaration calls BLANK measures 0 — the question that decides whether the
          # blank axis can be read as a statement about size at all. Shared with the guard that asks whether a
          # blank value could slip past a blank-tolerant entry, so the two cannot disagree about one declaration.
          #
          # Only the SIZE-BEARING tokens are asked. A union emits one branch per token and `size_bounds_for` puts
          # no bound on a branch that carries no size keyword, so a `NilClass` (or an `Integer`, or `:boolean`)
          # can neither make an `absence:` ceiling wrong nor be constrained by one — and must not veto it either.
          # Judging every token alike is what left `type: [Array, NilClass], presence: false, absence: true`
          # without a ceiling on its ARRAY branch, so a non-empty array was schema-valid and runtime-invalid: the
          # looser direction, which the emitter may never take.
          #
          # A `String` among them still answers false, and that is the point of asking per token rather than
          # per branch: a String branch IS size-bearing, and `absence:` bounds whitespace there rather than size,
          # so no ceiling can be emitted for the union at all while one member reads that way.
          def blank_values_are_empty?(validations)
            sized = declared_type_tokens(validations).select { |token| token_carries_a_size?(token) }

            sized.any? && sized.all? { |token| blank_is_empty_class?(token) }
          end

          # Whether the branch a token emits can carry a size keyword at all, asked through the emitter's own
          # type mapping and its own key lookup rather than an enumeration beside them — so a token whose emitted
          # type changes cannot leave this answering the old one.
          #
          # A token the map does not know emits no type, but its values may still carry one (a String subclass,
          # or anything `length:` measures through `to_s`), so it counts as size-bearing and vetoes.
          def token_carries_a_size?(token)
            known = known_type_for(token, for_output: false)
            known.nil? || !size_ceiling_key_for(known[:type]).nil?
          end

          def blank_is_empty_class?(token)
            BLANK_IS_EMPTY_CLASSES.any? { |klass| klass.equal?(token) } || (defined?(Set) && ::Set.equal?(token))
          end

          # The non-size tokens whose values an `absence:` check rejects OUTRIGHT: no `true`, no Integer and no
          # Float is blank, so a declaration bounding the blank axis to size 0 admits nothing of theirs at all —
          # which is what makes a refusal drawn from that ceiling sound even with one of them in the union.
          #
          # `:boolean` and `FalseClass` are the ones deliberately absent, and they are the whole reason this list
          # exists: `false` IS blank, so the `absence:` accepts it, and `LengthValidator` measures its rendering
          # (`"false"`, five characters) rather than a length it has none of. A union naming either has a branch
          # the ceiling does not bound, and the guard cannot conclude anything from it.
          ABSENCE_REJECTS_EVERY_VALUE = [::TrueClass, ::Integer, ::Float, ::Numeric].freeze

          # Whether an `absence:`-derived ceiling of 0 bounds EVERY branch this declaration names — the size
          # guard's question, and deliberately not `blank_values_are_empty?`, which filters the union down to its
          # size-bearing tokens.
          #
          # Both questions are right for their caller. The emitter needs to know what bound the ARRAY branch
          # carries, and `maxItems: 0` is the answer there whatever a sibling admits — dropping it would leave a
          # non-empty array schema-valid and runtime-invalid. This guard needs to know whether the DECLARATION
          # admits anything, and a single unbounded branch means it cannot say.
          #
          # Three cases per token, and the middle one is why this reads as a list rather than a measurement: a
          # token whose blank values are its empty ones is bounded (`blank_is_empty_class?`); a token no blank
          # value of which exists is bounded vacuously, since the `absence:` rejects everything it admits; and
          # anything else — `:boolean`, a `String`, an unrecognized class — is not bounded, so the ceiling proves
          # nothing about it. Unknown answers "not bounded", which stands the guard down: over-refusing a working
          # declaration is the one failure it cannot recover from.
          def absence_ceiling_bounds_every_token?(validations)
            declared_type_tokens(validations).all? do |token|
              next true if blank_is_empty_class?(token)
              next false if token_carries_a_size?(token)

              ABSENCE_REJECTS_EVERY_VALUE.any? { |known| Axn::Internal::Identity.same?(known, token) }
            end
          end
        end
      end
    end
  end
end
