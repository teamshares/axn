# frozen_string_literal: true

module Axn
  # A small DSL for declaring configuration on a module (e.g. a satellite gem
  # namespace like Axn::MCP), so each one doesn't hand-roll its own config
  # object, yielder, validation, and test reset.
  #
  #   module Axn::MCP
  #     extend Axn::Configurable
  #     setting :mcp_text_content, default: :structured, one_of: %i[structured message]
  #   end
  #
  #   Axn::MCP.config.mcp_text_content        # => :structured
  #   Axn::MCP.configure { |c| c.mcp_text_content = :message }
  #   Axn::MCP.reset_config!                  # primarily for test isolation
  module Configurable
    # Sentinel distinguishing "no argument given" from an explicit nil in the
    # generated class-level override accessors.
    UNSET = Object.new.freeze

    # The config source that owns `namespace` on `klass` or any ancestor, or nil. Walks the same
    # superclass chain the override store uses, so the duplicate-owner guard and the `configure`
    # writer agree on which source (if any) governs a namespace for a given class.
    def self.config_source_for(klass, namespace)
      while klass.is_a?(Module)
        if klass.instance_variable_defined?(:@_axn_config_sources)
          registry = klass.instance_variable_get(:@_axn_config_sources)
          return registry[namespace] if registry.key?(namespace)
        end
        break unless klass.is_a?(Class) && klass.superclass

        klass = klass.superclass
      end
      nil
    end

    Setting = Struct.new(:name, :default, :one_of, :validate, :callable, :overridable, keyword_init: true) do
      # Raises ArgumentError if the assigned value is not permitted.
      def validate!(value)
        raise ArgumentError, "#{name} must be one of #{one_of.map(&:inspect).join(', ')}; got #{value.inspect}" if one_of && !one_of.include?(value)

        return unless validate.respond_to?(:call) && !validate.call(value)

        raise ArgumentError, "#{name} got invalid value: #{value.inspect}"
      end

      # Resolves the stored value, calling it if this setting is declared callable.
      def resolve(value)
        callable && value.respond_to?(:call) ? value.call : value
      end

      # A fresh copy of the default, so mutable defaults (e.g. []) aren't shared
      # across instances. dup is a no-op for nil/true/false/Symbol/Integer.
      def dup_default
        default.dup
      end
    end

    # Per-class override accessors, shared by both config flavors (the
    # module-singleton `Configurable` and the class-level `Settings`). Included
    # into each, so its methods become singleton methods of whatever module/class
    # extends that flavor. The only per-flavor difference is where the resolution
    # fallback reads the library-level value, so `_define_override_methods` takes
    # that as a lambda.
    module PerClassOverrides
      # Returns a module that, when included in an action class, extends it with the
      # per-class override accessors for each overridable setting. `setting` adds to
      # a shared methods module as overridable settings are declared, and Ruby
      # reflects those additions on already-extended classes — so it's insensitive
      # to load order.
      def overrides
        @overrides ||= begin
          methods_module = _override_methods_module
          config_source = self
          Module.new do
            define_singleton_method(:included) do |base|
              # Breadcrumb before extending, while `base`'s own lookup still reflects only its
              # ancestors (not yet axn's accessors), so the check sees a genuine external definition.
              config_source.send(:_warn_on_shadowed_overrides, base)

              # Record which config source owns each namespace on this class, so the tolerant
              # `configure` writer can validate a setter eagerly when the namespace is registered
              # (schema known) and stay tolerant only when it isn't (adapter not loaded / not included).
              config_source.send(:_register_overrides_on, base)

              # `axn_configure` is the always-available, collision-proof writer. Bare `configure` is a
              # generic name a non-axn base class may already own; Ruby places an extended module above
              # the superclass chain, so installing it unconditionally would shadow that base hook and
              # reroute its `configure(...)` calls into axn's writer. Install the ergonomic bare alias
              # only when the name is free — same PRO-2875 discipline the Naming/SchemaReflection generic
              # names use — and always leave `axn_configure` as the guaranteed way to reach axn's config.
              base.extend(ClassConfigWriter)
              shadowed = defined?(Axn::Core::MethodShadowing) &&
                         Axn::Core::MethodShadowing.externally_defined?(base, :configure)
              unless shadowed
                base.define_singleton_method(:configure) do |namespace = :core, &block|
                  axn_configure(namespace, &block)
                end
              end
              base.extend(methods_module)
            end
          end
        end
      end

      # The store namespace this config source owns. Overridable settings and their
      # per-class overrides are keyed by `[namespace, setting]`, so two modules that
      # declare a same-named setting (e.g. a tool composing several adapter mixins)
      # never collide in the consumer class's single override store. Declared once via
      # `config_namespace :mcp`; the symbol is also what `configure(:mcp) { … }` targets.
      # Defaults to the module/class itself — unique per source, so flat-accessor-only
      # consumers stay collision-safe without declaring anything.
      def config_namespace(value = UNSET)
        return (@_config_namespace ||= self) if UNSET.equal?(value)

        # The namespace gets baked in the first time it's used — into each overridable setting's
        # accessor closures (at declaration) and into a class's source registry (at include). Changing
        # it afterward would strand those under the old key while `configure(value)` writes/validates
        # under the new one. Lock on first use and enforce the documented "declare it first" rule.
        if @_config_namespace_locked && value != @_config_namespace
          raise ArgumentError,
                "config_namespace must be declared before any overridable setting is defined or its " \
                "overrides are included (got #{value.inspect} after use under #{(@_config_namespace || self).inspect})"
        end

        @_config_namespace = value
      end

      # Resolves `name` for `klass` through the same override store + fallback the
      # generated accessors use, WITHOUT dispatching to a class method on `klass`.
      # For framework code that consumes an override: the generated `<name>` /
      # `resolved_<name>` readers are all shadowable by a same-named class method
      # on the action (or a subclass), which would silently bypass the override
      # store — so the framework resolves through this registry instead. Raises
      # KeyError if `name` isn't an overridable setting (a declaration-time bug).
      def resolve_override_for(klass, name)
        _override_resolvers.fetch(name.to_sym).call(klass)
      end

      # Eager validation for the `configure` writer when this source owns the namespace being
      # written: rejects a setter name that isn't an overridable setting (a typo that would
      # otherwise store silently and never resolve), then validates the value against the setting.
      def _validate_override_setter!(name, value)
        setting = _override_settings[name.to_sym]
        raise ArgumentError, "unknown overridable setting #{name.inspect} for namespace #{config_namespace.inspect}" unless setting

        setting.validate!(value)
      end

      private

      # Discoverability breadcrumb for the PRO-2875 shadowing class, applied to override accessors.
      # Unlike the generic Naming/SchemaReflection DSLs — which DEFER to a base's same-named method —
      # override accessors are opt-in (the app declared `overridable: true`), so axn still installs
      # them; deferring would silently deny the requested override and would break the reflecting
      # module's late-declaration guarantee. But a collision with a same-named class method on a
      # non-axn ancestor is still worth surfacing rather than shadowing silently, so leave a debug
      # breadcrumb (best-effort: only settings known when `base` includes the overrides module).
      def _warn_on_shadowed_overrides(base)
        return unless defined?(Axn::Core::MethodShadowing) && defined?(Axn.config)

        _override_resolvers.each_key do |name|
          next unless Axn::Core::MethodShadowing.externally_defined?(base, name)

          Axn.config.logger.debug do
            "[Axn] #{base.name || 'Action'}: per-class override accessor `#{name}` collides with a same-named " \
              "class method from a non-axn ancestor (axn installs the accessor anyway; reads route through " \
              "resolve_override_for). See PRO-2856."
          end
        end
      end

      def _override_methods_module
        @_override_methods_module ||= Module.new
      end

      # Overridable Setting objects by name — the schema `_validate_override_setter!` checks against.
      def _override_settings
        @_override_settings ||= {}
      end

      # Records this source as the owner of its namespace on `base`, so `NamespaceWriter` can find
      # the schema (and validate eagerly) for a namespace whose overrides the class actually included.
      def _register_overrides_on(base)
        registry = if base.instance_variable_defined?(:@_axn_config_sources)
                     base.instance_variable_get(:@_axn_config_sources)
                   else
                     base.instance_variable_set(:@_axn_config_sources, {})
                   end
        ns = config_namespace
        # Lock the namespace: it's now baked into this class's registry, so a later change would leave
        # the registration (and duplicate-owner guard) keyed to the wrong bucket.
        @_config_namespace_locked = true
        # Check the whole ancestry, not just this class's local registry: a parent action may already
        # own the namespace (a subclass that adds a second source for it hits the same hazard).
        existing = Axn::Configurable.config_source_for(base, ns)
        # Two different sources under one namespace share the same `[ns][name]` bucket but have
        # different schemas, so `configure(ns)` could only validate against one of them — settings
        # from the other would spuriously raise `unknown` or check against the wrong schema. That's a
        # DSL collision, not a merge; fail fast (re-registering the same source is a no-op).
        if existing && !existing.equal?(self)
          raise ArgumentError,
                "config_namespace #{ns.inspect} is already owned by #{existing} on " \
                "#{base.name || base}; two config sources cannot share a namespace"
        end

        registry[ns] = self
      end

      # Per-setting resolver lambdas, keyed by name — the collision-proof path
      # `resolve_override_for` dispatches through.
      def _override_resolvers
        @_override_resolvers ||= {}
      end

      # Generates `<name>(value = UNSET)` / `raw_<name>` / `resolved_<name>` on the
      # shared methods module. `fallback` is a zero-arg lambda returning the current
      # library-level value for this setting (its own `config` bag for the
      # module-singleton flavor; the live singleton instance for the class flavor).
      #
      # Closure-captured helpers so the generated accessors reference each other
      # through these lambdas rather than public method dispatch — a consumer class
      # that happens to define its own `raw_<name>`/`resolved_<name>` class method
      # can't shadow the internals the other accessors rely on.
      def _define_override_methods(setting, fallback)
        name = setting.name
        namespace = config_namespace
        @_config_namespace_locked = true
        _override_settings[name] = setting

        raw_lookup = lambda do |start|
          klass = start
          while klass.is_a?(Module)
            if klass.instance_variable_defined?(:@_axn_config_overrides)
              slot = klass.instance_variable_get(:@_axn_config_overrides)[namespace]
              return slot[name] if slot&.key?(name)
            end
            break unless klass.is_a?(Class) && klass.superclass

            klass = klass.superclass
          end
          UNSET
        end

        resolve_override = lambda do |start|
          found = raw_lookup.call(start)
          return fallback.call if UNSET.equal?(found)

          # Values written through the tolerant `configure(namespace)` bag are stored
          # unvalidated (core can't see an unloaded adapter's schema), so the owning
          # source validates its own slice here, at read — surfacing a bad value when
          # the adapter first resolves it. Flat-accessor writes already validated, so
          # this is a no-op for them.
          setting.validate!(found)
          setting.resolve(found)
        end

        # Register for the collision-proof `resolve_override_for` path, so framework
        # code never has to dispatch through a shadowable generated accessor.
        _override_resolvers[name] = resolve_override

        _override_methods_module.module_eval do
          define_method(name) do |value = UNSET|
            if UNSET.equal?(value)
              resolve_override.call(self)
            else
              setting.validate!(value)
              ((@_axn_config_overrides ||= {})[namespace] ||= {})[name] = value
            end
          end

          define_method(:"raw_#{name}") { raw_lookup.call(self) }

          define_method(:"resolved_#{name}") { resolve_override.call(self) }
        end
      end
    end

    include PerClassOverrides

    # Extended onto any class that includes an `overrides` module (and thus onto every
    # action via `Axn::Configuration.overrides`), giving it the namespaced `configure`
    # writer. Kept separate from the per-source methods module because `configure` is
    # source-agnostic: one method serves every namespace, so extending it twice (a tool
    # composing several adapters) is idempotent.
    module ClassConfigWriter
      # Sets per-class config for `namespace` via the yielded writer. No namespace ⇒ `:core` (axn's
      # own overridable settings). Always available as `axn_configure`; `configure` is the ergonomic
      # alias installed unless a base class already owns that name (see the `overrides` include hook).
      #
      # When the namespace's source is registered on this class (its `.overrides` were included, so
      # the schema is known — always true for `:core`), setter names and values are validated eagerly,
      # so a typo fails at class definition like the flat setter would. Otherwise the writer is
      # tolerant: it stores any `<setting>=` blindly, so a library can pre-declare `configure(:mcp) { … }`
      # for an adapter absent from this process — the value sits inert until that adapter resolves it
      # (and is validated then). Yielded-receiver + assignment mirrors `Axn.configure { |c| … }`.
      def axn_configure(namespace = :core)
        writer = NamespaceWriter.new(self, namespace)
        yield(writer) if block_given?
        writer
      end
    end

    # The bag `axn_configure`/`configure` yields. Each `<setting>=` writes into the class's
    # `[namespace][setting]` override slot, validating first through the namespace's registered
    # source when there is one (else storing tolerantly for a later validate-on-read).
    class NamespaceWriter
      def initialize(klass, namespace)
        @klass = klass
        @namespace = namespace
      end

      def respond_to_missing?(name, _include_private = false)
        name.to_s.end_with?("=") || super
      end

      def method_missing(name, *args)
        str = name.to_s
        return super unless str.end_with?("=")

        key = str.delete_suffix("=").to_sym
        value = args.first
        _registered_source&._validate_override_setter!(key, value)

        store = @klass.instance_variable_get(:@_axn_config_overrides) ||
                @klass.instance_variable_set(:@_axn_config_overrides, {})
        (store[@namespace] ||= {})[key] = value
      end

      private

      # The config source that owns `@namespace` on `@klass` (or an ancestor), if its overrides were
      # included — nil when the namespace is unregistered (adapter not loaded), which keeps the write tolerant.
      def _registered_source
        Axn::Configurable.config_source_for(@klass, @namespace)
      end
    end

    def _axn_config_settings
      @_axn_config_settings ||= {}
    end

    def setting(name, default: nil, one_of: nil, validate: nil, callable: false, overridable: false)
      name = name.to_sym
      setting = Setting.new(name:, default:, one_of:, validate:, callable:, overridable:)
      _axn_config_settings[name] = setting
      _define_override_methods(setting, -> { config.public_send(setting.name) }) if overridable
      nil
    end

    def config
      @_axn_config ||= Config.new(_axn_config_settings)
    end

    def configure
      yield(config) if block_given?
      config
    end

    def reset_config!
      @_axn_config = nil
    end

    class Config
      def initialize(settings)
        @settings = settings
        @values = {}
      end

      def respond_to_missing?(name, include_private = false)
        base = name.to_s.delete_suffix("?").delete_suffix("=").to_sym
        @settings.key?(base) || super
      end

      def method_missing(name, *args)
        str = name.to_s

        if str.end_with?("=")
          base = str.delete_suffix("=").to_sym
          return super unless @settings.key?(base)

          _write(base, args.first)
        elsif str.end_with?("?")
          base = str.delete_suffix("?").to_sym
          return super unless @settings.key?(base)

          !!_read(base)
        elsif @settings.key?(name)
          _read(name)
        else
          super
        end
      end

      private

      def _write(name, value)
        @settings[name].validate!(value)
        @values[name] = value
      end

      def _read(name)
        setting = @settings[name]
        @values[name] = setting.dup_default unless @values.key?(name)
        setting.resolve(@values[name])
      end
    end

    # Class-level flavor: declare validated *instance* settings on a class,
    # reusing the same Setting kernel (defaults, one_of:/validate:, callable:).
    # Used to dogfood Axn's own Configuration without contorting the
    # module-singleton DSL above. `overridable: true` mints the same per-class
    # override accessors (via PerClassOverrides), resolving their library-level
    # fallback from a live singleton the extending class registers.
    #
    #   class Configuration
    #     extend Axn::Configurable::Settings
    #     overridable_config_source { Axn.config }
    #     setting :log_level, default: :info
    #     setting :sidekiq_job_tag_sources, default: [...], overridable: true
    #   end
    module Settings
      include PerClassOverrides

      # Registers the live singleton whose values are the library-level fallback
      # for per-class overrides (e.g. `Axn.config`). Read lazily on each
      # resolution, so a swapped singleton is picked up. Must be declared before
      # any `overridable: true` setting.
      def overridable_config_source(&block)
        @_overridable_config_source = block
      end

      def setting(name, default: nil, one_of: nil, validate: nil, callable: false, overridable: false)
        setting = Setting.new(name: name.to_sym, default:, one_of:, validate:, callable:, overridable:)
        ivar = :"@#{name}"

        define_method(name) do
          instance_variable_set(ivar, setting.dup_default) unless instance_variable_defined?(ivar)
          setting.resolve(instance_variable_get(ivar))
        end

        define_method(:"#{name}=") do |value|
          setting.validate!(value)
          instance_variable_set(ivar, value)
        end

        return unless overridable

        raise ArgumentError, "setting #{name}: overridable: true requires overridable_config_source to be declared first" unless @_overridable_config_source

        source = @_overridable_config_source
        _define_override_methods(setting, -> { source.call.public_send(setting.name) })
      end
    end
  end
end
