# frozen_string_literal: true

require "active_support/parameter_filter"

module Axn
  module Core
    class ContextFacade
      def initialize(action:, context:, declared_fields:, implicitly_allowed_fields: nil)
        if self.class.name == "Axn::Core::ContextFacade" # rubocop:disable Style/ClassEqualityComparison
          raise "Axn::Core::ContextFacade is an abstract class and should not be instantiated directly"
        end

        @context = context
        @action = action
        @declared_fields = declared_fields

        (@declared_fields + Array(implicitly_allowed_fields)).each do |field|
          _define_reader_for(field)
        end
      end

      attr_reader :declared_fields

      def inspect = ContextFacadeInspector.new(facade: self, action:, context:).call

      def fail!(...)
        raise Axn::ContractViolation::MethodNotAllowed, "Call fail! directly rather than on the context"
      end

      private

      attr_reader :action, :context

      # Define one field's reader. The base (outbound Result) facade reads the data source directly;
      # InternalContext overrides this to resolve declared inbound fields through the read path.
      def _define_reader_for(field)
        if _model_fields.key?(field)
          _define_model_field_method(field, _model_fields[field])
        else
          singleton_class.define_method(field) do
            _context_data_source[field]
          end
        end
      end

      def _model_fields = action.class._model_fields

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
          action.class._messages_registry,
          event_type,
          action:,
          exception:,
        )
      end
    end
  end
end
