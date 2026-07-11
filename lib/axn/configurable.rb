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
          Module.new do
            define_singleton_method(:included) { |base| base.extend(methods_module) }
          end
        end
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

      private

      def _override_methods_module
        @_override_methods_module ||= Module.new
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

        raw_lookup = lambda do |start|
          klass = start
          while klass.is_a?(Module)
            if klass.instance_variable_defined?(:@_axn_config_overrides)
              store = klass.instance_variable_get(:@_axn_config_overrides)
              return store[name] if store.key?(name)
            end
            break unless klass.is_a?(Class) && klass.superclass

            klass = klass.superclass
          end
          UNSET
        end

        resolve_override = lambda do |start|
          found = raw_lookup.call(start)
          UNSET.equal?(found) ? fallback.call : setting.resolve(found)
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
              (@_axn_config_overrides ||= {})[name] = value
            end
          end

          define_method(:"raw_#{name}") { raw_lookup.call(self) }

          define_method(:"resolved_#{name}") { resolve_override.call(self) }
        end
      end
    end

    include PerClassOverrides

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
