# frozen_string_literal: true

require "active_support/parameter_filter"

module Axn
  class ContextFacade
    def initialize(action:, context:, declared_fields:, implicitly_allowed_fields: nil)
      if self.class.name == "Axn::ContextFacade" # rubocop:disable Style/ClassEqualityComparison
        raise "Axn::ContextFacade is an abstract class and should not be instantiated directly"
      end

      @context = context
      @action = action
      @declared_fields = declared_fields

      (@declared_fields + Array(implicitly_allowed_fields)).each do |field|
        if _model_fields.key?(field)
          _define_model_field_method(field, _model_fields[field])
        else
          singleton_class.define_method(field) do
            _context_data_source[field]
          end
        end
      end
    end

    attr_reader :declared_fields

    def inspect = ContextFacadeInspector.new(facade: self, action:, context:).call

    def fail!(...)
      raise Axn::ContractViolation::MethodNotAllowed, "Call fail! directly rather than on the context"
    end

    private

    attr_reader :action, :context

    def _model_fields
      action.internal_field_configs.each_with_object({}) do |config, hash|
        hash[config.field] = config.validations[:model] if config.validations.key?(:model)
      end
    end

    def action_name = @action.class.name.presence || "The action"

    def _define_model_field_method(field, options)
      Axn::Internal::Memoization.define_memoized_reader_method(singleton_class, field) do
        Axn::Core::FieldResolvers.resolve(
          type: :model,
          field:,
          options:,
          provided_data: _context_data_source,
        )
      end
    end

    def _context_data_source = raise NotImplementedError

    def _msg_resolver(event_type, exception:)
      Axn::Core::Flow::Handlers::Resolvers::MessageResolver.new(
        action._messages_registry,
        event_type,
        action:,
        exception:,
      )
    end
  end
end
