# frozen_string_literal: true

RSpec.describe Axn::Configurable do
  let(:configurable) do
    Module.new do
      extend Axn::Configurable

      setting :default_model, default: "gpt-4o-mini"
      setting :mcp_text_content, default: :structured, one_of: %i[structured message]
      setting :enabled, default: true
    end
  end

  describe ".config" do
    it "exposes the declared default" do
      expect(configurable.config.default_model).to eq("gpt-4o-mini")
    end

    it "round-trips an assigned value" do
      configurable.config.default_model = "claude"
      expect(configurable.config.default_model).to eq("claude")
    end

    it "raises NoMethodError for an unknown setting" do
      expect { configurable.config.nonexistent }.to raise_error(NoMethodError)
    end
  end

  describe ".configure" do
    it "yields the config for assignment" do
      configurable.configure { |c| c.default_model = "claude" }
      expect(configurable.config.default_model).to eq("claude")
    end
  end

  describe ".reset_config!" do
    it "discards assigned values back to defaults" do
      configurable.config.default_model = "claude"
      configurable.reset_config!
      expect(configurable.config.default_model).to eq("gpt-4o-mini")
    end
  end

  describe "one_of: validation" do
    it "accepts a permitted value" do
      configurable.config.mcp_text_content = :message
      expect(configurable.config.mcp_text_content).to eq(:message)
    end

    it "raises ArgumentError for a value outside the set" do
      expect { configurable.config.mcp_text_content = :nope }
        .to raise_error(ArgumentError, /mcp_text_content/)
    end
  end

  describe "dynamic defaults" do
    let(:derived_module) do
      Module.new do
        extend Axn::Configurable

        def self.derivations = @derivations ||= 0
        def self.bump! = @derivations = derivations + 1

        setting :derived, default: lambda {
          bump!
          "derived-#{derivations}"
        }
      end
    end

    it "re-derives a Proc default on every read while unset" do
      expect(derived_module.config.derived).to eq("derived-1")
      expect(derived_module.config.derived).to eq("derived-2")
    end

    it "returns an explicitly assigned Proc as-is, never invoking it" do
      assigned = -> { "not invoked" }
      derived_module.config.derived = assigned
      expect(derived_module.config.derived).to equal(assigned)
    end

    it "treats an explicitly assigned nil as a value, not as a reset" do
      derived_module.config.derived = nil
      expect(derived_module.config.derived).to be_nil
      expect(derived_module.config.derived?).to be(false)
    end
  end

  describe "overridable: settings" do
    let(:overridable) do
      Module.new do
        extend Axn::Configurable

        setting :mcp_text_content, default: :structured, one_of: %i[structured message], overridable: true
      end
    end

    let(:action_class) do
      mod = overridable.overrides
      Class.new { include mod }
    end

    it "resolves to the library default when no override is set" do
      expect(action_class.mcp_text_content).to eq(:structured)
    end

    it "reflects a change to the library default" do
      overridable.config.mcp_text_content = :message
      expect(action_class.mcp_text_content).to eq(:message)
    end

    it "resolves to the class-level override when set" do
      action_class.mcp_text_content :message
      expect(action_class.mcp_text_content).to eq(:message)
    end

    it "validates the override value" do
      expect { action_class.mcp_text_content :nope }.to raise_error(ArgumentError, /mcp_text_content/)
    end

    it "inherits an override from a parent class" do
      action_class.mcp_text_content :message
      child = Class.new(action_class)
      expect(child.mcp_text_content).to eq(:message)
    end

    it "does not leak an override to a sibling class" do
      action_class.mcp_text_content :message
      mod = overridable.overrides
      sibling = Class.new { include mod }
      expect(sibling.mcp_text_content).to eq(:structured)
    end

    it "does not generate override accessors for non-overridable settings" do
      plain = Module.new do
        extend Axn::Configurable
        setting :default_model, default: "x"
      end
      klass = Class.new { include plain.overrides }
      expect(klass).not_to respond_to(:default_model)
    end

    it "picks up overridable settings declared after the action includes overrides" do
      mod = Module.new { extend Axn::Configurable }
      overrides = mod.overrides
      klass = Class.new { include overrides } # included before the setting exists

      mod.setting :late, default: :x, overridable: true

      expect(klass.late).to eq(:x)
      klass.late :y
      expect(klass.late).to eq(:y)
    end

    describe "<name>?: boolean read of the resolved value" do
      let(:boolean_mod) do
        Module.new do
          extend Axn::Configurable
          setting :enabled, default: true, overridable: true
        end
      end

      let(:boolean_class) do
        mod = boolean_mod.overrides
        Class.new { include mod }
      end

      it "reflects the library default when no override is set" do
        expect(boolean_class.enabled?).to be(true)
      end

      it "reflects a falsey per-class override" do
        boolean_class.enabled(false)
        expect(boolean_class.enabled?).to be(false)
      end

      it "inherits a parent's override" do
        boolean_class.enabled(false)
        expect(Class.new(boolean_class).enabled?).to be(false)
      end

      it "is not generated for non-overridable settings" do
        plain = Module.new do
          extend Axn::Configurable
          setting :default_model, default: "x"
        end
        klass = Class.new { include plain.overrides }
        expect(klass).not_to respond_to(:default_model?)
      end
    end

    describe "<name>_override: the override with no config fallback" do
      it "returns UNSET when no override is set anywhere in the ancestry" do
        expect(action_class.mcp_text_content_override).to equal(Axn::Configurable::UNSET)
      end

      it "returns the stored override, unresolved, without falling back to config" do
        overridable.config.mcp_text_content = :message
        action_class.mcp_text_content :message

        expect(action_class.mcp_text_content_override).to eq(:message)
      end

      it "inherits a parent's override without falling back to config" do
        action_class.mcp_text_content :message
        child = Class.new(action_class)

        expect(child.mcp_text_content_override).to eq(:message)
      end

      it "does not leak a sibling's override" do
        action_class.mcp_text_content :message
        mod = overridable.overrides
        sibling = Class.new { include mod }

        expect(sibling.mcp_text_content_override).to equal(Axn::Configurable::UNSET)
      end

      it "does not generate <name>_override for non-overridable settings" do
        plain = Module.new do
          extend Axn::Configurable
          setting :default_model, default: "x"
        end
        klass = Class.new { include plain.overrides }

        expect(klass).not_to respond_to(:default_model_override)
      end

      it "does not define a raw_<name> alias (renamed to <name>_override)" do
        expect(action_class).not_to respond_to(:raw_mcp_text_content)
      end
    end

    describe "consumer-defined accessor collisions" do
      it "resolves via Axn's override store even when the class shadows <name>_override" do
        action_class.mcp_text_content :message
        action_class.define_singleton_method(:mcp_text_content_override) { :hijacked }

        expect(action_class.mcp_text_content).to eq(:message)
      end

      it "does not define a resolved_<name> alias (removed; use the bare reader)" do
        expect(action_class).not_to respond_to(:resolved_mcp_text_content)
      end
    end
  end
