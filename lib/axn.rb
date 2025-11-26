# frozen_string_literal: true

require "active_support"
require "active_support/concern"

# Standalone
require "axn/version"
require "axn/factory"
require "axn/configuration"
require "axn/exceptions"

# The core implementation
require "axn/core"

# Utilities
require "axn/util/memoization"
require "axn/util/callable"
require "axn/util/logging"
require "axn/form_object"

# Extensions
require "axn/mountable"
require "axn/async"

# Rails integration (if in Rails context)
require "axn/rails/engine" if defined?(Rails) && Rails.const_defined?(:Engine)

module Axn
  def self.included(base)
    base.class_eval do
      include Core

      # --- Extensions ---
      include Mountable
      include Async

      # Allow additional automatic includes to be configured
      Array(Axn.config.additional_includes).each { |mod| include mod }
    end
  end
end
