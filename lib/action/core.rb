# frozen_string_literal: true

require "action/context"

require "action/strategies"
require "action/core/hooks"
require "action/core/logging"
require "action/core/hoist_errors"
require "action/core/handle_exceptions"
require "action/core/automatic_logging"
require "action/core/use_strategy"
require "action/core/tracing"

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
    # Outcome constants for action execution results
    OUTCOME_SUCCESS = :success
    OUTCOME_FAILURE = :failure
    OUTCOME_EXCEPTION = :exception

    def self.included(base)
      base.class_eval do
        extend ClassMethods
        include Core::Hooks
        include Core::Logging
        include Core::AutomaticLogging
        include Core::Tracing

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
        new(context).tap(&:run).result
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

    # Main entry point for action execution
    def run
      with_tracing do
        with_logging do
          with_exception_swallowing do # Exceptions stop here; outer wrappers access result status (and must not introduce another exception layer)
            with_contract do # Library internals -- any failures (e.g. contract violations) *should* fail the Action::Result
              with_hooks do # User hooks -- any failures here *should* fail the Action::Result
                call
              end
            end
          end
        end
      end
    ensure
      _emit_metrics
    end

    # User-defined action logic - override this method in your action classes
    def call; end

    private

    def _emit_metrics
      return unless Action.config.emit_metrics

      Action.config.emit_metrics.call(
        self.class.name || "AnonymousClass",
        _determine_outcome,
      )
    rescue StandardError => e
      Axn::Util.piping_error("running metrics hook", action: self, exception: e)
    end

    def _determine_outcome
      return OUTCOME_EXCEPTION if @context.exception
      return OUTCOME_FAILURE if @context.failure?

      OUTCOME_SUCCESS
    end
  end
end