end

RSpec.describe Axn::Configurable::Settings do
  let(:klass) do
    Class.new do
      extend Axn::Configurable::Settings

      setting :log_level, default: :info
      setting :emit_metrics
      setting :additional_includes, default: []
      setting :mode, default: :a, one_of: %i[a b]
    end
  end

  subject(:instance) { klass.new }

  it "reads the declared default" do
    expect(instance.log_level).to eq(:info)
  end

  it "defaults to nil when none is declared" do
    expect(instance.emit_metrics).to be_nil
  end

  it "round-trips an assigned value" do
    instance.log_level = :debug
    expect(instance.log_level).to eq(:debug)
  end

  it "validates against one_of" do
    expect { instance.mode = :z }.to raise_error(ArgumentError, /mode/)
  end

  it "gives each instance its own copy of a mutable default" do
    instance.additional_includes << :Foo
    expect(klass.new.additional_includes).to eq([])
  end

  describe "validate: rejection reasons" do
    let(:klass) do
      Class.new do
        extend Axn::Configurable::Settings

        setting :bare, validate: ->(v) { v.is_a?(Integer) }
        setting :detailed, validate: ->(v) { v.is_a?(Integer) || "must be an Integer" }
        setting :blank_detail, validate: ->(v) { v.is_a?(Integer) || "" }
      end
    end

    let(:instance) { klass.new }

    it "raises without a detail clause when the validator returns false" do
      expect { instance.bare = "nope" }.to raise_error(ArgumentError, 'bare got invalid value: "nope"')
    end

    it "appends a String return value as the reason" do
      expect { instance.detailed = "nope" }.to raise_error(
        ArgumentError, 'detailed got invalid value: "nope" — must be an Integer'
      )
    end

    it "raises ArgumentError even when the reason's own strip would raise something else" do
      # The blank-reason check runs while an error is already being raised, so dispatching to a
      # caller-supplied String subclass there lets its method replace that ArgumentError with anything
      # — including a class the surrounding rescue was never meant to catch.
      hostile_reason = Class.new(String) do
        def strip = raise(NotImplementedError, "hostile strip")
      end

      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :num, validate: ->(_v) { hostile_reason.new("must be an Integer") }
      end

      expect { klass.new.num = 5 }.to raise_error(ArgumentError, /must be an Integer/)
    end

    it "accepts a truthy result whose own is_a? would raise, rather than dispatching to it" do
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :hostile, validate: ->(_v) { Class.new { def is_a?(_klass) = raise("hostile is_a?") }.new }
      end

      expect { klass.new.hostile = 5 }.not_to raise_error
    end

    it "accepts a valid value through a String-returning validator" do
      expect { instance.detailed = 3 }.not_to raise_error
    end

    it "falls back to the plain form when the validator returns a blank String" do
      expect { instance.blank_detail = "nope" }.to raise_error(ArgumentError, 'blank_detail got invalid value: "nope"')
    end
  end

  describe "predicate readers" do
    let(:klass) do
      Class.new do
        extend Axn::Configurable::Settings

        setting :sandbox_mode, default: -> { true }
        setting :emit_metrics
      end
    end

    it "returns true for a truthy resolved value (dynamic default)" do
      expect(instance.sandbox_mode?).to be(true)
    end

    it "returns false for an explicitly-assigned false" do
      instance.sandbox_mode = false
      expect(instance.sandbox_mode?).to be(false)
    end

    it "returns false when the setting resolves to nil" do
      expect(instance.emit_metrics?).to be(false)
    end
  end

  describe "dynamic defaults" do
    let(:klass) do
      Class.new do
        extend Axn::Configurable::Settings

        def self.derivations = @derivations ||= 0
        def self.bump! = @derivations = derivations + 1

        setting :derived, default: lambda {
          bump!
          "derived-#{derivations}"
        }
        setting :literal_list, default: []
      end
    end

    let(:instance) { klass.new }

    it "re-derives a Proc default on every read while unset" do
      expect(instance.derived).to eq("derived-1")
      expect(instance.derived).to eq("derived-2")
    end

    it "never writes a Proc default into the ivar, so the ivar stays an assignment sentinel" do
      instance.derived
      expect(instance.instance_variable_defined?(:@derived)).to be(false)
    end

    it "returns an explicitly assigned value instead of re-deriving" do
      instance.derived = "explicit"
      expect(instance.derived).to eq("explicit")
      expect(instance.derived).to eq("explicit")
    end

    it "treats an explicitly assigned nil as a value, not as a reset" do
      instance.derived = nil
      expect(instance.derived).to be_nil
      expect(instance.derived?).to be(false)
    end

    it "still memoizes a literal mutable default, so in-place mutation persists" do
      instance.literal_list << :a
      expect(instance.literal_list).to eq([:a])
    end

    it "does not share a literal mutable default across instances" do
      instance.literal_list << :a
      expect(klass.new.literal_list).to eq([])
    end
  end

  describe "overridable: settings" do
    # A stand-in for a live config singleton (what Axn.config is for Axn::Configuration).
    let(:singleton) { klass.new }

    let(:klass) do
      captured = -> { singleton }
      Class.new do
        extend Axn::Configurable::Settings
        overridable_config_source { captured.call }
        setting :mode, default: :a, one_of: %i[a b], overridable: true
      end
    end

    let(:action_class) do
      mod = klass.overrides
      Class.new { include mod }
    end

    it "resolves to the live singleton value when no override is set" do
      singleton.mode = :b
      expect(action_class.mode).to eq(:b)
    end

    it "reads the singleton value at resolution time, not at declaration (late-bound)" do
      expect(action_class.mode).to eq(:a) # singleton's default
      singleton.mode = :b
      expect(action_class.mode).to eq(:b) # picked up without redefining accessors
    end

    it "resolves to the class-level override when set" do
      action_class.mode :b
      expect(action_class.mode).to eq(:b)
    end

    it "validates the override value at set time" do
      expect { action_class.mode :z }.to raise_error(ArgumentError, /mode/)
    end

    it "inherits an override from a parent class" do
      action_class.mode :b
      expect(Class.new(action_class).mode).to eq(:b)
    end

    it "exposes <name>? resolving override then live singleton" do
      expect(action_class.mode?).to be(true) # :a is truthy
    end

    it "exposes <name>_override as the override with no singleton fallback" do
      expect(action_class.mode_override).to equal(Axn::Configurable::UNSET)
      action_class.mode :b
      expect(action_class.mode_override).to eq(:b)
    end

    it "raises at declaration when overridable: true without a registered source" do
      expect do
        Class.new do
          extend Axn::Configurable::Settings
          setting :mode, default: :a, overridable: true
        end
      end.to raise_error(ArgumentError, /overridable_config_source/)
    end

    describe "consumer-defined accessor collisions" do
      it "resolves via Axn's override store even when the class shadows <name>_override" do
        action_class.mode :b
        action_class.define_singleton_method(:mode_override) { :hijacked }

        expect(action_class.mode).to eq(:b)
      end
    end

    describe ".resolve_override_for (collision-proof framework path)" do
      it "resolves the override even when the class shadows every generated accessor" do
        action_class.mode :b
        action_class.define_singleton_method(:mode) { |*| :hijacked }
        action_class.define_singleton_method(:mode?) { :hijacked }
        action_class.define_singleton_method(:mode_override) { :hijacked }

        expect(klass.resolve_override_for(action_class, :mode)).to eq(:b)
      end

      it "falls back to the live singleton when no override is set" do
        singleton.mode = :b
        expect(klass.resolve_override_for(action_class, :mode)).to eq(:b)
      end

      it "raises KeyError for a setting that isn't overridable" do
        expect { klass.resolve_override_for(action_class, :not_a_setting) }.to raise_error(KeyError)
      end
    end
  end
