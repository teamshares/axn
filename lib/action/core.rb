# frozen_string_literal: true

require "interactor/context"

require "action/strategies"
require "action/core/hooks"

require_relative "core/validation/validators/model_validator"
require_relative "core/validation/validators/type_validator"
require_relative "core/validation/validators/validate_validator"

require_relative "core/exceptions"
require_relative "core/logging"
require_relative "core/configuration"
require_relative "core/top_level_around_hook"
require_relative "core/contract"
require_relative "core/contract_for_subfields"
require_relative "core/handle_exceptions"
require_relative "core/hoist_errors"
require_relative "core/use_strategy"

module Action
  module Core
    def self.included(base)
      base.class_eval do
        # *** START -- CORE INTERNALS ***
        extend ClassMethods
        include Core::Hooks

        # Public: Gets the Interactor::Context of the Interactor instance.
        attr_reader :context

        # *** END -- CORE INTERNALS ***

        # Include first so other modules can assume `log` is available
        include Logging

        # NOTE: include before any others that set hooks (like contract validation), so we
        # can include those hook executions in any traces set from this hook.
        include TopLevelAroundHook

        include HandleExceptions
        include Contract
        include ContractForSubfields

        include HoistErrors

        include UseStrategy
      end
    end

    module ClassMethods
      def call(context = {})
        new(context).tap(&:run).context
      end

      def call!(context = {})
        result = call(context)
        return result if result.ok?

        raise result.exception || Action::Failure.new(result.error)
      end
    end

    def initialize(context = {})
      @context = Interactor::Context.build(context)
    end

    def run
      run!
    rescue StandardError => e
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
    end

    def run!
      with_hooks do
        call
        context.called!(self)
      end
    rescue StandardError
      context.rollback!
      raise
    end

    def call; end
    def rollback; end
  end
end
