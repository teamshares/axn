# frozen_string_literal: true

require "axn/internal/identity"

# Breadcrumbs below go through Extensions.best_effort, so this component needs it whether or not the
# umbrella entrypoint loaded it.
require "axn/extensions"

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

    # Names the DSL installs itself, so a setting cannot be declared with one. Either direction of the
    # collision silently breaks something: a generated `reset!` reader would replace the per-setting
    # reset helper (leaving `reset!(:other)` an arity error), and in the module-singleton flavor
    # `Config#reset!` wins method lookup so the declared setting becomes unreadable. Raise when the
    # class is defined instead.
    RESERVED_SETTING_NAMES = %i[reset!].freeze

    # Canonicalizes a setting name to a Symbol and rejects the reserved ones, RETURNING the canonical
    # form so every downstream use — the registry key, the ivar, the generated methods — derives from
    # one `to_sym`. Calling `to_sym` again after the check would let a name whose `to_sym` answers
    # differently each time pass the guard as one name and install itself as another, which is not
    # only a way past the reserved list but a way to register a setting under a name whose reader and
    # ivar disagree with it.
    def self.canonical_setting_name!(name)
      canonical = name.to_sym
      return canonical unless RESERVED_SETTING_NAMES.include?(canonical)

      raise ArgumentError,
            "setting #{canonical.inspect} is reserved: Axn::Configurable defines #{canonical} on every " \
            "config object. Pick another name."
    end

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

    # Every Setting declared anywhere in `klass`'s own ancestry (via `Settings#setting`), merged
    # into one name => Setting map. Each class in the chain keeps its declarations in its own
    # `@_declared_settings` ivar rather than one shared registry, so a subclass that declares
    # additional settings — without re-extending `Settings` — still needs its instances to see
    # both its own and every ancestor's. Reads the ivar directly (not through `_declared_settings`)
    # so walking the chain never mints an empty registry on a class that never declared anything.
    # A name declared on more than one class in the chain resolves to the most specific (deepest)
    # declaration, since that class's Setting is merged in last.
    def self.declared_settings_for(klass)
      chain = []
      current = klass
      while current.is_a?(Class)
        chain << current
        current = current.superclass
      end

      chain.reverse_each.with_object({}) do |k, settings|
        settings.merge!(k.instance_variable_get(:@_declared_settings)) if k.instance_variable_defined?(:@_declared_settings)
      end
    end

    Setting = Struct.new(:name, :default, :one_of, :validate, :overridable, keyword_init: true) do
      # Raises ArgumentError if the assigned value is not permitted. A `validate:` lambda may return
      # a String instead of `true` to say WHY the value was rejected — worth it for a setting whose
      # value is an object the app supplies, where "invalid" alone doesn't hint at the contract.
      def validate!(value)
        raise ArgumentError, "#{name} must be one of #{one_of.map(&:inspect).join(', ')}; got #{value.inspect}" if one_of && !one_of.include?(value)
        return unless validate.respond_to?(:call)

        outcome = validate.call(value)
        # `String === outcome`, not `outcome.is_a?(String)`: the value comes back from a caller's
        # lambda, and Module#=== settles the type without dispatching anything to it.
        return if outcome && !Axn::Internal::Identity.kind?(outcome, String)

        # A blank reason is no reason: fall back to the plain form below rather than raising with a
        # dangling " — " and nothing after it. Checked without ActiveSupport's blank extensions, since
        # this file is loadable on its own and must not depend on them being present.
        # Rendered to UTF-8 before it is joined: a reason in an incompatible encoding would otherwise
        # raise Encoding::CompatibilityError out of the interpolation, replacing the ArgumentError this
        # method promises with one about encodings.
        # Rendered BEFORE the blank test, not after. `blank_string?` runs `strip`, which raises
        # Encoding::CompatibilityError on invalid UTF-8 — so testing the raw reason first reintroduced
        # the very failure the rendering exists to prevent, one step earlier.
        rendered = Axn::Internal::Identity.utf8_string(outcome) if Axn::Internal::Identity.kind?(outcome, String)
        detail = rendered unless Axn::Internal::Identity.nil_value?(rendered) ||
                                 Axn::Internal::Identity.blank_string?(rendered)
        raise ArgumentError, ["#{name} got invalid value: #{value.inspect}", detail].compact.join(" — ")
      end

      # A Proc default is DYNAMIC: re-derived on every read while the setting is unset, and never
      # stored. Settings whose default depends on the host app's boot state (a tracer that
      # OpenTelemetry may register after axn loads, a Rails.env-derived flag) would otherwise cache
      # an answer taken before that state existed.
      def dynamic_default? = Axn::Internal::Identity.kind?(default, Proc)

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
      # `<name>?` readers are all shadowable by a same-named class method
      # on the action (or a subclass), which would silently bypass the override
      # store — so the framework resolves through this registry instead. Raises
      # KeyError if `name` isn't an overridable setting (a declaration-time bug).
      def resolve_override_for(klass, name)
        _validate_slot_keys!(klass)
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
          [name, :"#{name}?", :"#{name}_override"].each do |accessor|
            next unless Axn::Core::MethodShadowing.externally_defined?(base, accessor)

            Axn::Extensions.best_effort("logging a shadowed override accessor", action: base) do
              Axn.config.logger.debug do
                "[Axn] #{base.name || 'Action'}: per-class override accessor `#{accessor}` collides with a same-named " \
                  "class method from a non-axn ancestor (axn installs the accessor anyway; reads route through " \
                  "resolve_override_for). See PRO-2856."
              end
            end
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

        # A tolerant `configure(ns)` write may have landed keys on `base` before this source was
        # registered (schema unknown then). Now that it's known, reject any that aren't real settings —
        # otherwise a typo'd key would sit orphaned in the slot and never surface.
        _validate_slot_keys!(base)
      end

      # Raises if `klass` (or an ancestor) has a value stored under this namespace whose key isn't an
      # overridable setting — the typo a tolerant `configure(ns)` write couldn't catch when the schema
      # was still unknown. Called from the schema-aware read/registration paths (a no-op once eager
      # write validation applies, since those reject unknown keys up front).
      def _validate_slot_keys!(klass)
        ns = config_namespace
        known = _override_settings
        while klass.is_a?(Module)
          if klass.instance_variable_defined?(:@_axn_config_overrides)
            slot = klass.instance_variable_get(:@_axn_config_overrides)[ns]
            slot&.each_key do |key|
              next if known.key?(key)

              raise ArgumentError, "unknown overridable setting #{key.inspect} for namespace #{ns.inspect}"
            end
          end
          break unless klass.is_a?(Class) && klass.superclass

          klass = klass.superclass
        end
      end

      # Per-setting resolver lambdas, keyed by name — the collision-proof path
      # `resolve_override_for` dispatches through.
      def _override_resolvers
        @_override_resolvers ||= {}
      end

      # Generates `<name>(value = UNSET)` / `<name>?` / `<name>_override` on the
      # shared methods module. `fallback` is a zero-arg lambda returning the current
      # library-level value for this setting (its own `config` bag for the
      # module-singleton flavor; the live singleton instance for the class flavor).
      #
      # Closure-captured helpers so the generated accessors reference each other
      # through these lambdas rather than public method dispatch — a consumer class
      # that happens to define its own same-named class method can't shadow the
      # internals the other accessors rely on.
      def _define_override_methods(setting, fallback)
        name = setting.name
        namespace = config_namespace
        @_config_namespace_locked = true
        _override_settings[name] = setting

        override_lookup = lambda do |start|
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
          found = override_lookup.call(start)
          return fallback.call if UNSET.equal?(found)

          # Values written through the tolerant `configure(namespace)` bag are stored
          # unvalidated (core can't see an unloaded adapter's schema), so the owning
          # source validates its own slice here, at read — surfacing a bad value when
          # the adapter first resolves it. Flat-accessor writes already validated, so
          # this is a no-op for them.
          #
          # An override value is used as-is. A setting's dynamic default still reaches a class with
          # no override of its own, through the `fallback` lambda below, which reads the config's
          # own reader.
          setting.validate!(found)
          found
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

          define_method(:"#{name}?") { !!resolve_override.call(self) }

          define_method(:"#{name}_override") { override_lookup.call(self) }
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
    # Read only by `setting` and `config` below. This module is `extend`ed onto a gem's own namespace
    # module, so a public `_`-prefixed method here lands on that gem's public surface.
    private :_axn_config_settings

    def setting(name, default: nil, one_of: nil, validate: nil, overridable: false)
      name = Axn::Configurable.canonical_setting_name!(name)
      setting = Setting.new(name:, default:, one_of:, validate:, overridable:)
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

      # Returns the named settings to their declared defaults (all of them with no arguments).
      # `reset_config!` on the owning module discards the whole bag; this is the per-setting form,
      # and the supported alternative to assigning nil, which is a VALUE rather than a reset.
      def reset!(*names)
        targets = names.empty? ? @settings.keys : names.map(&:to_sym)
        # Validate the WHOLE list before deleting anything, so a typo alongside a real name cannot
        # leave the config half-reset behind the raise.
        unknown = targets.reject { |name| @settings.key?(name) }
        if unknown.any?
          raise ArgumentError,
                "reset! got unknown setting #{unknown.first.inspect}. Declared settings are: " \
                "#{@settings.keys.map(&:inspect).join(', ')}."
        end

        targets.each { |name| @values.delete(name) }
        self
      end

      private

      def _write(name, value)
        @settings[name].validate!(value)
        @values[name] = value
      end

      def _read(name)
        setting = @settings[name]
        return @values[name] if @values.key?(name)
        return setting.default.call if setting.dynamic_default?

        @values[name] = setting.dup_default
      end
    end

    # Class-level flavor: declare validated *instance* settings on a class,
    # reusing the same Setting kernel (defaults, one_of:/validate:).
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

      # Declared Setting objects by name, on THIS class only — not merged with an ancestor's. The
      # class flavor otherwise keeps no registry (only overridable settings are tracked, by
      # PerClassOverrides). `reset!` reads across the full ancestry via
      # `Axn::Configurable.declared_settings_for`, not through this method, so that walk never
      # mints an empty registry on a class that never declared anything.
      def _declared_settings = @_declared_settings ||= {}

      # `reset!` is an INSTANCE method on the extending class (a config object), so it is installed
      # here rather than declared in this module's body. It resolves the settings it operates on
      # from `self.class` up through its ancestry, so an instance of a subclass sees both settings
      # declared on the subclass and settings declared on any ancestor that extended `Settings` —
      # regardless of whether the subclass re-extends `Settings` itself.
      #
      # A `reset!` the class already provides — its own, or one inherited from a non-axn ancestor —
      # wins: axn generates this one, so it defers rather than replacing behavior the author wrote,
      # leaving a debug breadcrumb instead. Settings still reset through the flat `<name>=` writers.
      def self.extended(base)
        if base.method_defined?(:reset!) || base.private_method_defined?(:reset!)
          if defined?(Axn.config)
            owner = base.instance_method(:reset!).owner
            Axn::Extensions.best_effort("logging a reset! collision", action: base) do
              Axn.config.logger.debug do
                "[Axn] #{base.name || base}: instance method `reset!` is already defined by #{owner}, so the " \
                  "Configurable settings DSL leaves it alone. Per-setting reset is unavailable on this class."
              end
            end
          end
          return
        end

        # INCLUDED as a module rather than defined on the class. A method defined directly on the class
        # outranks every module in the lookup chain, so it would beat a `reset!` the author includes
        # LATER — making the deferral depend on whether their include sits above or below the `extend`.
        # From a module, the class's own definition still wins (as it should) and so does anything
        # included after axn, while the pre-check above still covers what was already there.
        generated = Module.new
        base.include(generated)
        generated.send(:define_method, :reset!) do |*names|
          # Deferral has to be decided HERE, not only at extend time. The pre-check above covers a
          # `reset!` that already existed, and being a module covers one included later on this class —
          # but neither covers one that arrives later on an ANCESTOR, since the generated module sits
          # ahead of the superclass in a subclass's chain and would silently win. `super` resolves to
          # exactly the ancestors below this module, so asking for it makes the deferral independent of
          # whether the author's include ran before or after the extend.
          # Arguments explicit: `define_method` forbids implicit-argument `super`.
          return super(*names) if defined?(super)

          # Not `self.class`: a setting may be named `class`, and its generated reader would shadow the
          # real one — leaving reset! resolving its targets from a setting value.
          declared = Axn::Configurable.declared_settings_for(Axn::Internal::Identity.class_of(self))
          targets = names.empty? ? declared.keys : names.map(&:to_sym)
          # Validate the WHOLE list before touching anything, so `reset!(:real, :typo)` leaves the
          # config exactly as it was instead of half-reset behind the raise.
          unknown = targets.reject { |name| declared.key?(name) }
          if unknown.any?
            raise ArgumentError,
                  "reset! got unknown setting #{unknown.first.inspect}. Declared settings are: " \
                  "#{declared.keys.map(&:inspect).join(', ')}."
          end

          targets.each do |name|
            ivar = :"@#{name}"
            remove_instance_variable(ivar) if instance_variable_defined?(ivar)
          end
          self
        end
      end

      # Registers the live singleton whose values are the library-level fallback
      # for per-class overrides (e.g. `Axn.config`). Read lazily on each
      # resolution, so a swapped singleton is picked up. Must be declared before
      # any `overridable: true` setting.
      def overridable_config_source(&block)
        @_overridable_config_source = block
      end

      def setting(name, default: nil, one_of: nil, validate: nil, overridable: false)
        name = Axn::Configurable.canonical_setting_name!(name)
        setting = Setting.new(name:, default:, one_of:, validate:, overridable:)
        _declared_settings[setting.name] = setting
        ivar = :"@#{name}"

        define_method(name) do
          return instance_variable_get(ivar) if instance_variable_defined?(ivar)
          return setting.default.call if setting.dynamic_default?

          # A literal default IS memoized: mutating it in place (`config.some_list << :x`) is a
          # supported way to extend one, which a fresh dup per read would silently discard.
          instance_variable_set(ivar, setting.dup_default)
        end

        define_method(:"#{name}?") { !!public_send(name) }

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