end

RSpec.describe "Axn::Configurable namespaced per-class config" do
  let(:mcp) do
    Module.new do
      extend Axn::Configurable
      config_namespace :mcp
      setting :shared, default: :mcp_default, one_of: %i[mcp_default m], overridable: true
    end
  end

  let(:ruby_llm) do
    Module.new do
      extend Axn::Configurable
      config_namespace :ruby_llm
      setting :shared, default: :llm_default, overridable: true
    end
  end

  # A class composing two adapters that happen to share a setting name — the
  # tool topology the namespacing exists for.
  let(:tool) do
    a = mcp.overrides
    b = ruby_llm.overrides
    Class.new do
      include a
      include b
    end
  end

  it "keeps same-named settings from different namespaces independent" do
    tool.configure(:mcp) { |c| c.shared = :m }
    tool.configure(:ruby_llm) { |c| c.shared = :r }

    expect(mcp.resolve_override_for(tool, :shared)).to eq(:m)
    expect(ruby_llm.resolve_override_for(tool, :shared)).to eq(:r)
  end

  it "stores config for an unregistered namespace inertly, leaving loaded ones untouched" do
    expect { tool.configure(:not_loaded) { |c| c.anything = :x } }.not_to raise_error
    expect(mcp.resolve_override_for(tool, :shared)).to eq(:mcp_default)
  end

  it "validates eagerly when the namespace's source is registered on the class" do
    expect { tool.configure(:mcp) { |c| c.shared = :bogus } }.to raise_error(ArgumentError, /shared/)
  end

  it "rejects an unknown setter name for a registered namespace" do
    expect { tool.configure(:mcp) { |c| c.no_such_setting = :x } }.to raise_error(ArgumentError, /unknown overridable setting/)
  end

  it "stores an unregistered namespace tolerantly, validating only when the adapter resolves it" do
    mod = ruby_llm.overrides # gives the class `configure`, but does NOT register :mcp
    plain = Class.new { include mod }

    expect { plain.configure(:mcp) { |c| c.shared = :bogus } }.not_to raise_error
    expect { mcp.resolve_override_for(plain, :shared) }.to raise_error(ArgumentError, /shared/)
  end

  it "surfaces a typo'd tolerant key when the source resolves the namespace" do
    mod = ruby_llm.overrides
    plain = Class.new { include mod }
    plain.configure(:mcp) { |c| c.shraed = :m } # typo: real setting is :shared

    expect { mcp.resolve_override_for(plain, :shared) }.to raise_error(ArgumentError, /unknown overridable setting/)
  end

  it "surfaces a typo'd tolerant key when the source's overrides are later included" do
    rmod = ruby_llm.overrides
    mmod = mcp.overrides

    expect do
      Class.new do
        include rmod                          # `configure` available, :mcp still unregistered
        configure(:mcp) { |c| c.shraed = :m } # tolerant, typo'd
        include mmod                          # registers :mcp → validates the existing slot
      end
    end.to raise_error(ArgumentError, /unknown overridable setting/)
  end

  it "agrees with the flat accessor on the same namespace slot" do
    mod = mcp.overrides
    single = Class.new { include mod }
    single.configure(:mcp) { |c| c.shared = :m }
    expect(single.shared).to eq(:m)
  end

  it "defers to a base class's own `configure`, exposing axn's config as axn_configure" do
    base = Class.new do
      def self.configure(*args) = "base:#{args.inspect}"
    end
    mod = mcp.overrides
    sub = Class.new(base) { include mod }

    # Bare `configure` still reaches the base's own hook, untouched.
    expect(sub.configure(:anything)).to eq("base:[:anything]")

    # axn_configure is always available as the collision-proof form.
    sub.axn_configure(:mcp) { |c| c.shared = :m }
    expect(mcp.resolve_override_for(sub, :shared)).to eq(:m)
  end

  it "exposes axn_configure alongside configure on an unshadowed action" do
    mod = mcp.overrides
    single = Class.new { include mod }
    single.axn_configure(:mcp) { |c| c.shared = :m }
    expect(single.shared).to eq(:m)
  end

  it "raises when two different sources claim the same config_namespace on one class" do
    a = Module.new do
      extend Axn::Configurable
      config_namespace :dup
      setting :foo, default: 1, overridable: true
    end
    b = Module.new do
      extend Axn::Configurable
      config_namespace :dup
      setting :bar, default: 2, overridable: true
    end
    am = a.overrides
    bm = b.overrides

    expect do
      Class.new do
        include am
        include bm
      end
    end.to raise_error(ArgumentError, /namespace :dup is already owned/)
  end

  it "raises when a subclass adds a second source for a namespace its parent already owns" do
    a = Module.new do
      extend Axn::Configurable
      config_namespace :dup2
      setting :foo, default: 1, overridable: true
    end
    b = Module.new do
      extend Axn::Configurable
      config_namespace :dup2
      setting :bar, default: 2, overridable: true
    end
    am = a.overrides
    bm = b.overrides
    parent = Class.new { include am }

    expect { Class.new(parent) { include bm } }.to raise_error(ArgumentError, /namespace :dup2 is already owned/)
  end

  it "raises when config_namespace is declared after an overridable setting" do
    expect do
      Module.new do
        extend Axn::Configurable
        setting :x, default: 1, overridable: true
        config_namespace :late
      end
    end.to raise_error(ArgumentError, /config_namespace/)
  end

  it "raises when config_namespace is declared after the overrides were included" do
    src = Module.new { extend Axn::Configurable }
    mod = src.overrides
    Class.new { include mod } # include locks the (default) namespace

    expect { src.config_namespace(:mcp) }.to raise_error(ArgumentError, /config_namespace/)
  end
