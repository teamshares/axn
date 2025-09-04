# frozen_string_literal: true

require "active_support"

# Standalone
require "axn/version"
require "axn/factory"
require "axn/configuration"
require "axn/exceptions"

# The core implementation
require "axn/core"

# Extensions
require "axn/attachable"
require "axn/enqueueable"

module Axn
  def self.included(base)
    base.class_eval do
      include Core

      # --- Extensions ---
      include Attachable
      include Enqueueable

      # Allow additional automatic includes to be configured
      Array(Axn.config.additional_includes).each { |mod| include mod }
    end
  end
end
