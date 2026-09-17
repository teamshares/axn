# frozen_string_literal: true

require "active_model"

require "axn/internal/rendering"

module Axn
  module Validators
    class ValidateValidator < ActiveModel::EachValidator
      # `nested:` is required rather than defaulted: it decides which REMEDY the misuse message offers, and the
      # two are different advice. Both call sites name it, and a third that forgot would otherwise send the
      # author to the wrong position.
      def self.apply_syntactic_sugar(value, _fields, nested:)
        if value.is_a?(Hash)
          # `validate:` is the CUSTOM-callable validator; a Hash form must carry the callable under
          # `:with` (`validate: { with: <callable>, message: "…" }`). A Hash without `:with` is a
          # misuse — most often ActiveModel validator keys mistakenly nested under `validate:`
          # (`validate: { inclusion: { in: [...] } }`), which enforces nothing and would otherwise
          # raise a bare `must supply :with` at CALL time. Fail loudly here (declaration time) with the
          # fix, since this runs during `expects`/`exposes`.
          unless value.key?(:with)
            raise ArgumentError,
                  "`validate:` expects a callable — `validate: ->(value) { ... }` or " \
                  "`validate: { with: <callable>, message: \"...\" }` — but got a Hash with no `:with` key " \
                  "(keys: #{value.keys.inspect}). If you meant a standard validation such as an " \
                  "allowed-value set, declare it directly (e.g. `inclusion: { in: [...] }`), which constrains " \
                  "the value at that position — #{misuse_remedy(nested)}"
          end

          _reject_uncallable!(value[:with])
          return value
        end

        _reject_uncallable!(value)
        { with: value }
      end

      # Whether `value` is a legal `validate:`/`with:` value: a Symbol (PRO-3380 — resolved against the
      # action, mirroring `if:`/`sensitive:`/`inclusion: { in: :method }`) or anything answering `#call`
      # (a Proc, a Method, or a plain object). This is the SAME question `validate_each` asks to decide
      # how to invoke the value, so a value this predicate admits is exactly one `validate_each` can run
      # — the guard and the dispatch cannot drift.
      #
      # Guarded against a hostile `respond_to?` that raises instead of answering — a declaration guard
      # must not let the value being judged raise IN PLACE OF the verdict, so an unestablishable value is
      # refused rather than escaping the check (mirrors `Handlers::Invoker.safely_callable?`).
      def self.legal_with_value?(value)
        value.is_a?(::Symbol) || value.respond_to?(:call)
      rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
        false
      end

      # The misuse guard for the callable itself, run at declaration for both the bare form and the
      # Hash form's `:with` — a Symbol naming a nonexistent method, or a non-callable like `123`,
      # declared cleanly before this and then degraded into a per-call "failed validation: undefined
      # method 'call'" message. Runtime backstop in `check_validity!` below, for a validations Hash
      # assembled directly rather than through this sugar step.
      def self._reject_uncallable!(value)
        return if legal_with_value?(value)

        raise ArgumentError,
              "`validate:` expects a callable or a Symbol naming an action method — " \
              "`validate: ->(value) { ... }`, `validate: :method_name`, or " \
              "`validate: { with: <callable or Symbol> }` — but got a value of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(value)}."
      end
      private_class_method :_reject_uncallable!

      # Where "declare it directly" puts the validator, worded for the position the misuse was written at. In a
      # BAG the position is already the contents, so the validator belongs in that same bag; at a FIELD the
      # position is the container, and a constraint on its contents belongs one rung down in `of:`.
      def self.misuse_remedy(nested)
        if nested
          "in a bag that is the contents, so it belongs in the same bag beside `klass:`."
        else
          "on a container-typed field that is the container itself, not its contents — a constraint on those " \
            "belongs in `of:`."
        end
      end
      private_class_method :misuse_remedy

      # Runtime backstop for a `:with` that bypassed the declaration guard above (e.g. validations
      # assembled directly rather than through `apply_syntactic_sugar`) — a missing `:with`, a Symbol
      # naming nothing, or a plain non-callable. Mirrors the guard's own predicate, so the two agree.
      def check_validity!
        return if self.class.legal_with_value?(options[:with])

        raise ArgumentError,
              "`validate:` requires a callable or a Symbol under `:with` (`validate: { with: <callable or " \
              "Symbol> }`) or the bare form `validate: ->(value) { ... }` / `validate: :method_name`. For a " \
              "standard validation such as an allowed-value set, use the validator directly " \
              "(e.g. `inclusion: { in: [...] }`), which constrains the value at that position — on a " \
              "container-typed field that is the container itself, not its contents."
      end

      # `record` is the one-off `Axn::Validation::Fields` collector, which carries the action instance
      # threaded by `Fields.errors_for` (`@action`, read here through the private `_action_for_validation`
      # reader — the same seam `_validation_subject` reaches). PRO-3380: every other user-supplied
      # callable in the contract layer runs against the action (`default:`, `preprocess:`, `if:`/
      # `unless:`, …); `validate:` alone ran with the LEXICAL `self` at declaration, unable to reach a
      # sibling field or an action method. Mirrors `preprocess:`'s own dispatch
      # (`Internal::FieldConfig` — `action.instance_exec(value, &config.preprocess)`) exactly, with no
      # arity filtering: the value is always passed, because the value is the thing being validated.
      #
      # A Symbol resolves against the action (PRO-3380's new form, mirroring `if:`/`sensitive:`/
      # `inclusion: { in: :method }`). A Proc, lambda, or Method — anything answering `to_proc` — is
      # `instance_exec`'d against the action, so `self` is the action and a Method keeps its OWN
      # receiver (Ruby's `&method_obj` conversion, unaffected by `instance_exec`'s rebinding — the same
      # thing `Handlers::Invoker` relies on). Anything else (a plain object with only `#call`, which has
      # no receiver to rebind) is called directly, exactly as before this change — an object with its
      # own receiver isn't a closure. The `action`-less fallback is defensive: every `Fields.errors_for`
      # call site threads one, so it is unreached in practice.
      def validate_each(record, attribute, value)
        msg = begin
          callable = options[:with]
          action = record.send(:_action_for_validation)

          if callable.is_a?(::Symbol)
            action.send(callable, value)
          elsif action && callable.respond_to?(:to_proc)
            action.instance_exec(value, &callable)
          else
            callable.call(value)
          end
        # Catches what axn absorbs, not just StandardError: the fallback message names the real error
        # ("failed validation: stack level too deep"), so failing the field stays both accurate and
        # uniform — a validator that blows the stack takes the same path as one raising ArgumentError.
        # This also absorbs `fail!`/`done!` raised from inside the callable (`Axn::Failure` and
        # `Axn::Internal::EarlyCompletion` are both `StandardError`), the same way `preprocess:`'s own
        # wrapping does — the field simply fails with that message rather than short-circuiting the call.
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => e
          # Log the raised error best-effort, then surface it as this field's validation message — a
          # crashing custom validator fails the field rather than silently passing.
          # The subject is named by the validator collector rather than interpolated from the attribute: an
          # unnamed position's attribute is a synthetic axn owns (see Validation::ContainerContents).
          Axn::Extensions.best_effort("applying custom validation on #{record.send(:_validation_subject, attribute)}") { raise e }

          "failed validation: #{Axn::Internal::Rendering.exception_message(e)}"
        end

        record.errors.add(attribute, msg) if msg.present?
      end
    end
  end
end
