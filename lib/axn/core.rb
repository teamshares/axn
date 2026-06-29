# frozen_string_literal: true

require "axn/internal/piping_error"

require "axn/context"

require "axn/strategies"
require "axn/extras"
require "axn/core/hooks"
require "axn/core/logging"
require "axn/core/flow"
require "axn/core/automatic_logging"
require "axn/core/use_strategy"
require "axn/core/nesting_tracking"
require "axn/core/memoization"

# CONSIDER: make class names match file paths?
require "axn/core/validation/validators/model_validator"
require "axn/core/validation/validators/type_validator"
require "axn/core/validation/validators/validate_validator"
require "axn/core/validation/validators/of_validator"
require "axn/core/validation/validators/shape_validator"

require "axn/core/field_resolvers"
require "axn/core/contract"
require "axn/core/contract_for_subfields"
require "axn/core/default_call"

module Axn
  module Core
    module ClassMethods
      def call(**)
        new(**).tap(&:_run).result
      end

      def call!(**)
        result = call(**)
        return result if result.ok?

        # Carry this result's presentation for an ancestor to prefix onto (header aggregation). Scoped
        # to `call!` — transparent bubbling — on purpose: a child run via plain `.call` must NOT leave a
        # carried presentation, or an explicit `.call` + re-raise (e.g. `step`'s bug path) would leak it
        # into the parent. Gated on a declared base/reason so a baseless fallback contributes nothing.
        Axn::Internal::CarriedPresentation.set(result.exception, result.error) if result.send(:_error_from_declared_source?)

        raise result.exception
      end
    end

    def self.included(base)
      base.class_eval do
        extend ClassMethods

        # DSL modules that add class methods/attributes users interact with
        include Core::Hooks
        include Core::Logging
        include Core::AutomaticLogging
        include Core::Flow
        include Core::Contract
        include Core::ContractForSubfields
        include Core::UseStrategy
        include Core::Memoization
        include Core::DefaultCall

        # Internal: tracks nesting depth for logging and duplicate-log suppression
        include Core::NestingTracking

        # Actions are run via the sanctioned entry points (.call / .call!), which build
        # the instance internally. Block direct instantiation so callers can't bypass
        # hooks, validation, and the other guarantees those entry points provide.
        private_class_method :new
      end
    end

    # Main entry point for action execution
    def _run
      Axn::Executor.new(self).run
    end

    def fail!(message = nil, prefixed: true, **exposures)
      expose(**exposures) if exposures.any?
      raise Axn::Failure.new(message, prefixed:, action: self)
    end

    def done!(message = nil, prefixed: true, **exposures)
      expose(**exposures) if exposures.any?
      raise Axn::Internal::EarlyCompletion.new(message, prefixed:)
    end

    private

    def initialize(**)
      @__context = Axn::Context.new(**)
    end
  end
end
