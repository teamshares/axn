# frozen_string_literal: true

require "axn/core/context/facade"
require "axn/core/context/facade_inspector"

module Axn
  # Outbound / External ContextFacade
  class Result < ContextFacade
    # For ease of mocking return results in tests
    class << self
      def ok(msg = nil, **exposures)
        exposes = exposures.keys.to_h { |key| [key, { optional: true }] }

        Axn::Factory.build(exposes:, success: msg, log_calls: false, log_errors: false) do
          exposures.each do |key, value|
            expose(key, value)
          end
        end.call
      end

      def error(msg = nil, **exposures, &block)
        exposes = exposures.keys.to_h { |key| [key, { optional: true }] }

        Axn::Factory.build(exposes:, error: msg, log_calls: false, log_errors: false) do
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
    delegate :ok?, :exception, :elapsed_time, :finalized?, to: :context

    def error
      return if ok?

      _user_provided_error_message || _msg_resolver(:error, exception:).resolve_message
    end

    def success
      return unless ok?

      _user_provided_success_message || _msg_resolver(:success, exception: nil).resolve_message
    end

    def message = exception ? error : success

    # Outcome constants for action execution results
    OUTCOMES = [
      OUTCOME_SUCCESS = "success",
      OUTCOME_FAILURE = "failure",
      OUTCOME_EXCEPTION = "exception",
    ].freeze

    def outcome
      label = if exception.is_a?(Axn::Failure)
                OUTCOME_FAILURE
              elsif exception
                OUTCOME_EXCEPTION
              else
                OUTCOME_SUCCESS
              end

      ActiveSupport::StringInquirer.new(label)
    end

    # Internal accessor for the action instance
    # TODO: exposed for errors :from support, but should be private if possible
    def __action__ = @action

    # Enable pattern matching support for Ruby 3+
    def deconstruct_keys(keys)
      attrs = {
        ok: ok?,
        success:,
        error:,
        message:,
        outcome: outcome.to_sym,
        finalized: finalized?,
      }

      # Add all exposed data
      attrs.merge!(@context.exposed_data)

      # Return filtered attributes if keys specified
      keys ? attrs.slice(*keys) : attrs
    end

    private

    def _context_data_source = @context.exposed_data

    def _user_provided_success_message
      @context.__early_completion_message.presence
    end

    def _user_provided_error_message
      return unless exception.is_a?(Axn::Failure)
      return if exception.default_message?
      return if exception.cause # We raised this ourselves from nesting

      exception.message.presence
    end

    def method_missing(method_name, ...) # rubocop:disable Style/MissingRespondToMissing (because we're not actually responding to anything additional)
      if @context.__combined_data.key?(method_name.to_sym)
        msg = <<~MSG
          Method ##{method_name} is not available on Action::Result!

          #{action_name} may be missing a line like:
            exposes :#{method_name}
        MSG

        raise Axn::ContractViolation::MethodNotAllowed, msg
      end

      super
    end
  end
end