end

RSpec.describe "#reset!" do
  context "on the class flavor" do
    let(:klass) do
      Class.new do
        extend Axn::Configurable::Settings

        setting :literal, default: :original
        setting :derived, default: -> { :derived_default }
      end
    end

    let(:instance) { klass.new }

    it "returns a named literal setting to its default" do
      instance.literal = :changed
      instance.reset!(:literal)
      expect(instance.literal).to eq(:original)
    end

    it "returns a named dynamic setting to re-deriving, which an assigned nil had suppressed" do
      instance.derived = nil
      expect(instance.derived).to be_nil
      instance.reset!(:derived)
      expect(instance.derived).to eq(:derived_default)
    end

    it "resets every declared setting when called with no arguments" do
      instance.literal = :changed
      instance.derived = nil
      instance.reset!
      expect(instance.literal).to eq(:original)
      expect(instance.derived).to eq(:derived_default)
    end

    it "raises on a name that is not a declared setting, naming the ones that exist" do
      # Per AGENTS.md, a message explains the problem AND the fix — here, which names are valid.
      expect { instance.reset!(:nope) }
        .to raise_error(ArgumentError, /unknown setting :nope\. Declared settings are: .*:literal/)
    end

    it "resets nothing when any name in the list is unknown" do
      instance.literal = :changed

      expect { instance.reset!(:literal, :nope) }.to raise_error(ArgumentError, /unknown setting :nope/)
      expect(instance.literal).to eq(:changed)
    end

    it "is a no-op for a setting that was never assigned" do
      expect { instance.reset!(:literal) }.not_to raise_error
      expect(instance.literal).to eq(:original)
    end

    it "returns self so it can be chained" do
      expect(instance.reset!(:literal)).to be(instance)
    end

    it "resets both a subclass's own setting and one inherited from its superclass" do
      base = Class.new do
        extend Axn::Configurable::Settings

        setting :base_only, default: :base_default
      end
      sub = Class.new(base) do
        setting :sub_only, default: :sub_default
      end
      instance = sub.new

      instance.base_only = :changed
      instance.sub_only = :changed

      instance.reset!(:base_only)
      expect(instance.base_only).to eq(:base_default)
      expect(instance.sub_only).to eq(:changed)

      instance.reset!(:sub_only)
      expect(instance.sub_only).to eq(:sub_default)

      instance.base_only = :changed
      instance.sub_only = :changed
      instance.reset!
      expect(instance.base_only).to eq(:base_default)
      expect(instance.sub_only).to eq(:sub_default)
    end

    it "resets an inherited setting on a subclass that declares no settings of its own" do
      base = Class.new do
        extend Axn::Configurable::Settings

        setting :base_only, default: :base_default
      end
      sub = Class.new(base)
      instance = sub.new

      instance.base_only = :changed
      instance.reset!(:base_only)
      expect(instance.base_only).to eq(:base_default)
    end

    it "rejects `reset!` as a setting name at declaration, in the class flavor" do
      expect do
        Class.new do
          extend Axn::Configurable::Settings

          setting :reset!
        end
      end.to raise_error(ArgumentError, /setting :reset! is reserved/)
    end

    it "rejects `reset!` as a setting name at declaration, in the module-singleton flavor" do
      expect do
        Module.new do
          extend Axn::Configurable

          setting :reset!
        end
      end.to raise_error(ArgumentError, /setting :reset! is reserved/)
    end

    it "still defers when the logger raises while leaving the collision breadcrumb" do
      # The breadcrumb is a side channel and must not be able to take down the thing it observes —
      # here, class DEFINITION. A faulty custom logger previously aborted `extend`, so the collision
      # behavior it was announcing never happened at all.
      exploding = Object.new
      exploding.define_singleton_method(:debug) { |*| raise "logger exploded" }
      exploding.define_singleton_method(:warn) { |*| raise "warn exploded" }
      allow(Axn.config).to receive(:logger).and_return(exploding)

      klass = nil
      expect do
        klass = Class.new do
          def reset!(*) = :the_authors_own

          extend Axn::Configurable::Settings

          setting :literal, default: :original
        end
      end.not_to raise_error

      expect(klass.new.reset!(:literal)).to eq(:the_authors_own)
    end

    it "defers to a reset! the class defined itself rather than replacing it" do
      klass = Class.new do
        def reset!(*) = :the_authors_own

        extend Axn::Configurable::Settings

        setting :literal, default: :original
      end

      expect(klass.new.reset!(:literal)).to eq(:the_authors_own)
    end

    it "resolves its targets even when a setting named `class` shadows Object#class" do
      # The generated reader for `setting :class` shadows the real one, so reading `self.class` to find
      # the declared settings hands back the setting's VALUE — leaving no-arg reset! resetting nothing
      # and a named reset claiming a real setting is unknown.
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :class, default: :shadowed
        setting :other, default: 1
      end
      instance = klass.new
      instance.other = 9

      instance.reset!

      expect(instance.other).to eq(1)
      expect { instance.reset!(:other) }.not_to raise_error
    end

    it "defers to a reset! from a module included AFTER the extend" do
      # A method defined directly on the class outranks every module, so generating it that way made
      # the deferral depend on whether the author's include sat above or below the `extend`.
      authors = Module.new { def reset!(*) = :the_authors_own }
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :literal, default: :original

        include authors
      end

      expect(klass.new.reset!(:literal)).to eq(:the_authors_own)
    end

    it "still lets a reset! defined on the class itself win over the generated one" do
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :literal, default: :original

        def reset!(*) = :defined_on_the_class
      end

      expect(klass.new.reset!(:literal)).to eq(:defined_on_the_class)
    end

    it "defers to a reset! inherited from a non-axn ancestor" do
      ancestor = Class.new do
        def reset!(*) = :inherited
      end
      klass = Class.new(ancestor) do
        extend Axn::Configurable::Settings

        setting :literal, default: :original
      end

      expect(klass.new.reset!(:literal)).to eq(:inherited)
    end

    it "canonicalizes the name once, so a shifting to_sym cannot install a reserved name" do
      # The guard and the registration used to call `to_sym` separately, so a name answering `:safe`
      # first and `:reset!` second passed the check and then generated `reset!` anyway — replacing the
      # per-setting reset helper with a zero-arity reader, which is exactly what the guard exists to
      # prevent. One `to_sym` decides the name for the check, the registry, the ivar and the reader.
      shifty = Class.new(String) do
        def initialize(*)
          super
          @calls = 0
        end

        def to_sym = (@calls += 1) == 1 ? :safe : :reset!
      end.new("reset!")

      klass = Class.new do
        extend Axn::Configurable::Settings

        setting shifty, default: 1
      end

      expect(klass.new.safe).to eq(1)
      # The generated per-setting helper, not a zero-arity reader that shadowed it.
      expect(klass.instance_method(:reset!).arity).to eq(-1)
      expect(klass.new.reset!(:safe)).to be_a(klass)
    end

    it "still rejects a reserved name that canonicalizes to it on the first read" do
      expect do
        Class.new do
          extend Axn::Configurable::Settings

          setting "reset!", default: 1
        end
      end.to raise_error(ArgumentError, /setting :reset! is reserved/)
    end

    it "defers to a reset! added to an ANCESTOR after the extend" do
      # The last load-order dependency. Being a module covers an include on the same class, and the
      # extend-time check covers what already existed — but the generated module sits ahead of the
      # superclass in a subclass's ancestry, so a reset! arriving on the superclass afterwards would
      # silently lose. Deferral is therefore decided per call, not only at extend time.
      base = Class.new
      sub = Class.new(base) do
        extend Axn::Configurable::Settings

        setting :literal, default: :original
      end

      authors = Module.new { def reset!(*) = :added_to_the_ancestor_later }
      base.include(authors)

      expect(sub.new.reset!(:literal)).to eq(:added_to_the_ancestor_later)
    end

    it "passes its arguments through when it defers" do
      # `define_method` forbids implicit-argument `super`, so the forwarding is written out and can
      # silently drop the names it was called with.
      seen = []
      authors = Module.new do
        define_method(:reset!) { |*names| seen = names }
      end
      base = Class.new
      sub = Class.new(base) do
        extend Axn::Configurable::Settings

        setting :literal, default: :original
      end
      base.include(authors)

      sub.new.reset!(:literal, :another)
      expect(seen).to eq(%i[literal another])
    end
  end

  describe "a validate: reason in an incompatible encoding" do
    it "still raises ArgumentError rather than an encoding error" do
      # Joining a UTF-16LE reason into axn's UTF-8 message raised Encoding::CompatibilityError, so
      # REPORTING the validation failure replaced it — the caller saw an encoding bug instead of the
      # rejection, which is the one thing an error path may not do.
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :x, validate: ->(_v) { "réason".encode("UTF-16LE") }
      end

      expect { klass.new.x = 1 }.to raise_error(ArgumentError, /got invalid value: 1 — réason/)
    end

    it "still raises ArgumentError when the rejected value's own inspect raises" do
      # An inspect that raises is an ordinary bug — an uninitialized ivar, a broken association — and on
      # an error path the exception being reported must win over anything raised while describing it.
      # Interrupt specifically, since axn never swallows it anywhere else.
      hostile = Class.new do
        def inspect = raise(Interrupt)
      end.new
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :x, validate: ->(_v) { false }
      end

      expect { klass.new.x = hostile }.to raise_error(ArgumentError, /got invalid value: #<.*inspect unavailable/)
    end

    it "describes an unrenderable value in the one_of rejection too" do
      hostile = Class.new do
        def inspect = raise(Interrupt)
      end.new
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :x, one_of: %i[a b]
      end

      expect { klass.new.x = hostile }.to raise_error(ArgumentError, /must be one of :a, :b; got #</)
    end

    it "keeps a well-behaved value's own inspect rather than degrading it" do
      # The reason `inspect` is still dispatched: rendering everything through Object#inspect would turn
      # every useful message into #<String:0x…>.
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :x, validate: ->(_v) { false }
      end

      expect { klass.new.x = "foo" }.to raise_error(ArgumentError, /got invalid value: "foo"/)
    end

    it "still raises ArgumentError when the reason is TAGGED utf-8 but holds invalid bytes" do
      # The narrowest case, and the one the first fix missed. Transcoding a String already tagged UTF-8
      # succeeds without validating it, and the blank test ran on the RAW reason — so `strip` raised
      # Encoding::CompatibilityError before the rendering was ever reached.
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :x, validate: ->(_v) { (+"bad \xC3(").force_encoding(Encoding::UTF_8) }
      end

      expect { klass.new.x = 1 }.to raise_error(ArgumentError, /got invalid value: 1 — bad/)
    end

    it "treats a blank reason in another encoding as no reason at all" do
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :x, validate: ->(_v) { "   ".encode("UTF-16LE") }
      end

      # No dangling separator: the rendered reason is whitespace, so the plain form is used.
      expect { klass.new.x = 1 }.to raise_error(ArgumentError, /got invalid value: 1\z/)
    end

    it "renders a reason whose bytes cannot be transcoded at all" do
      klass = Class.new do
        extend Axn::Configurable::Settings

        setting :x, validate: ->(_v) { (+"bad \xC3(").force_encoding(Encoding::ASCII_8BIT) }
      end

      expect { klass.new.x = 1 }.to raise_error(ArgumentError, /got invalid value: 1 — bad/)
    end
  end

  context "on the module-singleton flavor" do
    let(:mod) do
      Module.new do
        extend Axn::Configurable

        setting :literal, default: :original
        setting :derived, default: -> { :derived_default }
      end
    end

    it "returns a named setting to its default" do
      mod.config.literal = :changed
      mod.config.reset!(:literal)
      expect(mod.config.literal).to eq(:original)
    end

    it "returns a dynamic setting to re-deriving after an assigned nil" do
      mod.config.derived = nil
      mod.config.reset!(:derived)
      expect(mod.config.derived).to eq(:derived_default)
    end

    it "resets every setting when called with no arguments" do
      mod.config.literal = :changed
      mod.config.derived = nil
      mod.config.reset!
      expect(mod.config.literal).to eq(:original)
      expect(mod.config.derived).to eq(:derived_default)
    end

    it "raises on an unknown setting, naming the ones that exist" do
      expect { mod.config.reset!(:nope) }
        .to raise_error(ArgumentError, /unknown setting :nope\. Declared settings are: .*:literal/)
    end

    it "resets nothing when any name in the list is unknown" do
      mod.config.literal = :changed

      expect { mod.config.reset!(:literal, :nope) }.to raise_error(ArgumentError, /unknown setting :nope/)
      expect(mod.config.literal).to eq(:changed)
    end
  end
end
