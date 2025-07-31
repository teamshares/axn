# frozen_string_literal: true

module Axn; end
require_relative "axn/version"
require_relative "axn/util"

require "interactor/context"
require "interactor/error"
require "interactor/hooks"

require "active_support"

require_relative "action/core/validation/validators/model_validator"
require_relative "action/core/validation/validators/type_validator"
require_relative "action/core/validation/validators/validate_validator"

require_relative "action/core/exceptions"
require_relative "action/core/logging"
require_relative "action/core/configuration"
require_relative "action/core/top_level_around_hook"
require_relative "action/core/contract"
require_relative "action/core/contract_for_subfields"
require_relative "action/core/handle_exceptions"
require_relative "action/core/hoist_errors"
require_relative "action/core/use_strategy"

require_relative "axn/factory"

require_relative "action/attachable"
require_relative "action/enqueueable"
require_relative "action/strategies"

def Axn(callable, **) # rubocop:disable Naming/MethodName
  return callable if callable.is_a?(Class) && callable < Action

  Axn::Factory.build(**, &callable)
end

module Action
  def self.included(base)
    base.class_eval do
      # *** START -- CORE INTERNALS ***
      extend ClassMethods
      include Interactor::Hooks

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

      # --- Extensions ---
      include Attachable
      include Enqueueable

      # Allow additional automatic includes to be configured
      Array(Action.config.additional_includes).each { |mod| include mod }

      # ----

      # ALPHA: Everything below here is to support inheritance

      base.define_singleton_method(:inherited) do |base_klass|
        return super(base_klass) if Interactor::Hooks::ClassMethods.private_method_defined?(:ancestor_hooks)

        raise StepsRequiredForInheritanceSupportError
      end
    end
  end

  module ClassMethods
    def call(context = {})
      new(context).tap(&:run).context
    end

    def call!(context = {})
      new(context).tap(&:run!).context
    end
  end

  def initialize(context = {})
    @context = Interactor::Context.build(context)
  end

  def run
    run!
  rescue Interactor::Failure
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
