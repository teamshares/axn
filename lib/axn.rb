# frozen_string_literal: true

module Axn; end
require_relative "axn/version"

require "interactor"

require "active_support"

require_relative "action/exceptions"
require_relative "action/logging"
require_relative "action/configuration"
require_relative "action/top_level_around_hook"
require_relative "action/contract"
require_relative "action/swallow_exceptions"
require_relative "action/hoist_errors"

require_relative "action/enqueueable"

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
