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
require "axn/reflection"
require "axn/tools/version_group"
require "axn/tools/registry"
require "axn/tools/adapter_roots"
require "axn/tools/invoker"

# Internal utilities
require "axn/internal/current_call_options"
require "axn/internal/memoization"
require "axn/internal/callable"
require "axn/internal/cycle_guard"
require "axn/internal/shape_graph"
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

  def self.tools_for(adapter, all_versions: false)
    adapter = _registered_tool_adapter!(adapter)
    Axn::Tools::Registry.tools_for(adapter, all_versions:)
  end

  # Validates every tool axn's contract, once each, and raises on the first invalid one.
  #
  # A colliding or unrenderable property name is only harmful to a JSON projection, and for a tool axn the
  # projection is what an adapter hands a model — so the moment to learn about it is app setup, not a user's
  # tool call. This loads the configured tool directories and projects each tool once; the per-class memo means a
  # later `input_schema` from an adapter pays nothing.
  #
  # Under Rails this runs automatically (`config.after_initialize`, and again on each `config.to_prepare` so a
  # dev reload re-validates). Without Rails there is no boot to hook, so an app calls this itself — typically
  # right after requiring its action files. Nothing else changes if it is never called: the same errors still
  # raise on first projection.
  #
  # TWO COVERAGE HOLES, deliberately not papered over:
  #
  # 1. Under Rails, Zeitwerk's `eager_load_dir` loads a directory as one unit (it has no public API to load a
  #    managed file in isolation), so a file that raises aborts the rest of THAT directory — warn-logged by the
  #    registry, and the siblings it skipped are never validated here.
  # 2. An axn made a tool by the `tool` DSL in a file OUTSIDE the configured tool directories is not loaded at
  #    boot in a dev environment, so it is not enumerable yet and falls back to validating on first projection.
  #
  # Both narrow the set this covers; neither makes an invalid contract reachable without any error at all.
  def self.validate_tool_contracts!
    Axn::Tools::Registry.tool_classes.each do |klass|
      klass.input_schema if klass.respond_to?(:input_schema)
      klass.output_schema if klass.respond_to?(:output_schema)
    rescue Axn::ContractViolation, ArgumentError => e
      # Named, because this runs over every tool at once: the underlying error describes the property and the
      # declarations that collide, but at boot the first thing an author needs is WHICH tool. Re-raised as the
      # same class so a caller matching on it still matches, with the original as `cause`. Both families are
      # caught: a collision is an Axn::ContractViolation, an unrenderable name or an oversized schema an
      # ArgumentError.
      raise e.class, "#{Axn::Internal::ClassName.of_module(klass)} has an invalid tool contract — #{e.message}"
    end
    nil
  end

  def self.versions_for(adapter, tool_name)
    adapter = _registered_tool_adapter!(adapter)
    Axn::Tools::Registry.versions_for(adapter, tool_name)
  end

  def self._registered_tool_adapter!(adapter)
    adapter = adapter.to_sym
    unless Axn::Tools::Registry.adapters.include?(adapter)
      raise ArgumentError, "#{adapter.inspect} is not a registered tool adapter (registered: #{Axn::Tools::Registry.adapters.to_a.inspect})"
    end

    adapter
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
