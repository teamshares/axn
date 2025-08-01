# frozen_string_literal: true

module Axn; end
require_relative "axn/version"
require_relative "axn/util"

require "active_support"

require "action/core"

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
      include Action::Core

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
end
