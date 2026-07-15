# frozen_string_literal: true

module Axn
  module Tools
    # Process-global tool registry: the registered adapter keys, every include-Axn class,
    # membership resolution, and on-demand loading of the configured tool directories.
    module Registry
      extend self

      def register_adapter(key)
        adapters << key.to_sym
      end

      def adapters
        @adapters ||= Set.new
      end

      def reset_adapters!
        @adapters = Set.new
      end

      # Called at include-Axn time for every action class.
      def register_class(klass)
        _classes << klass
      end

      # Only currently-defined, named classes: drops anonymous classes and stale references
      # left behind by a Zeitwerk reload (the reloaded constant points at a fresh object).
      def all_classes
        _classes.select { |k| _currently_defined?(k) }
      end

      def tools_for(_adapter)
        [] # membership resolution added in a later step
      end

      private

      def _classes
        @classes ||= []
      end

      def _currently_defined?(klass)
        name = klass.name
        return false if name.nil? || name.empty?

        klass.name.safe_constantize.equal?(klass)
      rescue StandardError
        false
      end
    end
  end
end
