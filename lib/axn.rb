# frozen_string_literal: true

require "active_support"

module Axn; end
require "axn/version"
require "axn/util"
require "axn/factory"

require "action/configuration"
require "action/exceptions"

require "action/core"

require "action/attachable"
require "action/enqueueable"

def Axn(callable, **) # rubocop:disable Naming/MethodName
  return callable if callable.is_a?(Class) && callable < Action

  Axn::Factory.build(**, &callable)
end

module Action
  def self.included(base)
    base.class_eval do
      include Core

      # --- Extensions ---
      include Attachable
      include Enqueueable

      # Allow additional automatic includes to be configured
      Array(Action.config.additional_includes).each { |mod| include mod }
    end
  end
end
