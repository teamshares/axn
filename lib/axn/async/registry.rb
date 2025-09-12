# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Axn
  module Async
    class AdapterNotFound < StandardError; end
    class DuplicateAdapterError < StandardError; end

    class Registry
      # rubocop:disable Style/ClassVars
      class << self
        def built_in
          return @@built_in if defined?(@@built_in)

          adapter_files = Dir[File.join(__dir__, "adapters", "*.rb")]
          adapter_files.each { |file| require file }

          constants = Axn::Async::Adapters.constants.map { |const| Axn::Async::Adapters.const_get(const) }
          mods = constants.select { |const| const.is_a?(Module) }

          @@built_in = mods.to_h do |mod|
            name = mod.name.split("::").last
            # Convert CamelCase to snake_case using ActiveSupport
            key = name.underscore.to_sym
            [key, mod]
          end
        end

        def register(name, adapter)
          all # ensure built_in is initialized
          key = name.to_sym
          raise DuplicateAdapterError, "Adapter #{name} already registered" if @@adapters.key?(key)

          @@adapters[key] = adapter
          @@adapters
        end

        def all
          @@adapters ||= built_in.dup
        end

        def clear!
          @@adapters = built_in.dup
        end

        def find(name)
          raise AdapterNotFound, "Adapter name cannot be nil" if name.nil?
          raise AdapterNotFound, "Adapter name cannot be empty" if name.to_s.strip.empty?

          all[name.to_sym] or raise AdapterNotFound, "Adapter '#{name}' not found"
        end
      end
      # rubocop:enable Style/ClassVars
    end
  end
end
