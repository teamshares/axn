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

    def _axn_config_settings
      @_axn_config_settings ||= {}
    end

    def setting(name, default: nil, one_of: nil, validate: nil, callable: false, overridable: false)
      name = name.to_sym
      setting = Setting.new(name:, default:, one_of:, validate:, callable:, overridable:)
      _axn_config_settings[name] = setting
      _define_override_methods(setting) if overridable
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

    # Returns a module that, when included in an action class, adds class-level
    # override accessors for each `overridable: true` setting:
    #
    #   <name>(value = UNSET)   # set a class-level override, or read the resolved value
    #   resolved_<name>         # resolve: nearest class override in the ancestry, else library config
    #   raw_<name>               # nearest class override in the ancestry, or UNSET if none is set
    #                             # (no config fallback, no Setting#resolve) — for a caller that needs
    #                             # to distinguish "no override" from "resolves to the library default"
    #
    # Overrides are stored per-class and inherited by subclasses. Declaration
    # order doesn't matter: the accessors live on a shared module the action
    # extends, so settings declared after the action includes this still appear.
    def overrides
      @overrides ||= begin
        methods_module = _override_methods_module
        Module.new do
          define_singleton_method(:included) { |base| base.extend(methods_module) }
        end
      end
    end

    private

    # A persistent module whose instance methods become class methods on any
    # action that extends it (via `include overrides`). `setting` adds to it as
    # overridable settings are declared, and Ruby reflects those additions on
    # already-extended classes — so it's insensitive to load order.
    def _override_methods_module
      @_override_methods_module ||= Module.new
    end

    def _define_override_methods(setting)
      name = setting.name
      config_source = self

      # Closure-captured helpers so the generated accessors reference each other
      # through these lambdas rather than public method dispatch — a consumer
      # class that happens to define its own `raw_<name>`/`resolved_<name>` class
      # method can't shadow the internals the other accessors rely on.
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
        UNSET.equal?(found) ? config_source.config.public_send(name) : setting.resolve(found)
      end

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
    # module-singleton DSL above.
    #
    #   class Configuration
    #     extend Axn::Configurable::Settings
    #     setting :log_level, default: :info
    #   end
    module Settings
      def setting(name, default: nil, one_of: nil, validate: nil, callable: false)
        setting = Setting.new(name: name.to_sym, default:, one_of:, validate:, callable:, overridable: false)
        ivar = :"@#{name}"

        define_method(name) do
          instance_variable_set(ivar, setting.dup_default) unless instance_variable_defined?(ivar)
          setting.resolve(instance_variable_get(ivar))
        end

        define_method(:"#{name}=") do |value|
          setting.validate!(value)
          instance_variable_set(ivar, value)
        end
      end
    end
  end
end
