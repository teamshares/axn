# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "axn/core/validation/base"

module Axn
  module Validation
    # THE one-off validator collector, for every declared config at every level: a top-level field
    # validates against the context facade (which resolves model records and reads by wire key), a
    # subfield against its canonically-resolved parent value. One (field, validations) pair per
    # one-off class; raising/settling is the caller's concern (see Executor#_validate_inbound!).
    class Fields < Base
      def initialize(source)
        super()
        @source = source
      end

      def read_attribute_for_validation(attr)
        # A subfield reads through the action's generated reader when one exists — the reader IS the
        # field's value (memoized, model-resolving, value-level-default-applying, PRO-2889), so
        # validation sees exactly what user code sees. The reader's memo can't be stale here: the
        # executor clears every subfield reader memo at the inbound-pipeline boundary
        # (_clear_pre_pipeline_memos!), so a value cached by an early pre-settlement read is discarded
        # and this read resolves against the settled wire values. A dotted-name subfield has no reader
        # and resolves through the same shared helper. Top-level fields keep reading their source facade.
        if @action && @reader && @action.respond_to?(@reader)
          @action.public_send(@reader)
        elsif @action && @config&.subfield?
          Axn::Core::ContractForSubfields.resolve_value(@action, @config)
        else
          # Only a top-level/outbound field reaches here (subfields resolve via the reader or
          # resolve_value above); its source is the framework's own context/result facade, whose
          # per-field reader is a safe accessor — so method dispatch is always permitted here (it's the
          # facade's generated reader, not the caller-object dispatch the method_call gate targets).
          # Malformed sources still read as absent (one doctrine — see FieldResolvers.extract_or_nil):
          # this field's own validators report against nil while the source's own type validation
          # classifies the bad value.
          Axn::Core::FieldResolvers.extract_or_nil(field: attr, provided_data: @source, permit_method_call: true)
        end
      end

      # Returns the ActiveModel::Errors for one (field, validations) pair against a source (empty if
      # valid).
      def self.collect_errors(field:, validations:, source:, action: nil, reader: nil, config: nil)
        errors_for(validator_class_for(field:, validations:), source:, validations:, action:, reader:, config:)
      end

      # Builds the one-off validator class for a (field, validations) pair. Callers that validate
      # the same contract repeatedly (e.g. ShapeValidator over array elements) can build this once
      # and reuse it across sources via .errors_for, avoiding per-call class compilation.
      def self.validator_class_for(field:, validations:)
        Class.new(self) do
          def self.name = "Axn::Validation::Fields::OneOff"

          # A field may legitimately carry no validators at all (e.g. `optional: true` with no
          # type/model), which `validates` rejects — an empty set means nothing to enforce.
          validates field, **validations unless validations.empty?
        end
      end

      # Runs a validator class against a source and returns its ActiveModel::Errors (empty if valid).
      def self.errors_for(validator_class, source:, validations:, action: nil, reader: nil, config: nil)
        validator = validator_class.new(source)

        # Set the action context for model field resolution + symbol-argument delegation
        validator.instance_variable_set(:@action, action)
        validator.instance_variable_set(:@validations, validations)
        validator.instance_variable_set(:@reader, reader)
        validator.instance_variable_set(:@config, config)

        validator.valid?
        validator.errors
      end

      private

      def _action_for_validation = @action
    end
  end
end
