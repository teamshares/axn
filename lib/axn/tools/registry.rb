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
      # Iterates a snapshot (_classes.to_a) so a mid-enumeration registration can't corrupt the
      # backing Set and so deleting from _classes while walking is safe. Definitively-stale NAMED
      # entries (a non-empty name that no longer resolves to this very object) are deleted from
      # _classes here, releasing the strong ref so a Rails reload can't pin dead classes forever.
      # Anonymous entries are only excluded from the return value, never deleted: an anonymous class
      # may still be assigned to a constant later and become live.
      def all_classes
        live = []
        _classes.to_a.each do |klass|
          if _currently_defined?(klass)
            live << klass
          elsif (n = klass.name) && !n.empty?
            _classes.delete(klass)
          end
        end
        live
      end

      def tools_for(adapter)
        ensure_loaded!
        members = all_classes.select { |klass| member?(klass, adapter) }
        _assert_unique_tool_names!(members, adapter)
        members
      end

      # Ensures tool classes under the configured tool_paths are loaded before enumeration.
      # Under Rails, unless eager-loading has already completed, hands each existing tool dir to
      # the main Zeitwerk loader via `eager_load_dir`; outside Rails, requires every .rb file
      # under each existing tool dir
      # individually. Isolation granularity differs by path: outside Rails, each `require` is
      # rescued independently, so one bad FILE is logged at warn and skipped without affecting its
      # siblings. Under Rails, `eager_load_dir` loads a DIRECTORY as a single unit — Zeitwerk has no
      # public API to load or `require` a managed file in isolation — so a file that raises aborts
      # the rest of that directory's files (logged at warn), while every other `tool_paths`
      # directory still loads independently.
      def ensure_loaded!
        dirs = _tool_dirs.select { |dir| File.directory?(dir) }
        return if dirs.empty?

        if _rails_app?
          # `config.eager_load` only says Rails INTENDS to eager-load; that phase runs late in boot
          # (after config/initializers). Skip the on-demand load only once the app has finished
          # initializing (eager-load has actually run), so a tools_for call from within an
          # initializer still loads the tool dirs on demand.
          return if Rails.application.config.eager_load &&
                    Rails.application.respond_to?(:initialized?) && Rails.application.initialized?

          loader = Rails.autoloaders.main
          # The engine only pushes app/actions into Zeitwerk `after: :load_config_initializers`
          # (see Axn::RailsIntegration::Engine), so a `tools_for` call from within a
          # `config/initializers` file runs BEFORE that hook — a configured tool dir can exist on
          # disk yet not be one Zeitwerk manages. `eager_load_dir` on an unmanaged dir would just
          # raise and get rescued below, silently yielding an empty/partial tool list. We don't push
          # dirs ourselves here (that's the engine's job, with its own namespace) — instead we check
          # Zeitwerk's own managed-root list (`loader.dirs`) up front and warn loudly so the caller
          # knows discovery may be incomplete, rather than degrading silently.
          managed_roots = loader.respond_to?(:dirs) ? loader.dirs : nil
          dirs.each { |dir| _eager_load_rails_dir(loader, dir, managed_roots) }
        else
          dirs.each do |dir|
            Dir.glob(File.join(dir, "**", "*.rb")).each do |file|
              # Snapshot _classes before the require so that if the file registers an Axn class (via
              # include/inherited) and THEN raises later in the same file, we can roll those
              # registrations back — otherwise a "skipped" file would still leak its classes into
              # tools_for. The loop is single-threaded, so a before/after diff is exact. Scope the
              # rollback to classes SOURCED FROM this file: a dependency the file `require`d before
              # raising was registered in the same window but belongs to its own (valid) file, and
              # Ruby marks that file loaded so a later glob iteration would no-op — dropping it here
              # would leave the valid tool's constant defined yet permanently absent from _classes.
              before = _classes.dup
              require file
            rescue StandardError, LoadError => e
              expanded = File.expand_path(file)
              _rollback_registrations(before) { |src| src == expanded }
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

      # Two independently-declared classes (different files) can derive or override the same
      # provider-facing tool_name for the same adapter — only knowable once both are loaded and
      # selected here. An adapter that publishes by tool_name would then silently clobber one tool
      # or hand the provider duplicate names, so fail loudly with a fixable message instead. Scoped
      # per-adapter: the same name reused under a DIFFERENT adapter is fine (checked by the caller
      # passing only that adapter's members).
      def _assert_unique_tool_names!(members, adapter)
        collisions = members.group_by(&:tool_name).select { |_name, klasses| klasses.length > 1 }
        return if collisions.empty?

        details = collisions.map { |tname, klasses| "#{tname.inspect} (#{klasses.map(&:name).sort.join(', ')})" }.join("; ")
        raise ArgumentError,
              "Duplicate tool_name for adapter #{adapter.inspect}: #{details}. Two tools cannot share a " \
              "provider name; give one an explicit `tool name: \"...\"` to disambiguate."
      end

      # Eager-loads a single Rails tool dir, or warns and skips it if Zeitwerk doesn't manage it
      # yet (see the boot-ordering comment in `ensure_loaded!`). `managed_roots` is nil when the
      # loader predates `#dirs` (older Zeitwerk), in which case the manage-check is skipped
      # entirely and behavior is unchanged from before this check existed.
      def _eager_load_rails_dir(loader, dir, managed_roots)
        return unless loader.respond_to?(:eager_load_dir)

        if managed_roots&.none? { |root| dir == root || dir.start_with?(root + File::SEPARATOR) }
          Axn.config.logger.warn do
            "[Axn] tool dir #{dir} is not yet managed by the Rails autoloader — tools_for was likely called " \
              "before Rails finished initializing (e.g. from a config/initializers file). Tool discovery may " \
              "be incomplete; enumerate tools from `config.after_initialize` or a `to_prepare` block for " \
              "reliable results."
          end
          return
        end

        # Snapshot _classes before eager-loading the directory so a file that raises partway
        # through can't leak the classes it already registered into tools_for. Zeitwerk loads a
        # directory as a unit, so rollback granularity is per-DIRECTORY: drop only added classes
        # whose source file lives under this dir. A class a file `require`d from OUTSIDE the dir
        # is preserved (it isn't this directory's tool).
        before = _classes.dup
        loader.eager_load_dir(dir)
      rescue StandardError, LoadError => e
        _rollback_registrations(before) do |src|
          src == dir || src.start_with?(dir + File::SEPARATOR)
        end
        Axn.config.logger.warn { "[Axn] tool dir skipped (#{dir}): #{e.class}: #{e.message}" }
      end

      # Rolls back registrations added since `before`, deleting each added class whose (expanded)
      # source file satisfies the block predicate. Shared by both eager-load branches so the
      # scoping loop lives in one place. Added classes with no resolvable source (anonymous classes
      # return nil) are left registered — they're excluded from tools_for by the name filter anyway,
      # and dropping one risks unregistering a nested dependency's not-yet-named class.
      def _rollback_registrations(before)
        (_classes - before).each do |added|
          src = _class_source_file(added)
          next unless src

          _classes.delete(added) if yield(File.expand_path(src))
        end
      end

      # The file a class was defined in, or nil. For an already-defined constant this does NOT
      # autoload (the class was just loaded); anonymous classes (nil/empty name) return nil.
      def _class_source_file(klass)
        name = klass.name
        return nil if name.nil? || name.empty?

        Object.const_source_location(name)&.first
      rescue StandardError
        nil
      end

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

      # Normalizes via the same `Axn::Configuration.normalize_tool_path` the `tool_paths=` validator
      # uses (strip + `Pathname#cleanpath`), so an entry like `"actions/./tools"` resolves to the
      # identical dir as its clean spelling `"actions/tools"` instead of a raw, uncollapsed path.
      # `File.expand_path` on the joined result makes the returned dir canonical/absolute, matching
      # how `_under_tool_path?` expands a class's source path before comparing — without this, the
      # two comparison sides can disagree on an otherwise-equal directory (PRO-2921 follow-up).
      def _resolve_tool_dir(path)
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          rel = Axn::Configuration.normalize_tool_path(path)
          rel = rel.delete_prefix("app/") if rel.start_with?("app/")
          File.expand_path(Rails.root.join("app", rel).to_s)
        else
          File.expand_path(path)
        end
      end

      def _classes
        @classes ||= Set.new
      end

      # A class is "currently defined" iff its name resolves — WITHOUT triggering any autoload — to
      # the very same object. This deliberately avoids String#safe_constantize, which would autoload
      # a pending constant (a stale entry left by a Rails reload) purely to decide staleness — both a
      # surprising enumeration side-effect and a re-entrancy hazard (the loaded file may include Axn
      # and mutate _classes mid-enumeration).
      def _currently_defined?(klass)
        name = klass.name
        return false if name.nil? || name.empty?

        _loaded_constant(name).equal?(klass)
      end

      # Resolves a "::"-separated constant name against already-loaded constants only, returning the
      # constant or nil. Walks from Object; at each segment bails (nil) unless the current module
      # defines it directly (const_defined?(segment, false)) as a genuinely-loaded constant — a
      # pending autoload (autoload?(segment) truthy) counts as not-yet-live and is NOT triggered.
      def _loaded_constant(name)
        name.split("::").reduce(Object) do |mod, segment|
          return nil unless mod.is_a?(Module)
          return nil unless mod.const_defined?(segment, false)
          return nil if mod.autoload?(segment)

          mod.const_get(segment, false)
        end
      rescue NameError
        nil
      end
    end
  end
end
