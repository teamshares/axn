# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Axn
  module Tools
    # Process-global tool registry: the registered adapter keys and every include-Axn class.
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

      # Called at include-Axn time (direct include) and inherited time (subclasses) for every
      # action class. Idempotent: the backing Set drops a class already present, so a class
      # reachable via more than one path is never enumerated twice by tools_for.
      def register_class(klass)
        _classes << klass
      end

      # Only currently-defined, named classes: drops anonymous classes and stale references
      # left behind by a Zeitwerk reload (the reloaded constant points at a fresh object).
      def all_classes
        _classes.select { |k| _currently_defined?(k) }
      end

      def tools_for(adapter)
        ensure_loaded!
        all_classes.select { |klass| member?(klass, adapter) }
      end

      # Ensures tool classes under the configured tool_paths are loaded before enumeration.
      # Under Rails with eager_load off, hands each existing tool dir to the main Zeitwerk
      # loader; outside Rails, requires every .rb under each existing tool dir. Best-effort per
      # file/dir: a single bad file or dir is logged at warn and skipped, never aborting the rest.
      def ensure_loaded!
        dirs = _tool_dirs.select { |dir| File.directory?(dir) }
        return if dirs.empty?

        if _rails_app?
          return if Rails.application.config.eager_load

          loader = Rails.autoloaders.main
          dirs.each do |dir|
            next unless loader.respond_to?(:eager_load_dir)

            loader.eager_load_dir(dir)
          rescue StandardError, LoadError => e
            Axn.config.logger.warn { "[Axn] tool dir skipped (#{dir}): #{e.class}: #{e.message}" }
          end
        else
          dirs.each do |dir|
            Dir.glob(File.join(dir, "**", "*.rb")).each do |file|
              require file
            rescue StandardError, LoadError => e
              Axn.config.logger.warn { "[Axn] tool file skipped (#{file}): #{e.class}: #{e.message}" }
            end
          end
        end
      rescue StandardError => e
        Axn.config.logger.warn { "[Axn] tool eager-load skipped: #{e.class}: #{e.message}" }
      end

      # Fail-safe membership: an explicit declaration wins; else auto-register when the class's
      # source file lives under a configured tool_path dir; else treat a configure(<adapter>) bag
      # for a registered adapter key as implicit membership for that adapter; else not a tool.
      def member?(klass, adapter)
        return false unless klass.respond_to?(:_tool_declaration)

        case (decl = klass._tool_declaration)
        when false then false
        when :all then true
        when Array then decl.include?(adapter)
        else
          _under_tool_path?(klass) || _declares_adapter_config?(klass, adapter)
        end
      end

      private

      def _rails_app?
        defined?(Rails) && Rails.respond_to?(:application) && Rails.application
      end

      def _under_tool_path?(klass)
        return false unless klass.name

        path = Object.const_source_location(klass.name)&.first
        return false unless path

        expanded = File.expand_path(path)
        _tool_dirs.any? { |dir| expanded == dir || expanded.start_with?(dir + File::SEPARATOR) }
      rescue StandardError
        false
      end

      # A tolerant configure(<adapter>) write lands in @_axn_config_overrides keyed by the
      # namespace symbol; a registered adapter key there signals implicit membership.
      def _declares_adapter_config?(klass, adapter)
        return false unless adapters.include?(adapter)

        node = klass
        while node.is_a?(Module)
          store = node.instance_variable_get(:@_axn_config_overrides)
          return true if store.is_a?(Hash) && store.key?(adapter)
          break unless node.is_a?(Class) && node.superclass

          node = node.superclass
        end
        false
      end

      # Feeds both eager-loading (ensure_loaded!) and membership (_under_tool_path?), so both are
      # protected by the same fail-safe: re-checks each entry against the setter's own broad-path
      # predicate rather than trusting `tool_paths=` already enforced it. The setter can't catch an
      # entry that reaches the live array without going through it — in-place mutation
      # (`Axn.config.tool_paths << "actions"`), a mutated reference held after assignment, or the
      # never-assigned default array (also mutable) — so a broad entry smuggled in this way is
      # skipped here and logged, never silently auto-registering every business action.
      def _tool_dirs
        Array(Axn.config.tool_paths).filter_map do |path|
          if Axn::Configuration.broad_tool_path?(path)
            Axn.config.logger.warn { "[Axn] tool_paths entry #{path.inspect} is too broad; skipping (see Axn::Configuration::TOOL_PATHS_BLOCKLIST)" }
            next
          end

          _resolve_tool_dir(path)
        end
      end

      def _resolve_tool_dir(path)
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          rel = path.to_s.strip.sub(%r{\A/+}, "")
          rel = rel.delete_prefix("app/") if rel.start_with?("app/")
          Rails.root.join("app", rel).to_s
        else
          File.expand_path(path)
        end
      end

      def _classes
        @classes ||= Set.new
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
