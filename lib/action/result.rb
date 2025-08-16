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
              @__context.exception = e
              @__context.send(:failure=, true)
            end
          else
            fail!
          end
        end.call
      end
    end

    # Poke some holes for necessary internal control methods
    delegate :each_pair, to: :context

    # External interface
    delegate :ok?, :exception, to: :context

    def error
      return if ok?

      return @context.error_from_user if @context.error_from_user.present?

      msg = action.class._custom_message_for(:error, action:, exception: @context.exception)
      msg.presence || "Something went wrong"
    end

    def success
      return unless ok?

      msg = action.class._custom_message_for(:success, action:, exception: nil)
      msg.presence || "Action completed successfully"
    end

    def message = error || success

    def default_error = _find_first_static_message(:error) || "Something went wrong"
    def default_success = _find_first_static_message(:success) || "Action completed successfully"

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

    # Elapsed time in milliseconds
    def elapsed_time
      @context.elapsed_time
    end

    # Internal accessor for the action instance
    # TODO: exposed for errors :from support, but should be private if possible
    def __action__ = @action

    private

    def context_data_source = @context.exposed_data

    def _find_first_static_message(event_type)
      # The registry stores handlers in "last-defined-first" order, so we need to reverse
      # to get the order they were defined (first-defined-first)
      action.class._messages_registry.for(event_type).reverse.each do |handler|
        # A handler is static if it has no matcher (no conditions)
        if handler.static?
          msg = handler.apply(action:, exception: @context.exception)
          return msg if msg.present?
        end
      end
      nil
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
