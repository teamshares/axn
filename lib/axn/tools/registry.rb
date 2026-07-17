# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Axn
  module Tools
    # Process-global tool registry: the registered adapter keys and every include-Axn class.
    module Registry
      extend self

      def register_adapter(key, config_source = nil)
        _adapter_sources[key.to_sym] = config_source
      end

      def adapters
        _adapter_sources.keys.to_set
      end

      def adapter_config_source(adapter)
        _adapter_sources[adapter.to_sym]
      end

      def reset_adapters!
        @adapter_sources = {}
      end

      # Called at include-Axn time (direct include) and inherited time (subclasses) for every
      # action class. Idempotent: the backing Set drops a class already present, so a class
      # reachable via more than one path is never enumerated twice by tools_for.
      def register_class(klass)
        _classes << klass
      end

      # Only currently-defined, named classes survive. Every entry that isn't _currently_defined? is
      # deleted from _classes here, releasing its strong ref so a process-global Set can't pin dead
      # classes forever. That covers both cases _currently_defined? rejects: a stale NAMED reference
      # left by a Zeitwerk reload (the reloaded constant points at a fresh object), and a transient
      # anonymous class (name nil) that never got a constant. An anonymous class can never be a usable
      # tool anyway (no stable tool_name, no const_source_location for tool_path membership), and
      # tools_for runs at adapter setup — well after class definition — so the "anonymous now, named
      # later" window is effectively never open at enumeration. Iterates a snapshot (_classes.to_a) so
      # a mid-enumeration registration can't corrupt the backing Set and deleting while walking is safe.
      def all_classes
        live = []
        _classes.to_a.each do |klass|
          if _currently_defined?(klass)
            live << klass
          else
            _classes.delete(klass)
          end
        end
        live
      end

      def tools_for(adapter)
        ensure_loaded!
        members = all_classes.select { |klass| member?(klass, adapter) }
        _assert_unique_tool_names!(members, adapter)
        # Deterministic enumeration regardless of load/registration order. Safe to sort by
        # tool_name because _assert_unique_tool_names! has already guaranteed the names are
        # distinct for this adapter, so there are no ties.
        members.sort_by { |klass| klass.tool_name(adapter) }
      end

      # Ensures tool classes under each adapter's tool roots are loaded before enumeration.
      # Under Rails, unless eager-loading has already completed, hands each existing tool dir to
      # the main Zeitwerk loader via `eager_load_dir`; outside Rails, requires every .rb file
      # under each existing tool dir
      # individually. Both branches rescue `StandardError, ScriptError` — ScriptError covers
      # SyntaxError, LoadError, and NotImplementedError — so any load failure of one unit (a malformed
      # file, a missing require, a raising initializer) is isolated and warn-logged rather than
      # aborting enumeration. Isolation granularity differs by path: outside Rails, each `require` is
      # rescued independently, so one bad FILE is logged at warn and skipped without affecting its
      # siblings. Under Rails, `eager_load_dir` loads a DIRECTORY as a single unit — Zeitwerk has no
      # public API to load or `require` a managed file in isolation — so a file that raises aborts
      # the rest of that directory's files (logged at warn), while every other tool root
      # directory still loads independently.
      def ensure_loaded!
        dirs = _all_adapter_dirs.select { |dir| File.directory?(dir) }
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
            rescue StandardError, ScriptError => e
              expanded = File.expand_path(file)
              _rollback_registrations(before) { |src| src == expanded }
              Axn.config.logger.warn { "[Axn] tool file skipped (#{file}): #{e.class}: #{e.message}" }
            end
          end
        end
      rescue StandardError => e
        Axn.config.logger.warn { "[Axn] tool eager-load skipped: #{e.class}: #{e.message}" }
      end

      # Membership = (directory grant ∪ declaration grant) − except. Directory grant: adapters whose
      # configured tool_roots contain the class's source file. Declaration grant: :all (every adapter),
      # or the explicit adapter list, or a tolerant configure(<adapter>) bag. `tool false` and an
      # excepted adapter both short-circuit to non-membership.
      def member?(klass, adapter)
        return false unless klass.respond_to?(:_tool_declaration)

        decl = klass._tool_declaration
        return false if decl == false
        return false if klass._tool_except.include?(adapter)

        declared_grant = decl == :all || (decl.is_a?(Array) && decl.include?(adapter))
        declared_grant || _under_adapter_root?(klass, adapter) || _declares_adapter_config?(klass, adapter)
      end

      private

      # Two independently-declared classes (different files) can derive or override the same
      # provider-facing tool_name for the same adapter — only knowable once both are loaded and
      # selected here. An adapter that publishes by tool_name would then silently clobber one tool
      # or hand the provider duplicate names, so fail loudly with a fixable message instead. Scoped
      # per-adapter: the same name reused under a DIFFERENT adapter is fine (checked by the caller
      # passing only that adapter's members).
      def _assert_unique_tool_names!(members, adapter)
        collisions = members.group_by { |klass| klass.tool_name(adapter) }.select { |_name, klasses| klasses.length > 1 }
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
      rescue StandardError, ScriptError => e
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

      # True when the class's source file lives under one of `adapter`'s resolved tool_roots.
      def _under_adapter_root?(klass, adapter)
        return false unless klass.name

        dirs = _adapter_dirs(adapter)
        return false if dirs.empty?

        path = Object.const_source_location(klass.name)&.first
        return false unless path

        expanded = File.expand_path(path)
        dirs.any? { |dir| expanded == dir || expanded.start_with?(dir + File::SEPARATOR) }
      rescue StandardError
        false
      end

      # A tolerant configure(<adapter>) write lands in @_axn_config_overrides keyed by the
      # namespace symbol; a registered adapter key there signals implicit membership.
      def _declares_adapter_config?(klass, adapter)
        return false unless _adapter_sources.key?(adapter)

        node = klass
        while node.is_a?(Module)
          store = node.instance_variable_get(:@_axn_config_overrides)
          return true if store.is_a?(Hash) && store.key?(adapter)
          break unless node.is_a?(Class) && node.superclass

          node = node.superclass
        end
        false
      end

      # Resolved, canonical tool directories for one adapter. Re-checks each root against the broad-path
      # guard (the same fail-safe the old global list had): a broad root reaching config via in-place
      # mutation is skipped + warned rather than bulk-exposing every business action.
      def _adapter_dirs(adapter)
        _adapter_roots(adapter).filter_map do |path|
          if Axn::Configuration.broad_tool_path?(path)
            Axn.config.logger.warn do
              "[Axn] tool_roots entry #{path.inspect} for adapter #{adapter.inspect} is too broad; " \
                "skipping (see Axn::Configuration::BROAD_TOOL_PATH_LEAVES)"
            end
            next
          end

          _resolve_tool_dir(path)
        end
      end

      # The raw tool_roots array declared on an adapter's config source, or [] when the adapter has no
      # source or the read fails. Defensive: an adapter may register before its config is set, or with a
      # source that doesn't follow the AdapterRoots contract.
      def _adapter_roots(adapter)
        source = _adapter_sources[adapter]
        return [] unless source.respond_to?(:config)

        roots = source.config.tool_roots
        roots.is_a?(Array) ? roots : []
      rescue StandardError
        []
      end

      # Union of every registered adapter's resolved dirs — the set ensure_loaded! must load before
      # enumeration, since a class in any adapter's root (or declared for any adapter) may surface.
      def _all_adapter_dirs
        adapters.flat_map { |adapter| _adapter_dirs(adapter) }.uniq
      end

      # Normalizes via the same `Axn::Configuration.normalize_tool_path` the `tool_paths=` validator
      # uses (strip + `Pathname#cleanpath`), so an entry like `"actions/./tools"` resolves to the
      # identical dir as its clean spelling `"actions/tools"` instead of a raw, uncollapsed path.
      # `File.expand_path` on the joined result makes the returned dir canonical/absolute, matching
      # how `_under_adapter_root?` expands a class's source path before comparing — without this, the
      # two comparison sides can disagree on an otherwise-equal directory (PRO-2921 follow-up).
      def _resolve_tool_dir(path)
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          # An ABSOLUTE entry (e.g. `Rails.root.join("app/actions/tools").to_s`) is already a real
          # dir — use it directly. Re-rooting it under `Rails.root/app` would strip its leading slash,
          # join a non-`app/`-prefixed path under app, and produce a doubled, nonexistent path. Check
          # the RAW path before normalization (which would collapse the leading slash away).
          return File.expand_path(path.to_s) if File.absolute_path?(path.to_s)

          rel = Axn::Configuration.normalize_tool_path(path)
          rel = rel.delete_prefix("app/") if rel.start_with?("app/")
          File.expand_path(Rails.root.join("app", rel).to_s)
        else
          File.expand_path(path.to_s)
        end
      end

      def _classes
        @classes ||= Set.new
      end

      def _adapter_sources
        @adapter_sources ||= {}
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
