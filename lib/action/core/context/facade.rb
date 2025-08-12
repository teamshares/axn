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

      msg = action._error_msg

      unless only_default
        interceptor = action.class._error_interceptor_for(exception:, action:)
        msg = interceptor.message if interceptor
      end

      stringified(msg, exception:).presence || "Something went wrong"
    end

    # Allow for callable OR string messages
    def stringified(msg, exception: nil)
      return msg.presence unless msg.respond_to?(:call)

      # The error message callable can take the exception as an argument
      if exception && msg.arity == 1
        action.instance_exec(exception, &msg)
      else
        action.instance_exec(&msg)
      end
    rescue StandardError => e
      Axn::Util.piping_error("determining message callable", action:, exception: e)
    end
  end
end
