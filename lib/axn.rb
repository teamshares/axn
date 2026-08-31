# frozen_string_literal: true

require "active_support"
require "active_support/concern"
# ActiveModel validates `numericality: { in: range }` through `Object#in?` (its `RANGE_CHECKS` is
# `{ in: :in? }`), which is a core extension `require "active_support"` does not load — so the option
# declared cleanly and raised `NoMethodError` on every call outside Rails, while working inside it. Required
# explicitly rather than reaching for `active_support/all`, which would pull in far more than axn depends on.
require "active_support/core_ext/object/inclusion"

# Named rather than relied on transitively. The declaration guards name `BigDecimal` in their closed equality
# world, and those lists are frozen at load time — so a `BigDecimal` that arrived later would be missing from
# them and the refusals it earns would silently stop firing. It is loaded either way today (activemodel's
# `numericality.rb` requires it, eagerly, via `validations.rb`), which is exactly what makes depending on that
# accident the wrong thing to do: nothing here would notice if activemodel stopped.
require "bigdecimal"

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
require "axn/extensions/tracing"

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
require "axn/internal/action_state"
require "axn/internal/name_ownership"
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
require "axn/internal/transparent_bubbling"
require "axn/internal/field_config"
require "axn/internal/timing"
require "axn/internal/tracing"
require "axn/form_object"

# Utilities (possibly useful for downstream users)
require "axn/util/execution_context"

# Extensions
require "axn/mountable"
require "axn/async"

# Rails integration. The `defined?` check runs once and re-requiring axn is a no-op, so a host that
# loads axn before Rails -- the conventional RSpec layout does -- would otherwise never get the
# engine. `:before_configuration` fires from `Rails::Application#initialize`, before railties are
# collected, and runs immediately if Rails is already past that point.
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

    # Last, so the module it installs outranks every module the class_eval above included — including
    # `Axn.config.additional_includes`. A name the user's own hierarchy owns wins over axn's helper.
    Core::InstanceDeferral.install(base)

    Axn::Tools::Registry.register_class(base)
  end
end

# Load after Axn is defined since it includes Axn
require "axn/async/enqueue_all_orchestrator"
