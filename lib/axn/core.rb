# frozen_string_literal: true

require "axn/context"

require "axn/strategies"
require "axn/extras"
require "axn/core/hooks"
require "axn/core/method_shadowing"
require "axn/core/naming"
require "axn/core/tools"
require "axn/core/logging"
require "axn/core/flow"
require "axn/core/automatic_logging"
require "axn/core/tagging"
require "axn/core/use_strategy"
require "axn/core/nesting_tracking"
require "axn/core/memoization"
require "axn/core/extension_metadata"
require "axn/core/semantic_hints"
require "axn/core/schema_reflection"

# CONSIDER: make class names match file paths?
require "axn/core/validation/validators/model_validator"
require "axn/core/validation/validators/type_validator"
require "axn/core/validation/validators/validate_validator"
require "axn/core/validation/validators/of_validator"
require "axn/core/validation/validators/shape_validator"

require "axn/core/field_resolvers"
require "axn/core/ambient_context"
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
        # into the parent. Two gates: (1) only when an Axn ancestor is still on the stack to consume it
        # — at the OUTERMOST `call!`, `call` above has already unwound NestingTracking (and run its
        # reset), so a write here would have no consumer and no later reset (a thread-local leak that
        # also pins the Failure's __originating_action/context); (2) only when a base/reason was actually
        # declared, so a baseless fallback contributes nothing.
        if Core::NestingTracking._current_axn_stack.any? && result.send(:_error_from_declared_source?)
          Axn::Internal::CarriedPresentation.set(result.exception, result.error)
        end

        raise result.exception
      end
    end

    def self.included(base)
      base.class_eval do
        extend ClassMethods

        # DSL modules that add class methods/attributes users interact with
        include Core::Hooks
        include Core::Naming
        include Core::Tools
        include Core::Logging
        include Core::AutomaticLogging
        include Core::Tagging
        include Core::Flow
        include Core::AmbientContext
        include Core::Contract
        include Core::ContractForSubfields
        include Core::UseStrategy
        include Core::Memoization
        include Core::DefaultCall
        include Core::ExtensionMetadata
        include Core::SemanticHints
        include Core::SchemaReflection

        # Per-class config overrides: gives the action class-level accessors
        # (`<name>` setter/reader, `<name>?`, `<name>_override`) for every
        # `overridable: true` setting on Axn.config. See Axn::Configurable.
        include Axn::Configuration.overrides

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

    def fail!(message = nil, standalone: false, **exposures)
      expose(**exposures) if exposures.any?
      raise Axn::Failure.new(message, standalone:, action: self)
    end

    def done!(message = nil, standalone: false, **exposures)
      expose(**exposures) if exposures.any?
      raise Axn::Internal::EarlyCompletion.new(message, standalone:)
    end

    private

    def initialize(**)
      @__context = Axn::Context.new(**)
    end
  end
end
