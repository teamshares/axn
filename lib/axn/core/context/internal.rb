# frozen_string_literal: true

require "axn/core/context/facade"

module Axn
  module Core
    # Inbound / Internal ContextFacade
    class InternalContext < ContextFacade
      def default_error = _msg_resolver(:error, exception: Axn::Failure.new).resolve_default_message
      def default_success = _msg_resolver(:success, exception: nil).resolve_default_message

      private

      def _context_data_source = @context.provided_data

      # Inbound fields resolve through the read-path seam (coerce/preprocess/default applied on read,
      # provided_data never mutated). A field with no config (implicitly-allowed) keeps the raw source
      # read. Model fields resolve through the shared resolve_model_value (record + sibling-id + default).
      def _define_reader_for(field)
        config = action.internal_field_configs.find { |c| c.field == field }
        return super if config.nil?

        if config.validations.key?(:model)
          Axn::Internal::Memoization.define_memoized_reader_method(singleton_class, field) do
            Axn::Core::ContractForSubfields.resolve_model_value(action, config, config.validations[:model])
          end
        else
          singleton_class.define_method(field) do
            Axn::Core::ContractForSubfields.resolve_value(action, config)
          end
        end
      end

      def method_missing(method_name, ...) # rubocop:disable Style/MissingRespondToMissing (because we're not actually responding to anything additional)
        if @context.__combined_data.key?(method_name.to_sym)
          msg = <<~MSG
            Method ##{method_name} is not available on Axn::Core::InternalContext!

            #{action_name} may be missing a line like:
              expects :#{method_name}
          MSG

          raise Axn::ContractViolation::MethodNotAllowed, msg
        end

        super
      end
    end
  end
end
