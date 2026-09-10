# frozen_string_literal: true

require "active_model"

require "axn/extensions"

module Axn
  module Validators
    class ModelValidator < ActiveModel::EachValidator
      # Syntactic sugar: model: User -> model: { klass: User }
      def self.apply_syntactic_sugar(value, fields)
        (value.is_a?(Hash) ? value.dup : { klass: value }).tap do |options|
          # Set default klass based on field name if not provided
          options[:klass] = nil if options[:klass] == true
          options[:klass] ||= fields.first.to_s.classify

          # Constantize string klass names
          options[:klass] = options[:klass].constantize if options[:klass].is_a?(String)

          # Set default finder if not provided
          options[:finder] ||= :find

          # One class or a list of them, canonicalized to a list so the resolver reads one shape. Only
          # when the author wrote the key: an ABSENT `not_found_on:` means "use the default set", which is
          # resolved per-ask at runtime (ActiveRecord may load after axn), while an explicit empty list is
          # a real answer that opts the field out. `is_a?(::Array)` rather than `Kernel#Array`, which would
          # ask a caller-supplied class for `to_ary`/`to_a` before wrapping it.
          options[:not_found_on] = [options[:not_found_on]] if options.key?(:not_found_on) && !options[:not_found_on].is_a?(::Array)
        end
      end

      # What a `model:` field says when it resolved to nothing. ActiveModel calls a Proc `message:` with
      # `(object, data)`, so this rides on the field's presence check (Contract#_apply_model_absence_message!)
      # rather than being added as a second error — one nil, one error.
      #
      # Two different facts wear the same nil, and conflating them is the misdirection PRO-3369 closes: no
      # `<field>_id` at all is a blank field, while an id the finder could not resolve is a record that does
      # not exist. The id itself is deliberately NOT interpolated — this message reaches an external caller
      # verbatim under `user_facing_input_errors:`, and a custom finder's token can be a secret (an email, an
      # API token) where a primary key would have been harmless. The caller already knows the id they sent,
      # and a dev-facing report carries it in `context[:inputs]`.
      ABSENCE_MESSAGE = lambda do |object, _data|
        field = object.class.respond_to?(:_axn_validated_field) ? object.class._axn_validated_field : nil
        Axn::Validators::ModelValidator.absence_message(object, field)
      end

      # Axn's own wording, given the validator instance and the field it is validating. Reached from the
      # presence entry's Proc `message:` above and from `_reject_absence` below — the two places an absence
      # can be reported — so a `model:` field says the same thing about a nil however the check that reports
      # it was installed. An author's own `message:` outranks it at both, and is applied by the caller.
      def self.absence_message(validator, field)
        return "not found" if lookup_attempted?(validator)

        # ActiveModel's own :blank string, so a host's i18n override still governs the ordinary case.
        field ? validator.errors.generate_message(field, :blank) : "can't be blank"
      end

      # Whether the finder was actually asked — i.e. the caller named a record to look up. Resolved through
      # the SAME token derivation the finder consumes (ContractForSubfields.model_lookup_token), which also
      # memoizes it, so the message can never claim "not found" for an id the lookup never saw, or "can't be
      # blank" for one it did — not even when reading the id DISPATCHES a one-shot method.
      #
      # Any seam that cannot answer means NOT attempted: this only ever chooses between two wordings for a
      # violation already being reported, so a degraded read costs a less specific message, while raising
      # here would replace the contract violation with an error manufactured while describing it.
      def self.lookup_attempted?(validator)
        # A finder runs for INBOUND fields only — `_model_fields`, the resolver's own source, is built from
        # `internal_field_configs` — so an outbound `model:` field resolving to nil means "you did not expose
        # it", never "no such record". Without this, an `exposes :user, model: …` failure alongside an
        # `expects :user, model: …` that SUCCEEDED borrowed the inbound token and reported a lookup that had
        # actually found its record. Gated here rather than at declaration because the same borrowing reaches
        # a second door (a model field with no presence check, reported by `_reject_absence` below).
        return false if validator.send(:_outbound_validation?)

        action = validator.send(:_action_for_validation)
        return false unless action

        # The config is HANDED over, never recovered. Looking it up by name meant dispatching `class` on the
        # action — a user-owned object, so an override decided the answer — and matching on `field`, which
        # cannot distinguish two declarations that share a name. Both call sites now thread it (Executor's
        # inbound collector at either depth), so an absent one means this is not a position that can have
        # attempted a lookup.
        config = validator.send(:_config_for_validation)
        return false unless config&.validations&.key?(:model)

        # `blank?`, the SAME decision `FieldResolvers::Model#derive_value` gates the finder on. A hand-rolled
        # `to_s.strip.empty?` disagreed with it for every token whose blankness is not about its characters —
        # `false`, `[]`, `{}` all render non-empty — so the resolver skipped the lookup while this said one had
        # happened, and a required field reported "not found" for a record nobody asked for.
        !Axn::Core::ContractForSubfields.model_lookup_token(action, config).blank?
      rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
        false
      end

      def check_validity!
        return unless options[:klass].nil?

        raise ArgumentError, "must supply :klass"
      end

      def validate_each(record, attribute, value)
        return _reject_absence(record, attribute) if value.nil?

        # The value is already resolved by the facade, just validate the type
        type_validator = TypeValidator.new(attributes: [attribute], **options)
        type_validator.validate_each(record, attribute, value)
      end

      private

      # A nil record is an ABSENCE, never a type error: the finder either wasn't asked or answered "no such
      # record". Delegating nil to the TypeValidator is what produced the doubled "X is not a Y and X can't
      # be blank" — two validators reporting one missing value — so this reports it once, or defers.
      #
      # It DEFERS whenever a presence check will actually REPORT this nil, which is the ordinary case: that
      # entry carries this same wording (Contract#_model_absence_message_for picks it, author's `message:`
      # included), so it says exactly this, and both of us adding an error is the doubling
      # again. Otherwise this is the only thing between an omitted record and a passing contract, so it
      # reports here — the field is still required either way (requiredness is `optional?`, which none of
      # these spellings touch, and the emitted schema keys off that).
      #
      # "Will report", never "exists": a presence entry that ActiveModel SKIPS reports nothing, and deferring
      # to one let a required `model:` field resolve to nil and the action succeed. Three spellings skip it —
      # `presence: false` installs no validator at all, `presence: { if: … }`/`{ unless: … }` gates it off,
      # and `presence: { allow_nil: … }`/`{ allow_blank: … }` makes it skip exactly the value in hand. The
      # gate half is decided by ActiveModel itself through the shared oracle rather than a hand-rolled mirror
      # of its merge and arity rules (Fields.validator_gate_open?), and the entry's options are read off the
      # constructed validator, where `validates` has already merged the declaration-level gates into the
      # entry's own.
      def _reject_absence(record, attribute)
        return if record.errors.where(attribute).any?

        # The author's own `model: { message: }` first, on the same precedence the presence door applies
        # (Contract#_model_absence_message_for) — it reached this case before the model validator stopped
        # handing nil to `TypeValidator`, which is what honored it.
        record.errors.add(attribute, options[:message] || self.class.absence_message(record, attribute))
      end
    end
  end
end
