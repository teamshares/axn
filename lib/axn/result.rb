# frozen_string_literal: true

require "axn/core/context/facade"
require "axn/core/context/facade_inspector"

module Axn
  # Outbound / External ContextFacade
  class Result < ContextFacade
    def initialize(...)
      super
      _define_boolean_predicate_readers
    end

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
            fail! msg, prefixed: false
          end
        end.call
      end
    end

    # External interface
    delegate :ok?, :exception, :elapsed_time, :finalized?, to: :context

    # Memoized: a Result is a snapshot of a finalized context, and resolution can invoke
    # user-supplied message blocks. The lifecycle (logging) and every caller read share the one
    # memoized `@__result`, so resolving once here means those blocks run a single time total.
    def error
      return if ok?

      @__resolved_error = _resolve_error unless defined?(@__resolved_error)
      @__resolved_error
    end

    def success
      return unless ok?

      @__resolved_success = _resolve_success unless defined?(@__resolved_success)
      @__resolved_success
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
                # Three records of "this settled as a failure", in priority order:
                #   1. context flag — durable; survives after the per-execution set is cleared.
                #   2. live classification set — set as soon as ANY action (this one or a nested one,
                #      sticky) classifies the exception. Covers the window where an ancestor's `on_error`
                #      reads outcome *before* the executor sets the context flag on this level.
                #   3. `_fails_on?` — defensive recompute.
                failure = @context.__classified_as_failure? ||
                          Internal::ExceptionClassification.failure?(exception) ||
                          action.class._fails_on?(exception)
                failure ? OUTCOME_FAILURE : OUTCOME_EXCEPTION
              else
                OUTCOME_SUCCESS
              end

      ActiveSupport::StringInquirer.new(label)
    end

    # Internal accessor for the action instance
    # Internal accessor for the underlying action instance (used by introspection/tests); should be
    # private if possible.
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

    def _define_boolean_predicate_readers
      action.external_field_configs.each do |config|
        next unless declared_fields.include?(config.field)
        next unless Axn::Internal::FieldConfig.boolean?(config)

        _define_boolean_predicate_reader(config.field)
      end
    end

    def _define_boolean_predicate_reader(field)
      field_name = field.to_s
      return if field_name.end_with?("?") || field_name.include?(".")

      predicate_name = "#{field_name}?"
      return if singleton_class.method_defined?(predicate_name)

      singleton_class.alias_method predicate_name, field
    end

    def _resolve_error
      reason = _user_provided_error_message
      return _msg_resolver(:error, exception:).resolve_message unless reason

      _fail_prefixed? ? _msg_resolver(:error, exception:).with_base_prefix(reason) : reason
    end

    def _resolve_success
      reason = _user_provided_success_message
      return _msg_resolver(:success, exception: nil).resolve_message unless reason

      @context.__early_completion_prefixed ? _msg_resolver(:success, exception: nil).with_base_prefix(reason) : reason
    end

    def _user_provided_success_message
      @context.__early_completion_message.presence
    end

    def _user_provided_error_message
      return unless exception.is_a?(Axn::Failure)
      return if exception.default_message?

      exception.message.presence
    end

    def _fail_prefixed?
      return true unless exception.is_a?(Axn::Failure)
      # `prefixed: false` is scoped to the action that called `fail!`. A bubbled child Failure
      # resolved at an ancestor still gets the ancestor's base prefix (child opt-out is local).
      return true unless exception.__originating_action.equal?(action)

      exception.prefixed?
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
