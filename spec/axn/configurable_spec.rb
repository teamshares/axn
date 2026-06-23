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

    it "picks up overridable settings declared after the action includes overrides" do
      mod = Module.new { extend Axn::Configurable }
      overrides = mod.overrides
      klass = Class.new { include overrides } # included before the setting exists

      mod.setting :late, default: :x, overridable: true

      expect(klass.resolved_late).to eq(:x)
      klass.late :y
      expect(klass.resolved_late).to eq(:y)
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
end
