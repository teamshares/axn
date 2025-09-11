# frozen_string_literal: true

require "axn/internal/logging"

require "axn/context"

require "axn/strategies"
require "axn/core/hooks"
require "axn/core/logging"
require "axn/core/flow"
require "axn/core/automatic_logging"
require "axn/core/use_strategy"
require "axn/core/timing"
require "axn/core/tracing"
require "axn/core/nesting_tracking"

# CONSIDER: make class names match file paths?
require "axn/core/validation/validators/model_validator"
require "axn/core/validation/validators/type_validator"
require "axn/core/validation/validators/validate_validator"

require "axn/core/contract_validation"
require "axn/core/contract_validation_for_subfields"
require "axn/core/contract"
require "axn/core/contract_for_subfields"

module Axn
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
        include Core::ContractValidationForSubfields
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
        raise Axn::Failure.new(result.error, source: result.__action__), cause: result.exception if _nested_in_another_axn?

        raise result.exception
      end
    end

    def initialize(**)
      @__context = Axn::Context.new(**)
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
      raise Axn::Failure, message
    end

    def done!(message = nil)
      raise Axn::Internal::EarlyCompletion, message
    end

    private

    def _emit_metrics
      return unless Axn.config.emit_metrics

      Axn.config.emit_metrics.call(
        self.class.name || "AnonymousClass",
        result,
      )
    rescue StandardError => e
      Axn::Internal::Logging.piping_error("running metrics hook", action: self, exception: e)
    end
  end
end
