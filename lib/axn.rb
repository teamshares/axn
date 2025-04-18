# frozen_string_literal: true

module Axn; end
require_relative "axn/version"

require "interactor"
require "active_support"

require_relative "action/core/exceptions"
require_relative "action/core/logging"
require_relative "action/core/configuration"
require_relative "action/core/top_level_around_hook"
require_relative "action/core/contract"
require_relative "action/core/swallow_exceptions"
require_relative "action/core/hoist_errors"
require_relative "action/core/enqueueable"

require_relative "axn/factory"

require_relative "action/attachable"

def Axn(callable, **kwargs) # rubocop:disable Naming/MethodName
  return callable if callable.is_a?(Class) && callable < Action

  Axn::Factory.build(**kwargs, &callable)
end

module Action
  def self.included(base)
    base.class_eval do
      include Interactor

      # Include first so other modules can assume `log` is available
      include Logging

      # NOTE: include before any others that set hooks (like contract validation), so we
      # can include those hook executions in any traces set from this hook.
      include TopLevelAroundHook

      include Contract
      include SwallowExceptions

      include HoistErrors

      include Enqueueable

      # --- Extensions ---
      include Attachable

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
end
