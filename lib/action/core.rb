# frozen_string_literal: true

require "action/context"

require "action/strategies"
require "action/core/hooks"
require "action/core/logging"
require "action/core/flow"
require "action/core/automatic_logging"
require "action/core/use_strategy"
require "action/core/timing"
require "action/core/tracing"
require "action/core/nesting_tracking"

# CONSIDER: make class names match file paths?
require "action/core/validation/validators/model_validator"
require "action/core/validation/validators/type_validator"
require "action/core/validation/validators/validate_validator"

require "action/core/contract_validation"
require "action/core/contract"
require "action/core/contract_for_subfields"

module Action
  module Core
    def self.included(base)
      base.class_eval do
        extend ClassMethods
        include Core::Hooks
        include Core::Logging
        include Core::AutomaticLogging
        include Core::Tracing
        include Core::Timing

        include Core::Flow

        include Core::ContractValidation
        include Core::Contract
        include Core::ContractForSubfields
        include Core::NestingTracking

        include Core::UseStrategy
      end
    end

    module ClassMethods
      def call(**)
        new(**).tap(&:_run).result
      end

      def call!(**)
        result = call(**)
        return result if result.ok?

        # When we're nested, we want to raise a failure that includes the source action to support
        # the error message generation's `from` filter
        raise Action::Failure.new(result.error, source: result.__action__), cause: result.exception if _nested_in_another_axn?

        raise result.exception
      end
    end

    def initialize(**)
      @__context = Action::Context.new(**)
    end

    # Main entry point for action execution
    def _run
      _tracking_nesting(self) do
        _with_tracing do
          _with_logging do
            _with_timing do
              _with_exception_handling do # Exceptions stop here; outer wrappers access result status (and must not introduce another exception layer)
                _with_contract do # Library internals -- any failures (e.g. contract violations) *should* fail the Action::Result
                  _with_hooks do # User hooks -- any failures here *should* fail the Action::Result
                    call
                  end
                end
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

    def fail!(message = nil)
      raise Action::Failure, message
    end

    private

    def _emit_metrics
      return unless Axn.config.emit_metrics

      Axn.config.emit_metrics.call(
        self.class.name || "AnonymousClass",
        result,
      )
    rescue StandardError => e
      Axn::Util.piping_error("running metrics hook", action: self, exception: e)
    end
  end
end
