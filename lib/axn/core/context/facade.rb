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
        singleton_class.define_method(field) do
          _context_data_source[field]
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

    def action_name = @action.class.name.presence || "The action"

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
