# frozen_string_literal: true

require "active_support"

module Axn; end
require "axn/version"
require "axn/internal/logging"
require "axn/factory"

require "axn/configuration"
require "axn/exceptions"

require "axn/core"

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
