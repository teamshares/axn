# frozen_string_literal: true

require "active_support/parameter_filter"

module Action
  class ContextFacade
    def initialize(action:, context:, declared_fields:, implicitly_allowed_fields: nil)
      if self.class.name == "Action::ContextFacade" # rubocop:disable Style/ClassEqualityComparison
        raise "Action::ContextFacade is an abstract class and should not be instantiated directly"
      end

      @context = context
      @action = action
      @declared_fields = declared_fields

      (@declared_fields + Array(implicitly_allowed_fields)).each do |field|
        singleton_class.define_method(field) do
          context_data_source[field]
        end
      end
    end

    attr_reader :declared_fields

    def inspect = ContextFacadeInspector.new(facade: self, action:, context:).call

    def fail!(...)
      raise Action::ContractViolation::MethodNotAllowed, "Call fail! directly rather than on the context"
    end

    private

    attr_reader :action, :context

    def action_name = @action.class.name.presence || "The action"

    def context_data_source = raise NotImplementedError

    def determine_error_message(only_default: false)
      return @context.error_from_user if @context.error_from_user.present?

      # We need an exception for interceptors, and also in case the messages.error callable expects an argument
      exception = @context.exception || Action::Failure.new

      # Try message handlers in order; pick first non-blank (non-static first)
      unless only_default
        Array(action.class._messages_registry&.for(:error)).each do |handler|
          next if handler.respond_to?(:static?) && handler.static?

          msg = handler.execute_if_matches(action:, exception:)
          return msg if msg.present?
        end
      end

      # Try static error message entries (registered via .error); else default
      Array(action.class._messages_registry&.for(:error)).each do |handler|
        next unless handler.respond_to?(:static?) && handler.static?

        msg = handler.execute_if_matches(action:, exception:)
        return msg if msg.present?
      end

      "Something went wrong"
    end

    def determine_success_message
      # Prefer conditional success interceptors if any match; first non-blank wins
      Array(action.class._messages_registry&.for(:success)).each do |handler|
        msg = handler.execute_if_matches(action:, exception: nil)
        return msg if msg.present?
      end

      # Try static success message entries (registered via .success); else default
      Array(action.class._messages_registry&.for(:success)).each do |handler|
        next unless handler.respond_to?(:static?) && handler.static?

        msg = handler.execute_if_matches(action:, exception: nil)
        return msg if msg.present?
      end

      "Action completed successfully"
    end

    # Adapter now lives in handlers
  end
end
