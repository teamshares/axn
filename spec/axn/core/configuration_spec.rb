# frozen_string_literal: true

RSpec.describe Axn::RailsConfiguration do
  subject(:config) { described_class.new }

  describe "#app_actions_autoload_namespace" do
    it "defaults to nil" do
      expect(config.app_actions_autoload_namespace).to be_nil
    end

    it "can be set to a symbol" do
      config.app_actions_autoload_namespace = :Actions
      expect(config.app_actions_autoload_namespace).to eq(:Actions)
    end

    it "can be set to nil explicitly" do
      config.app_actions_autoload_namespace = nil
      expect(config.app_actions_autoload_namespace).to be_nil
    end
  end
end

RSpec.describe Axn::Configuration do
  subject(:config) { described_class.new }

  describe "defaults (in test mode)" do
    it { expect(config.additional_includes).to eq([]) }
    it { expect(config.logger).to be_a(Logger) }
    it { expect(config.env.test?).to eq(true) }
    it { expect(config.tool_paths).to eq(%w[agent_tools actions/tools]) }
    it { expect(config.tool_name_stripped_prefixes).to eq(%w[actions tools agent_tools]) }

    describe "#tool_paths=" do
      it "accepts an array of strings" do
        config.tool_paths = %w[agent_tools]
        expect(config.tool_paths).to eq(%w[agent_tools])
      end

      it "rejects a non-array" do
        expect { config.tool_paths = "agent_tools" }.to raise_error(ArgumentError)
      end

      it "rejects a bare broad `actions` entry, naming the offender" do
        expect { config.tool_paths = ["actions"] }.to raise_error(ArgumentError, /"actions"/)
      end

      it "rejects `app/actions`" do
        expect { config.tool_paths = ["app/actions"] }.to raise_error(ArgumentError, %r{app/actions})
      end

      it "rejects `app`" do
        expect { config.tool_paths = ["app"] }.to raise_error(ArgumentError, /"app"/)
      end

      it "rejects an empty-string entry" do
        expect { config.tool_paths = [""] }.to raise_error(ArgumentError)
      end

      it "rejects a `.` entry" do
        expect { config.tool_paths = ["."] }.to raise_error(ArgumentError)
      end

      it "rejects a broad entry even with surrounding whitespace and slashes" do
        expect { config.tool_paths = ["  /actions/  "] }.to raise_error(ArgumentError)
      end

      it "rejects `./actions` (a `.`-prefixed alternate spelling of the broad `actions` dir)" do
        expect { config.tool_paths = ["./actions"] }.to raise_error(ArgumentError, %r{\./actions})
      end

      it "rejects `actions/.` (a trailing-`.` alternate spelling of the broad `actions` dir)" do
        expect { config.tool_paths = ["actions/."] }.to raise_error(ArgumentError, %r{actions/\.})
      end

      it "rejects `actions/../actions` (a `..`-round-trip alternate spelling of the broad `actions` dir)" do
        expect { config.tool_paths = ["actions/../actions"] }.to raise_error(ArgumentError, %r{actions/\.\./actions})
      end

      it "rejects a `..` traversal entry that escapes the app root" do
        expect { config.tool_paths = ["../secret"] }.to raise_error(ArgumentError, %r{\.\./secret})
      end

      it "still accepts legitimately narrow dirs" do
        config.tool_paths = %w[agent_tools actions/tools]
        expect(config.tool_paths).to eq(%w[agent_tools actions/tools])
      end

      it "still accepts legitimately narrow dirs (agent_tools, actions/tools, app/actions/tools)" do
        config.tool_paths = %w[actions/tools app/actions/tools agent_tools]
        expect(config.tool_paths).to eq(%w[actions/tools app/actions/tools agent_tools])
      end

      it "accepts app/actions/tools (a narrow subdir of app/actions)" do
        config.tool_paths = %w[app/actions/tools]
        expect(config.tool_paths).to eq(%w[app/actions/tools])
      end
    end

    describe ".normalize_tool_path" do
      it "collapses a `.`-segment alternate spelling" do
        expect(described_class.normalize_tool_path("actions/./tools")).to eq("actions/tools")
      end

      it "collapses a `..`-round-trip alternate spelling" do
        expect(described_class.normalize_tool_path("app/../agent_tools")).to eq("agent_tools")
      end

      it "strips surrounding whitespace and slashes" do
        expect(described_class.normalize_tool_path(" /actions/tools/ ")).to eq("actions/tools")
      end
    end

    describe ".broad_tool_path?" do
      it "flags a bare broad `actions` entry" do
        expect(described_class.broad_tool_path?("actions")).to be(true)
      end

      it "flags `./actions` (alternate spelling)" do
        expect(described_class.broad_tool_path?("./actions")).to be(true)
      end

      it "flags `app/actions`" do
        expect(described_class.broad_tool_path?("app/actions")).to be(true)
      end

      it "flags a `..`-traversal entry" do
        expect(described_class.broad_tool_path?("actions/..")).to be(true)
        expect(described_class.broad_tool_path?("..")).to be(true)
      end

      it "does not flag a legitimately narrow dir" do
        expect(described_class.broad_tool_path?("actions/tools")).to be(false)
      end

      it "does not flag a dir that merely shares a prefix with a blocklisted entry" do
        expect(described_class.broad_tool_path?("agent_tools")).to be(false)
      end

      it "does not flag a narrow subdir of app/actions" do
        expect(described_class.broad_tool_path?("app/actions/tools")).to be(false)
      end
    end

    describe "#tool_name_stripped_prefixes=" do
      it "accepts an array of strings" do
        config.tool_name_stripped_prefixes = %w[actions]
        expect(config.tool_name_stripped_prefixes).to eq(%w[actions])
      end

      it "rejects a non-array" do
        expect { config.tool_name_stripped_prefixes = :actions }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#logger" do
    # Rails boots its logger in an initializer; any code that runs earlier (e.g. `include Axn`
    # at gem load, under Bundler.require) sees `Rails` defined but `Rails.logger` still nil.
    # The getter must stay usable in that window rather than returning nil (PRO-2891).
    context "when Rails is defined but Rails.logger is nil (boot window)" do
      before { stub_const("Rails", Module.new { def self.logger = nil }) }

      it "returns a usable Logger instead of nil" do
        expect(config.logger).to be_a(Logger)
      end

      it "does not raise when a caller logs through it" do
        expect { config.logger.debug { "boot-time message" } }.not_to raise_error
      end
    end

    context "when Rails.logger is initially nil, then set later" do
      let(:fake_rails) do
        Class.new do
          class << self
            attr_accessor :logger
          end
        end
      end

      before { stub_const("Rails", fake_rails) }

      it "does not memoize the transient fallback (picks up Rails.logger once available)" do
        fake_rails.logger = nil
        expect(config.logger).to be_a(Logger)

        real_logger = Logger.new(File::NULL)
        fake_rails.logger = real_logger
        expect(config.logger).to be(real_logger)
      end
    end
  end

  describe "async configuration" do
    # Tests that use real adapters (:sidekiq, :active_job) are in spec_rails/
    # since they require those gems to be loaded.

    it "defaults to disabled" do
      expect(config._default_async_adapter).to be false
      expect(config._default_async_config).to eq({})
      expect(config._default_async_config_block).to be_nil
    end

    it "can set just the config" do
      config.set_default_async(false, queue: "low", retry: 3)

      expect(config._default_async_adapter).to be false
      expect(config._default_async_config).to eq({ queue: "low", retry: 3 })
      expect(config._default_async_config_block).to be_nil
    end

    it "can set just the block" do
      block = proc { puts "test block" }
      config.set_default_async(&block)

      expect(config._default_async_adapter).to be false
      expect(config._default_async_config).to eq({})
      expect(config._default_async_config_block).to eq(block)
    end

    it "raises ArgumentError when trying to set adapter to nil" do
      expect do
        config.set_default_async(nil)
      end.to raise_error(ArgumentError, "Cannot set default async adapter to nil as it would cause infinite recursion")
    end

    it "triggers async exception reporting registration for Sidekiq when set_default_async(:sidekiq)" do
      allow(config).to receive(:_ensure_async_exception_reporting_registered_for_adapter)
      allow(config).to receive(:_apply_async_to_enqueue_all_orchestrator)

      config.set_default_async(:sidekiq, queue: "default")

      expect(config).to have_received(:_ensure_async_exception_reporting_registered_for_adapter).with(:sidekiq)
    end

    it "calls ensure with false when adapter is false (no registration for disabled async)" do
      allow(config).to receive(:_ensure_async_exception_reporting_registered_for_adapter)
      allow(config).to receive(:_apply_async_to_enqueue_all_orchestrator)

      config.set_default_async(false, queue: "low")

      expect(config).to have_received(:_ensure_async_exception_reporting_registered_for_adapter).with(false)
    end
  end

  describe "set_enqueue_all_async and async exception reporting" do
    it "triggers async exception reporting registration for Sidekiq when set_enqueue_all_async(:sidekiq)" do
      allow(config).to receive(:_ensure_async_exception_reporting_registered_for_adapter)
      allow(config).to receive(:_apply_async_to_enqueue_all_orchestrator)

      config.set_enqueue_all_async(:sidekiq, queue: "batch")

      expect(config).to have_received(:_ensure_async_exception_reporting_registered_for_adapter).with(:sidekiq)
    end
  end

  describe "#rails" do
    it "returns a RailsConfiguration instance" do
      expect(config.rails).to be_a(Axn::RailsConfiguration)
    end

    it "returns the same instance on subsequent calls" do
      expect(config.rails).to be(config.rails)
    end
  end

  describe "#env" do
    it "can be set to production" do
      expect(config.env.test?).to eq(true)
      config.env = "production"
      expect(config.env.production?).to eq(true)
    end
  end

  describe "#async_exception_reporting" do
    it "defaults to :first_and_exhausted" do
      expect(config.async_exception_reporting).to eq(:first_and_exhausted)
    end

    it "can be set to :every_attempt" do
      config.async_exception_reporting = :every_attempt
      expect(config.async_exception_reporting).to eq(:every_attempt)
    end

    it "can be set to :only_exhausted" do
      config.async_exception_reporting = :only_exhausted
      expect(config.async_exception_reporting).to eq(:only_exhausted)
    end

    it "raises ArgumentError for invalid values" do
      expect do
        config.async_exception_reporting = :invalid
      end.to raise_error(ArgumentError, /must be one of:/)
    end
  end

  describe "#async_max_retries" do
    it "defaults to nil (uses adapter defaults)" do
      expect(config.async_max_retries).to be_nil
    end

    it "can be set to override adapter defaults" do
      config.async_max_retries = 10
      expect(config.async_max_retries).to eq(10)
    end
  end

  describe "#on_exception" do
    let(:exception) { StandardError.new("fail!") }
    let(:action) { double("Action", log: nil) }
    let(:context) { { foo: :bar } }
    subject(:config) { described_class.new }

    it "calls proc with only e if no kwargs expected" do
      called = nil
      config.on_exception = proc { |e| called = [e] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception])
    end

    it "calls proc with e and action if action: is expected" do
      called = nil
      config.on_exception = proc { |e, action:| called = [e, action] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, action])
    end

    it "calls proc with e and context if context: is expected" do
      called = nil
      config.on_exception = proc { |e, context:| called = [e, context] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, context])
    end

    it "calls proc with e, action, and context if both are expected" do
      called = nil
      config.on_exception = proc { |e, action:, context:| called = [e, action, context] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, action, context])
    end

    it "does not pass unknown kwargs" do
      called = nil
      config.on_exception = proc { |e, foo: nil| called = [e, foo] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, nil])
    end
  end

  describe "#sidekiq_job_tag_sources" do
    it "defaults to [:tag, :dimension]" do
      expect(config.sidekiq_job_tag_sources).to eq(%i[tag dimension])
    end

    it "accepts a bounded-only subset" do
      config.sidekiq_job_tag_sources = %i[dimension]
      expect(config.sidekiq_job_tag_sources).to eq(%i[dimension])
    end

    it "accepts an empty array (disables the sink)" do
      config.sidekiq_job_tag_sources = []
      expect(config.sidekiq_job_tag_sources).to eq([])
    end

    it "raises on an unknown source" do
      expect { config.sidekiq_job_tag_sources = %i[tag bogus] }.to raise_error(ArgumentError)
    end

    it "raises on a non-array value" do
      expect { config.sidekiq_job_tag_sources = :tag }.to raise_error(ArgumentError)
    end
  end

  describe "#coerce_input_types" do
    after { config.remove_instance_variable(:@coerce_input_types) if config.instance_variable_defined?(:@coerce_input_types) }

    it "defaults to false" do
      expect(config.coerce_input_types).to be(false)
    end

    it "accepts a boolean" do
      config.coerce_input_types = true
      expect(config.coerce_input_types).to be(true)
    end

    it "raises on a non-boolean value" do
      expect { config.coerce_input_types = :yes }.to raise_error(ArgumentError)
    end
  end
