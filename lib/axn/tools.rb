# frozen_string_literal: true

module Axn
  # The tool surface: registering an adapter, enumerating its tools, and validating their contracts.
  #
  # This module is what an adapter gem names. `Registry`, `Invoker`, `AdapterRoots` and `VersionGroup`
  # beneath it are implementation constants an adapter reaches through these methods rather than
  # calling directly — the registry in particular is free to change how membership is stored.
  #
  # `for` is a keyword in statement position, so every call inside axn writes the receiver
  # (`Axn::Tools.for(...)`); a receiverless `for(...)` would parse as a loop.
  module Tools
    class << self
      # Registers an adapter key, optionally with the config source the registry reads `tool_roots`
      # from. Idempotent, and a source-less re-registration never wipes a source already supplied
      # (see Registry#register_adapter).
      def register_adapter(key, config_source = nil)
        Registry.register_adapter(key, config_source)
      end

      # The registered adapter keys. The read-companion to `register_adapter`, and the set every
      # method here validates against.
      def adapters = Registry.adapters

      # An adapter's tools: the latest version per `tool_name` by default, sorted by `tool_name`;
      # every version (by name, then ascending version) with `all_versions: true`.
      def for(adapter, all_versions: false)
        Registry.members(_registered_adapter!(adapter), all_versions:)
      end

      # One logical tool's version group under `adapter` (`.all` ascending, `.latest`), or nil when
      # nothing matches — for an adapter resolving a single name rather than walking the enumeration.
      def versions(adapter, tool_name)
        Registry.version_group(_registered_adapter!(adapter), tool_name)
      end

      private

      # Symbolizes and vets the adapter key, so a typo names the mistake instead of quietly
      # enumerating nothing.
      def _registered_adapter!(adapter)
        adapter = adapter.to_sym
        unless Registry.adapters.include?(adapter)
          raise ArgumentError, "#{adapter.inspect} is not a registered tool adapter (registered: #{Registry.adapters.to_a.inspect})"
        end

        adapter
      end
    end
  end
end
