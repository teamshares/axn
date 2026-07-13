# frozen_string_literal: true

RSpec.describe Axn::Configurable do
  let(:configurable) do
    Module.new do
      extend Axn::Configurable

      setting :default_model, default: "gpt-4o-mini"
      setting :mcp_text_content, default: :structured, one_of: %i[structured message]
      setting :enabled, default: true, callable: true
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

  describe "callable: settings" do
    it "resolves a proc value at read time" do
      configurable.config.enabled = -> { false }
      expect(configurable.config.enabled).to eq(false)
    end

    it "returns a non-callable value as-is" do
      configurable.config.enabled = true
      expect(configurable.config.enabled).to eq(true)
    end

    it "exposes a boolean predicate" do
      configurable.config.enabled = -> { false }
      expect(configurable.config.enabled?).to eq(false)
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

    it "resolves a callable override value through Setting#resolve" do
      mod = Module.new do
        extend Axn::Configurable
        setting :enabled, default: true, callable: true, overridable: true
      end
      m = mod.overrides
      klass = Class.new { include m }

      klass.enabled(-> { false })

      expect(klass.enabled).to eq(false)
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
          setting :enabled, default: true, callable: true, overridable: true
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

      it "resolves a callable default at read time" do
        boolean_mod.config.enabled = -> { false }
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

    describe "raw_<name>: the override with no config fallback" do
      it "returns UNSET when no override is set anywhere in the ancestry" do
        expect(action_class.raw_mcp_text_content).to equal(Axn::Configurable::UNSET)
      end

      it "returns the stored override, unresolved, without falling back to config" do
        overridable.config.mcp_text_content = :message
        action_class.mcp_text_content :message

        expect(action_class.raw_mcp_text_content).to eq(:message)
      end

      it "inherits a parent's override without falling back to config" do
        action_class.mcp_text_content :message
        child = Class.new(action_class)

        expect(child.raw_mcp_text_content).to eq(:message)
      end

      it "does not leak a sibling's override" do
        action_class.mcp_text_content :message
        mod = overridable.overrides
        sibling = Class.new { include mod }

        expect(sibling.raw_mcp_text_content).to equal(Axn::Configurable::UNSET)
      end

      it "does not generate raw_<name> for non-overridable settings" do
        plain = Module.new do
          extend Axn::Configurable
          setting :default_model, default: "x"
        end
        klass = Class.new { include plain.overrides }

        expect(klass).not_to respond_to(:raw_default_model)
      end
    end

    describe "consumer-defined accessor collisions" do
      it "resolves via Axn's override store even when the class shadows raw_<name>" do
        action_class.mcp_text_content :message
        action_class.define_singleton_method(:raw_mcp_text_content) { :hijacked }

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

  describe "predicate readers" do
    let(:klass) do
      Class.new do
        extend Axn::Configurable::Settings

        setting :sandbox_mode, default: -> { true }, callable: true
        setting :emit_metrics
      end
    end

    it "returns true for a truthy resolved value (callable default)" do
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

    it "exposes raw_<name> as the override with no singleton fallback" do
      expect(action_class.raw_mode).to equal(Axn::Configurable::UNSET)
      action_class.mode :b
      expect(action_class.raw_mode).to eq(:b)
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
      it "resolves via Axn's override store even when the class shadows raw_<name>" do
        action_class.mode :b
        action_class.define_singleton_method(:raw_mode) { :hijacked }

        expect(action_class.mode).to eq(:b)
      end
    end

    describe ".resolve_override_for (collision-proof framework path)" do
      it "resolves the override even when the class shadows every generated accessor" do
        action_class.mode :b
        action_class.define_singleton_method(:mode) { |*| :hijacked }
        action_class.define_singleton_method(:mode?) { :hijacked }
        action_class.define_singleton_method(:raw_mode) { :hijacked }

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