end

RSpec.describe "per-class config overrides on actions" do
  let(:action) { Class.new { include Axn } }

  after do
    # NOTE: unlike the hand-rolled settings elsewhere in this file (on_exception,
    # ambient_context_provider), which use `@ivar ||= default` and so treat nil as
    # "unset", the Settings-flavor reader (lib/axn/configurable.rb) memoizes via
    # `instance_variable_defined?` — once set, even to nil, it never recomputes the
    # default. `instance_variable_set(:@sidekiq_job_tag_sources, nil)` therefore does
    # NOT reset this setting to its default; it wedges it at nil for every subsequent
    # example. Removing the ivar entirely restores the "recompute default on next
    # read" behavior the other resets rely on.
    Axn.config.remove_instance_variable(:@sidekiq_job_tag_sources) if Axn.config.instance_variable_defined?(:@sidekiq_job_tag_sources)
  end

  it "gives every action the override accessors for sidekiq_job_tag_sources" do
    expect(action).to respond_to(:sidekiq_job_tag_sources)
    expect(action).to respond_to(:sidekiq_job_tag_sources?)
    expect(action).to respond_to(:sidekiq_job_tag_sources_override)
    expect(action).not_to respond_to(:resolved_sidekiq_job_tag_sources)
  end

  it "resolves to Axn.config by default (no per-class override)" do
    expect(action.sidekiq_job_tag_sources).to eq(%i[tag dimension])
    expect(action.sidekiq_job_tag_sources_override).to equal(Axn::Configurable::UNSET)
  end

  it "tracks a change to the library-level value" do
    Axn.config.sidekiq_job_tag_sources = %i[dimension]
    expect(action.sidekiq_job_tag_sources).to eq(%i[dimension])
  end

  it "resolves to the per-class override when set, leaving Axn.config untouched" do
    action.sidekiq_job_tag_sources %i[dimension]
    expect(action.sidekiq_job_tag_sources).to eq(%i[dimension])
    expect(Axn.config.sidekiq_job_tag_sources).to eq(%i[tag dimension])
  end

  it "validates a per-class override at set time" do
    expect { action.sidekiq_job_tag_sources %i[bogus] }.to raise_error(ArgumentError)
  end

  it "reads a value written through the no-arg configure bag (core namespace)" do
    action.configure { |c| c.sidekiq_job_tag_sources = %i[dimension] }
    expect(action.sidekiq_job_tag_sources).to eq(%i[dimension])
  end

  it "rejects a typo'd setter in the no-arg configure bag (core schema is always known)" do
    expect { action.configure { |c| c.sidekiq_job_tag_sorces = %i[dimension] } }
      .to raise_error(ArgumentError, /unknown overridable setting/)
  end

  it "validates the value in the no-arg configure bag" do
    expect { action.configure { |c| c.sidekiq_job_tag_sources = %i[bogus] } }.to raise_error(ArgumentError)
  end

  it "always exposes axn_configure as the collision-proof form" do
    action.axn_configure { |c| c.sidekiq_job_tag_sources = %i[dimension] }
    expect(action.sidekiq_job_tag_sources).to eq(%i[dimension])
  end

  it "inherits a per-class override into subclasses" do
    action.sidekiq_job_tag_sources %i[dimension]
    expect(Class.new(action).sidekiq_job_tag_sources).to eq(%i[dimension])
  end

  it "does not leak a per-class override to a sibling action" do
    action.sidekiq_job_tag_sources %i[dimension]
    sibling = Class.new { include Axn }
    expect(sibling.sidekiq_job_tag_sources).to eq(%i[tag dimension])
  end

  # PRO-2875 makes the generic Naming/SchemaReflection DSLs DEFER to a base's same-named class
  # method. Override accessors are opt-in, so axn still installs them (deferring would silently deny
  # the requested override) — but the collision is surfaced with a debug breadcrumb, not silent.
  describe "collision with a non-axn ancestor's same-named class method" do
    let(:base) { Class.new { def self.sidekiq_job_tag_sources(*) = :base_value } }

    it "leaves a debug breadcrumb rather than shadowing silently" do
      messages = []
      allow(Axn.config.logger).to receive(:debug) { |*args, &block| messages << (block ? block.call : args.first) }
      Class.new(base) { include Axn } # trigger the overrides include hook
      expect(messages).to include(a_string_matching(/override accessor `sidekiq_job_tag_sources` collides/))
    end

    it "still installs the opt-in accessor (does not defer)" do
      action = Class.new(base) { include Axn }
      action.sidekiq_job_tag_sources %i[dimension]
      expect(action.sidekiq_job_tag_sources).to eq(%i[dimension])
    end

    it "leaves a breadcrumb when the predicate name collides" do
      predicate_base = Class.new { def self.sidekiq_job_tag_sources? = :base_value }
      messages = []
      allow(Axn.config.logger).to receive(:debug) { |*args, &block| messages << (block ? block.call : args.first) }
      Class.new(predicate_base) { include Axn }
      expect(messages).to include(a_string_matching(/override accessor `sidekiq_job_tag_sources\?` collides/))
    end
  end
end
