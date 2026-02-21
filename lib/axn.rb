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
require "axn/executor"

# Internal utilities
require "axn/internal/memoization"
require "axn/internal/callable"
require "axn/internal/call_logger"
require "axn/internal/piping_error"
require "axn/util/execution_context"
require "axn/internal/contract_error_handling"
require "axn/internal/global_id_serialization"
require "axn/internal/exception_context"
require "axn/internal/subfield_path"
require "axn/internal/field_config"
require "axn/internal/timing"
require "axn/internal/tracing"
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

# Load after Axn is defined since it includes Axn
require "axn/async/enqueue_all_orchestrator"
