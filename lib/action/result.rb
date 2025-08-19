# frozen_string_literal: true

require "action/core/context/facade"
require "action/core/context/facade_inspector"

module Action
  # Outbound / External ContextFacade
  class Result < ContextFacade
    # For ease of mocking return results in tests
    class << self
      def ok(msg = nil, **exposures)
        exposes = exposures.keys.to_h { |key| [key, { allow_blank: true }] }

        Axn::Factory.build(exposes:, success: msg) do
          exposures.each do |key, value|
            expose(key, value)
          end
        end.call
      end

      def error(msg = nil, **exposures, &block)
        exposes = exposures.keys.to_h { |key| [key, { allow_blank: true }] }

        Axn::Factory.build(exposes:, error: msg) do
          exposures.each do |key, value|
            expose(key, value)
          end
          if block_given?
            begin
              block.call
            rescue StandardError => e
              # Set the exception directly without triggering on_exception handlers
              @__context.__record_exception(e)
            end
          else
            fail! msg
          end
        end.call
      end
    end

    # External interface
    delegate :ok?, :exception, :elapsed_time, to: :context

    def error
      return if ok?

      _user_provided_error_message || _resolver(:error, exception:).resolve_message
    end

    def success
      return unless ok?

      _user_provided_success_message || _resolver(:success, exception: nil).resolve_message
    end

    def message = exception ? error : success

    def default_error = _resolver(:error, exception: exception || Action::Failure.new).resolve_default_message
    def default_success = _resolver(:success, exception: nil).resolve_default_message

    # Outcome constants for action execution results
    OUTCOMES = [
      OUTCOME_SUCCESS = :success,
      OUTCOME_FAILURE = :failure,
      OUTCOME_EXCEPTION = :exception,
    ].freeze

    def outcome
      return OUTCOME_FAILURE if exception&.is_a?(Action::Failure)
      return OUTCOME_EXCEPTION if exception

      OUTCOME_SUCCESS
    end

    # Internal accessor for the action instance
    # TODO: exposed for errors :from support, but should be private if possible
    def __action__ = @action

    private

    def _context_data_source = @context.exposed_data

    # TODO: hook for adding early-return success at some point
    def _user_provided_success_message = nil

    def _user_provided_error_message
      return unless exception&.is_a?(Action::Failure)
      return if exception.default_message?
      return if exception.cause # We raised this ourselves from nesting

      exception.message.presence
    end

    def _resolver(event_type, exception:)
      Action::Core::Flow::Handlers::Resolvers::MessageResolver.new(
        action._messages_registry,
        event_type,
        action:,
        exception:,
      )
    end

    def method_missing(method_name, ...) # rubocop:disable Style/MissingRespondToMissing (because we're not actually responding to anything additional)
      if @context.__combined_data.key?(method_name.to_sym)
        msg = <<~MSG
          Method ##{method_name} is not available on Action::Result!

          #{action_name} may be missing a line like:
            exposes :#{method_name}
        MSG

        raise Action::ContractViolation::MethodNotAllowed, msg
      end

      super
    end
  end
end
