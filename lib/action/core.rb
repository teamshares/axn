# frozen_string_literal: true

require "action/context"

require "action/strategies"
require "action/core/hooks"
require "action/core/logging"
require "action/core/hoist_errors"
require "action/core/handle_exceptions"
require "action/core/automatic_logging"
require "action/core/use_strategy"

# CONSIDER: make class names match file paths?
require "action/core/validation/validators/model_validator"
require "action/core/validation/validators/type_validator"
require "action/core/validation/validators/validate_validator"

require "action/core/contract_validation"
require "action/core/contract"
require "action/core/contract_for_subfields"
require "action/core/timing"

module Action
  module Core
    def self.included(base)
      base.class_eval do
        extend ClassMethods
        include Core::Hooks
        include Core::Logging
        include Core::AutomaticLogging

        include Core::HandleExceptions

        include Core::ContractValidation
        include Core::Contract
        include Core::ContractForSubfields

        include Core::HoistErrors
        include Core::UseStrategy
      end
    end

    module ClassMethods
      def call(context = {})
        # TODO: can clean up the external_context naming now that we're not exposing #context at all
        new(context).tap(&:run).external_context
      end

      def call!(context = {})
        result = call(context)
        return result if result.ok?

        raise result.exception || Action::Failure.new(result.error)
      end
    end

    def initialize(context = {})
      @context = Action::Context.build(context)
    end

    def with_tracing(&)
      return yield unless Action.config.trace_hook

      Action.config.trace_hook.call(self.class.name || "AnonymousClass", &)
    end

    def with_logging
      timing_start = Core::Timing.now
      _log_before
      yield
    ensure
      _log_after(timing_start:, outcome: _determine_outcome)
    end

    def with_contract
      _apply_inbound_preprocessing!
      _apply_defaults!(:inbound)
      _validate_contract!(:inbound)

      yield

      _apply_defaults!(:outbound)
      _validate_contract!(:outbound)

      # TODO: improve location of this triggering
      trigger_on_success if respond_to?(:trigger_on_success)
    end

    def run
      with_tracing do
        with_logging do
          with_contract do
            # User hooks and implementation
            with_hooks do
              call
              @context.called!(self)
            end
          end
        end
      end
    rescue StandardError => e
      @context.rollback!

      # on_error handlers run for both unhandled exceptions and fail!
      self.class._error_handlers.each do |handler|
        handler.execute_if_matches(exception: e, action: self)
      end

      # on_failure handlers run ONLY for fail!
      if e.is_a?(Action::Failure)
        @context.instance_variable_set("@error_from_user", e.message) if e.message.present?

        self.class._failure_handlers.each do |handler|
          handler.execute_if_matches(exception: e, action: self)
        end
      else
        # on_exception handlers run for ONLY for unhandled exceptions. AND NOTE: may be skipped if the exception is rescued via `rescues`.
        trigger_on_exception(e)

        @context.exception = e
      end

      @context.instance_variable_set("@failure", true)
    ensure
      # Always emit metrics, regardless of success/failure/exception
      _emit_metrics
    end

    def call; end
    def rollback; end

    private

    def _emit_metrics
      return unless Action.config.metrics_hook

      Action.config.metrics_hook.call(
        self.class.name || "AnonymousClass",
        _determine_outcome,
      )
    end

    def _determine_outcome
      return "exception" if @context.exception
      return "failure" if @context.failure?

      "success"
    end
  end
end
