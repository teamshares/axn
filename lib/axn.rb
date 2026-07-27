# frozen_string_literal: true

require "active_support"
require "active_support/concern"

# Standalone
require "axn/version"
require "axn/field_declarations"
require "axn/factory"
require "axn/configurable"
require "axn/configuration"
require "axn/exceptions"
require "axn/extensions"
require "axn/extensions/config"

# The core implementation
require "axn/core"
require "axn/core/executor"
require "axn/reflection"
require "axn/tools/registry"
require "axn/tools/adapter_roots"
require "axn/tools/invoker"

# Internal utilities
require "axn/internal/current_call_options"
require "axn/internal/memoization"
require "axn/internal/callable"
require "axn/internal/call_logger"
require "axn/internal/contract_error_handling"
require "axn/internal/global_id_serialization"
require "axn/internal/async_serialization"
require "axn/internal/exception_context"
require "axn/internal/exception_classification"
require "axn/internal/carried_presentation"
require "axn/internal/field_config"
require "axn/internal/timing"
require "axn/internal/tracing"
require "axn/form_object"

# Utilities (possibly useful for downstream users)
require "axn/util/execution_context"

# Extensions
require "axn/mountable"
require "axn/async"

# Rails integration (if in Rails context)
require "axn/rails/engine" if defined?(Rails) && Rails.const_defined?(:Engine)

module Axn
  # Whether axn owns this exception's #message (and may stamp the resolved presentation onto it).
  # Foreign exceptions reclassified via fails_on are NOT owned — they keep their technical cause.
  def self.owns_failure_exception?(exception)
    exception.is_a?(Axn::Failure) || Axn::ValidationError.user_facing?(exception)
  end

  def self.register_tool_adapter(key, config_source = nil)
    Axn::Tools::Registry.register_adapter(key, config_source)
  end

  def self.tools_for(adapter)
    adapter = adapter.to_sym
    unless Axn::Tools::Registry.adapters.include?(adapter)
      raise ArgumentError, "#{adapter.inspect} is not a registered tool adapter (registered: #{Axn::Tools::Registry.adapters.to_a.inspect})"
    end

    Axn::Tools::Registry.tools_for(adapter)
  end

  def self.included(base)
    # Re-including Axn (e.g. `include Axn` in a subclass of an existing Axn) would re-run
    # setup and reset the inheritance-aware class_attributes that hold field configs,
    # silently wiping the parent's expects/exposes. Inheritance already carries everything
    # down, so treat a redundant inclusion as a no-op.
    return if base < Core

    base.class_eval do
      include Core

      # --- Extensions ---
      include Mountable
      include Async

      # Allow additional automatic includes to be configured
      Array(Axn.config.additional_includes).each { |mod| include mod }
    end

    Axn::Tools::Registry.register_class(base)
  end
end

# Load after Axn is defined since it includes Axn
require "axn/async/enqueue_all_orchestrator"
