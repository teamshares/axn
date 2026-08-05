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

# Rails integration (if in Rails context).
#
# A bare `if defined?(Rails)` here would be evaluated once and never revisited, so a host that
# requires axn BEFORE Rails would silently never get the engine -- `require "axn"` is a no-op by
# the time Rails exists. That is the normal order in a conventional Rails test suite, where
# `.rspec` loads a Rails-free `spec_helper.rb` (the file we tell people to put
# `require "axn/testing/spec_helpers"` in) ahead of the `rails_helper.rb` that boots the app.
# Without the engine, `app/actions` never gets its configured autoload namespace and every
# constant under it is unresolvable -- in the test environment only.
#
# `:before_configuration` runs from `Rails::Application#initialize`, well before railties are
# collected, so an engine defined there is still picked up. ActiveSupport is already loaded (see
# the top of this file), and `on_load` fires immediately if the hook has already run, so the
# deferred branch is safe whenever Rails arrives.
if defined?(Rails) && Rails.const_defined?(:Engine)
  require "axn/rails/engine"
else
  ActiveSupport.on_load(:before_configuration) { require "axn/rails/engine" }
end

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
