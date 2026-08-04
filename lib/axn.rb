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
require "axn/extensions/serialization"

# The core implementation
require "axn/core"
require "axn/core/executor"
require "axn/internal/reflection"
require "axn/tools/version_group"
require "axn/tools/registry"
require "axn/tools/adapter_roots"
require "axn/tools/invoker"
require "axn/tools"

# Internal utilities
require "axn/internal/current_call_options"
require "axn/internal/coercion"
require "axn/internal/memoization"
require "axn/internal/callable"
require "axn/internal/cycle_guard"
require "axn/internal/native_methods"
require "axn/internal/shape_graph"
require "axn/internal/call_logger"
require "axn/internal/contract_error_handling"
require "axn/internal/global_id_serialization"
require "axn/internal/async_serialization"
require "axn/internal/rendering"
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
