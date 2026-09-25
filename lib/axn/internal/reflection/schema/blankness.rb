# frozen_string_literal: true

# `Internal::ClassName` is how a Parameters instance is recognized without naming a Rails constant.
require "axn/exceptions"
require "axn/internal/native_methods"

module Axn
  module Internal
    module Reflection
      module Schema
        # Whether a RUNTIME VALUE is blank or empty, and how big it is — asked of the value itself, never of
        # a declaration. Separate from the rest of the emitter because nothing here knows about JSON Schema
        # at all: `Core::Contract`'s declaration-time guards are its heaviest reader, and they need the same
        # answers the emitter does, from the same code.
        #
        # Every question is put to the value through `NativeMethods`, which reads a method's OWNER before
        # dispatching: a reflection verdict may not run a caller's `empty?`/`blank?`, and a class that
        # overrides one is simply unrecognized rather than trusted.
        module Blankness
          # Parameters is identified by rendered class NAME rather than by the constant: this file is one an adapter
          # gem loads directly, and naming a Rails constant here would put an unresolvable reference in its load graph
          # for every consumer running without Rails. It is the same identify-by-name form TypeValidator already uses
          # to recognize a test double, and the rendering is read natively (`Internal::ClassName.of_module`) so a class
          # cannot answer this question for itself.
          PARAMS_CLASS_NAME = "ActionController::Parameters"

          # The container classes whose `empty?` is RUBY'S OWN — the ones the emptiness axis is declared on. `Set` sits
          # behind `defined?` because `set` is not always loaded.
          EMPTY_CONTAINER_CLASSES = [::Hash, ::Array, ::String].freeze

          # Whether a default is an EMPTY container, decided by WHOSE `empty?` would answer it. Ownership is the whole
          # test, because it separates the two things a subclass can be: one that INHERITS the built-in's `empty?`
          # answers with Ruby's own code, so running it is safe and its empty instance is as empty as the built-in's;
          # one that OVERRIDES it (or carries a singleton) is caller code, which a reflection verdict must not run —
          # and not recognizing it is also what matches the runtime, since that same override is what the emptiness
          # check will ask. Anything else — a lazy collection, an arbitrary object — is unrecognized for the same
          # reason, so no `empty?` of a caller's writing is ever dispatched here.
          #
          # The owner read is bound (`NativeMethods.method_owner`); the call that follows it needs no guard, because
          # the implementation it dispatches is the one whose owner was just established.
          def empty_container?(value)
            owner = Axn::Internal::NativeMethods.method_owner(value, :empty?)
            return false unless owner && native_empty_owner?(owner)

            value.empty?
          end

          # How many elements a literal holds, or nil where a check could measure it differently. Read where a
          # declared literal has to be weighed against the sizes a contract admits (the empty-interval guard's
          # inclusion branch).
          #
          # FOUR checks can hold a size bound, and each asks the value by a different method — the complete list:
          #
          #   `length:`             `value.length`   (activemodel 8.1.3.1, length.rb:48)     floor and ceiling
          #   `presence:`           `value.blank?`   (presence.rb)                           floor
          #   the emptiness check   `value.empty?`   (NonEmptinessValidator)                 floor
          #   `absence:`            `value.present?` (absence.rb)                            ceiling
          #
          # Which check holds a given bound is not this method's to know — the floor of 1 is `presence:`'s on one
          # declaration and `length:`'s on the next — so a value is measured only where every one of them is
          # Ruby's own, and there they agree by construction. `size` is deliberately not among them: no check
          # asks it, and reading it is how an `Array` subclass overriding `length` was measured as empty here
          # while `length:` and `inclusion:` both accepted it at runtime.
          #
          # And a bound-holding check does not reach its measurement directly: it asks the value whether it CAN
          # answer first, and takes a different measurement when the answer is no. `length:` reads
          # `value.respond_to?(:length) ? value.length : value.to_s.length`, and ActiveSupport's `Object#blank?`
          # is `respond_to?(:empty?) ? !!empty? : false`. So the capability probe is part of the measurement, and
          # a value carrying its own `respond_to?` is measured by an answer IT wrote however native the method
          # that answer names: an exact `Array` answering `false` for `:length` is measured as `"[]"` — two
          # characters — and not as `Array#length`'s zero, so a floor of 2 it appears to fail is one it meets.
          # `respond_to?` is therefore on the list beside the four measurements it selects between.
          #
          # That override is not deception to be refused: answering for a method it forwards is the ordinary
          # shape of a proxy or delegator, which is why axn's own emptiness check asks the capability through a
          # BOUND `Object#respond_to?` (`NonEmptinessValidator::CAPABILITY_CHECK`) rather than trusting the
          # value's answer. ActiveModel dispatches it, so a declaration weighing what ActiveModel will measure
          # has to count the caller's answer as part of the measurement — reading the unforgeable one here would
          # measure something no check performs.
          #
          # The list grows with the bounds. `present?` belongs to it because PRO-3220 taught `absence:` to name a
          # ceiling; adding that bound without revisiting this list is what let a member answering
          # `present? => false` be weighed against a ceiling it does not obey.
          #
          # Ownership is the whole test, the same one `empty_container?` applies and for the same reason: a
          # measurement a caller wrote is caller code, which a declaration-time verdict must neither run nor
          # second-guess. Standing down leaves the declaration legal, the direction this guard must err in.
          #
          # The owner reads are bound (`NativeMethods.method_owner`); the call that follows needs no guard,
          # because the implementation it dispatches is the one whose owner was just established.
          def container_size(value)
            return nil unless ASKED_BY_A_BOUNDING_CHECK.all? { |method_name| natively_answered?(value, method_name) }

            value.length
          end

          # The methods the BLANK axis asks a value by: ActiveModel's presence/absence validators call `blank?`
          # and `present?`, and ActiveSupport's generic pair answers out of `empty?` behind a `respond_to?` probe.
          # `length` is deliberately absent — blankness is not size, which is the whole reason a `String` member
          # needs this at all.
          ASKED_BY_THE_BLANK_AXIS = %i[blank? present? empty? respond_to?].freeze

          # Whether this value's BLANKNESS is Ruby's own to answer, on exactly the terms `container_size` applies
          # to its measurement and for the same reason: a member whose `present?` or `blank?` is its own decides
          # for itself whether an `absence:` accepts it, and a declaration-time verdict may neither run that code
          # nor second-guess it. Answering false stands the judgment down, which leaves the declaration legal.
          def blankness_natively_answered?(value)
            ASKED_BY_THE_BLANK_AXIS.all? { |method_name| natively_answered?(value, method_name) }
          end

          # Every method a check that holds a size bound asks the value by — the four measurements plus the
          # `respond_to?` those checks select between them with. All must be Ruby's own, so the order is
          # immaterial.
          ASKED_BY_A_BOUNDING_CHECK = %i[length empty? blank? present? respond_to?].freeze

          # `Object` and `Kernel` are admitted as owners, and neither can end up owning a MEASUREMENT here:
          # `Object` only ever owns `blank?`/`present?` and `Kernel` only ever owns `respond_to?`, since none of
          # them defines `length` or `empty?`. ActiveSupport's `Object#blank?` is
          # `respond_to?(:empty?) ? !!empty? : false` and its `present?` is `!blank?`, so both answer out of the
          # very `empty?` this method has already required to be native: for a `Set`, whose blankness AS does not
          # specialize, that is the whole reason a member is measurable at all. `Kernel#respond_to?` is Ruby's
          # own capability probe, which every value answers with until one carries an override.
          def natively_answered?(value, method_name)
            owner = Axn::Internal::NativeMethods.method_owner(value, method_name)
            return false if owner.nil?

            native_empty_owner?(owner) || ::Object.equal?(owner) || ::Kernel.equal?(owner)
          end

          def native_empty_owner?(owner)
            return true if EMPTY_CONTAINER_CLASSES.any? { |klass| klass.equal?(owner) }
            return true if defined?(Set) && ::Set.equal?(owner)

            # The rendered name is a Ruby-made String (the bound `Module#to_s`), so comparing it dispatches String's
            # own `==` whatever the owner is.
            Axn::Internal::ClassName.of_module(owner) == PARAMS_CLASS_NAME
          end

          # A default value ActiveModel's presence validator treats as blank (and so rejects): `false`, a
          # whitespace-only String, or an empty container. (nil is handled by the caller.)
          def presence_blank?(value)
            return true if value.equal?(false)
            return value.strip.empty? if value.instance_of?(String)

            empty_container?(value)
          end

          # Whether a default is EMPTY — the question `allow_empty: false`'s own check asks of a value, which is
          # not blankness: a whitespace-only String is blank but not empty, and `false` has no empty state at all.
          def empty_default?(value) = empty_container?(value)

          # Whether an `<field>_id` default can actually serve as a model LOOKUP token — the shared test
          # for every id-rescue site (sibling_id_rescued?, which serves both the annotation credit and the
          # contradictions loop, and SubfieldContradictions' model_omittable?). usable_default? judges a default for the FIELD's OWN
          # omission, where a blank literal ("" / {}) is usable when no presence validator rejects it — but
          # the model resolver blank-guards the id (Model#derive_value: `return nil if id_value.blank?`), so
          # a blank id default can never resolve a record and never rescues an omitted model. It must
          # therefore be satisfiability-usable AND not a blank literal. A Proc default stays optimistic
          # (unknowable at declaration), matching usable_default?'s satisfiability doctrine.
          def usable_id_token_default?(config)
            return false unless usable_default?(config, subfield: true)

            value = declared_attribute(config, :default)
            return true if value.is_a?(Proc)

            !presence_blank?(value)
          end
        end
      end
    end
  end
end
