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
      expect(action_class.resolved_mcp_text_content).to eq(:structured)
    end

    it "reflects a change to the library default" do
      overridable.config.mcp_text_content = :message
      expect(action_class.resolved_mcp_text_content).to eq(:message)
    end

    it "resolves to the class-level override when set" do
      action_class.mcp_text_content :message
      expect(action_class.resolved_mcp_text_content).to eq(:message)
    end

    it "validates the override value" do
      expect { action_class.mcp_text_content :nope }.to raise_error(ArgumentError, /mcp_text_content/)
    end

    it "inherits an override from a parent class" do
      action_class.mcp_text_content :message
      child = Class.new(action_class)
      expect(child.resolved_mcp_text_content).to eq(:message)
    end

    it "does not leak an override to a sibling class" do
      action_class.mcp_text_content :message
      mod = overridable.overrides
      sibling = Class.new { include mod }
      expect(sibling.resolved_mcp_text_content).to eq(:structured)
    end

    it "does not generate override accessors for non-overridable settings" do
      plain = Module.new do
        extend Axn::Configurable
        setting :default_model, default: "x"
      end
      klass = Class.new { include plain.overrides }
      expect(klass).not_to respond_to(:resolved_default_model)
    end

    it "resolves a callable override value through Setting#resolve" do
      mod = Module.new do
        extend Axn::Configurable
        setting :enabled, default: true, callable: true, overridable: true
      end
      m = mod.overrides
      klass = Class.new { include m }

      klass.enabled(-> { false })

      expect(klass.resolved_enabled).to eq(false)
    end

    it "picks up overridable settings declared after the action includes overrides" do
      mod = Module.new { extend Axn::Configurable }
      overrides = mod.overrides
      klass = Class.new { include overrides } # included before the setting exists

      mod.setting :late, default: :x, overridable: true

      expect(klass.resolved_late).to eq(:x)
      klass.late :y
      expect(klass.resolved_late).to eq(:y)
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

        expect(action_class.resolved_mcp_text_content).to eq(:message)
        expect(action_class.mcp_text_content).to eq(:message)
      end

      it "reads via Axn's resolution even when the class shadows resolved_<name>" do
        action_class.mcp_text_content :message
        action_class.define_singleton_method(:resolved_mcp_text_content) { :hijacked }

        expect(action_class.mcp_text_content).to eq(:message)
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
      expect(action_class.resolved_mode).to eq(:b)
    end

    it "reads the singleton value at resolution time, not at declaration (late-bound)" do
      expect(action_class.resolved_mode).to eq(:a) # singleton's default
      singleton.mode = :b
      expect(action_class.resolved_mode).to eq(:b) # picked up without redefining accessors
    end

    it "resolves to the class-level override when set" do
      action_class.mode :b
      expect(action_class.resolved_mode).to eq(:b)
    end

    it "validates the override value at set time" do
      expect { action_class.mode :z }.to raise_error(ArgumentError, /mode/)
    end

    it "inherits an override from a parent class" do
      action_class.mode :b
      expect(Class.new(action_class).resolved_mode).to eq(:b)
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
  end
end
