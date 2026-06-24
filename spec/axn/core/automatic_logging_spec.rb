# frozen_string_literal: true

RSpec.describe Axn::Core::AutomaticLogging do
  let(:log_messages) { [] }

  # Capture whichever level(s) a given example exercises.
  def capture(action, *levels)
    levels.each do |level|
      allow(action).to receive(level) do |message, **options|
        log_messages << { level:, message:, options: }
      end
    end
  end

  def before_log = log_messages.find { |log| log[:message].include?("About to execute") }
  def after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

  describe "default (no auto_log declaration)" do
    let(:action) { build_axn }

    before { capture(action, :info) }

    it "logs before and after at the configured level for a successful call" do
      action.call

      expect(log_messages.length).to eq(2)
      expect(log_messages.map { |l| l[:level] }).to all(eq(:info))
      expect(before_log).to be_present
      expect(after_log).to be_present
      expect(after_log[:message]).to include("success")
    end

    it "includes timing information in the after log" do
      action.call
      expect(after_log[:message]).to match(/in \d+\.\d+ milliseconds/)
    end

    it "logs failure outcomes" do
      action = build_axn { def call = fail!("nope") }
      capture(action, :info)

      action.call

      expect(after_log[:message]).to include("failure")
    end

    it "logs exception outcomes" do
      action = build_axn { def call = raise("boom") }
      capture(action, :info)

      expect { action.call! }.to raise_error("boom")

      expect(after_log[:message]).to include("exception")
    end
  end

  describe "auto_log <level> (all outcomes)" do
    let(:action) { build_axn { auto_log :warn } }

    before { capture(action, :warn) }

    it "logs before and after at the given level" do
      action.call

      expect(log_messages.length).to eq(2)
      expect(log_messages.map { |l| l[:level] }).to all(eq(:warn))
      expect(before_log).to be_present
      expect(after_log).to be_present
    end
  end

  describe "auto_log true / auto_log (no arg)" do
    it "behaves identically to the default for no-arg" do
      action = build_axn { auto_log }
      capture(action, :info)

      action.call

      expect(log_messages.length).to eq(2)
      expect(log_messages.map { |l| l[:level] }).to all(eq(:info))
    end

    it "behaves identically to the default for true" do
      action = build_axn { auto_log true }
      capture(action, :info)

      action.call

      expect(log_messages.length).to eq(2)
      expect(log_messages.map { |l| l[:level] }).to all(eq(:info))
    end
  end

  describe "auto_log false" do
    it "logs nothing on success" do
      action = build_axn { auto_log false }
      action.call
      expect(log_messages).to be_empty
    end

    it "logs nothing on failure" do
      action = build_axn do
        auto_log false
        def call = fail!("nope")
      end
      action.call
      expect(log_messages).to be_empty
    end

    it "logs nothing on exception" do
      action = build_axn do
        auto_log false
        def call = raise("boom")
      end
      expect { action.call! }.to raise_error("boom")
      expect(log_messages).to be_empty
    end
  end

  describe "auto_log <level>, success: false (errors only)" do
    it "logs nothing on success (and no before line)" do
      action = build_axn { auto_log :warn, success: false }
      capture(action, :warn)

      action.call

      expect(log_messages).to be_empty
    end

    it "logs the after line on failure at the given level, with no before line" do
      action = build_axn do
        auto_log :warn, success: false
        def call = fail!("nope")
      end
      capture(action, :warn)

      action.call

      expect(log_messages.length).to eq(1)
      expect(before_log).to be_nil
      expect(after_log[:level]).to eq(:warn)
      expect(after_log[:message]).to include("failure")
    end

    it "logs the after line on exception at the given level, with no before line" do
      action = build_axn do
        auto_log :warn, success: false
        def call = raise("boom")
      end
      capture(action, :warn)

      expect { action.call! }.to raise_error("boom")

      expect(log_messages.length).to eq(1)
      expect(before_log).to be_nil
      expect(after_log[:level]).to eq(:warn)
      expect(after_log[:message]).to include("exception")
    end
  end

  describe "auto_log exception: <level> (raised bugs only)" do
    it "logs nothing on success" do
      action = build_axn { auto_log exception: :error }
      capture(action, :error)
      action.call
      expect(log_messages).to be_empty
    end

    it "logs nothing on an explicit fail!" do
      action = build_axn do
        auto_log exception: :error
        def call = fail!("nope")
      end
      capture(action, :error)
      action.call
      expect(log_messages).to be_empty
    end

    it "logs the after line on a raised exception" do
      action = build_axn do
        auto_log exception: :error
        def call = raise("boom")
      end
      capture(action, :error)

      expect { action.call! }.to raise_error("boom")

      expect(log_messages.length).to eq(1)
      expect(before_log).to be_nil
      expect(after_log[:level]).to eq(:error)
      expect(after_log[:message]).to include("exception")
    end
  end

  describe "before-line tracks the success level" do
    it "emits the before line at the (quieter) success level, not a fixed floor" do
      action = build_axn { auto_log :debug }
      capture(action, :debug)

      action.call

      expect(before_log[:level]).to eq(:debug)
      expect(after_log[:level]).to eq(:debug)
    end
  end

  describe "validation" do
    it "raises for an invalid positional level" do
      expect { build_axn { auto_log :bogus } }.to raise_error(ArgumentError, /log level/i)
    end

    it "raises for an invalid per-outcome level" do
      expect { build_axn { auto_log success: :bogus } }.to raise_error(ArgumentError, /log level/i)
    end

    it "raises for an unknown outcome key" do
      expect { build_axn { auto_log foo: :warn } }.to raise_error(ArgumentError, /outcome/i)
    end

    it "raises when given more than one positional argument" do
      expect { build_axn { auto_log :info, :warn } }.to raise_error(ArgumentError)
    end

    it "accepts string-keyed outcome overrides (indifferent access)" do
      action = build_axn do
        auto_log("exception" => :error)
        def call = raise("boom")
      end
      capture(action, :error)

      expect { action.call! }.to raise_error("boom")

      expect(log_messages.length).to eq(1)
      expect(after_log[:level]).to eq(:error)
    end
  end

  describe "respects a globally overridden Axn.config.log_level" do
    around do |example|
      original = Axn.config.log_level
      Axn.config.log_level = :debug
      example.run
      Axn.config.log_level = original
    end

    it "uses the configured default level when none is declared" do
      action = build_axn
      capture(action, :debug)

      action.call

      expect(log_messages.length).to eq(2)
      expect(log_messages.map { |l| l[:level] }).to all(eq(:debug))
    end
  end

  describe "inheritance" do
    let(:parent_action_class) { build_axn { auto_log :debug } }

    it "inherits the auto_log setting" do
      capture(parent_action_class, :debug)

      parent_action_class.call

      expect(log_messages.length).to eq(2)
      expect(log_messages.map { |l| l[:level] }).to all(eq(:debug))
    end

    it "lets a child override the setting" do
      child_action = Class.new(parent_action_class) do
        auto_log :warn
        def call; end
      end
      capture(child_action, :warn)

      child_action.call

      expect(log_messages.length).to eq(2)
      expect(log_messages.map { |l| l[:level] }).to all(eq(:warn))
    end

    it "inherits an errors-only setting" do
      parent = build_axn do
        auto_log :error, success: false
        def call = fail!("Parent error")
      end
      capture(parent, :error)

      parent.call

      expect(log_messages.length).to eq(1)
      expect(after_log[:level]).to eq(:error)
    end
  end

  describe "log separators with nested actions" do
    let(:log_messages) { [] }
    let(:logger) { instance_double(Logger, info: nil) }

    before do
      allow(Axn.config).to receive(:logger).and_return(logger)
      allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      # Simulate running in a log file context (not console, not background)
      allow(Axn::Util::ExecutionContext).to receive(:console?).and_return(false)
      allow(Axn::Util::ExecutionContext).to receive(:background?).and_return(false)
      allow(logger).to receive(:info) do |message|
        log_messages << message
      end
    end

    context "when action is called at top level" do
      let(:action) { build_axn }

      it "includes separator before and after logs" do
        action.call

        outer_before = log_messages.find { |msg| msg.include?("About to execute") }
        outer_after = log_messages.find { |msg| msg.include?("Execution completed") }

        expect(outer_before).to start_with("\n------\n")
        expect(outer_after).to end_with("\n------\n")
      end
    end

    context "when action is nested" do
      let(:outer_action) do
        inner = inner_action
        build_axn do
          define_method(:call) { inner.call }
        end
      end

      let(:inner_action) { build_axn }

      it "includes separator only for outer action, not inner" do
        outer_action.call

        outer_before = log_messages.find { |msg| msg.include?("About to execute") && !msg.include?(" > ") }
        inner_before = log_messages.find { |msg| msg.include?("About to execute") && msg.include?(" > ") }
        inner_after = log_messages.find { |msg| msg.include?("Execution completed") && msg.include?(" > ") }
        outer_after = log_messages.find { |msg| msg.include?("Execution completed") && !msg.include?(" > ") }

        expect(outer_before).to start_with("\n------\n")
        expect(outer_after).to end_with("\n------\n")
        expect(inner_before).not_to start_with("\n------\n")
        expect(inner_after).not_to end_with("\n------\n")
      end
    end

    context "when in production environment" do
      before do
        allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      end

      let(:action) { build_axn }

      it "does not include separators" do
        action.call

        expect(log_messages.find { |msg| msg.include?("About to execute") }).not_to include("------")
        expect(log_messages.find { |msg| msg.include?("Execution completed") }).not_to include("------")
      end
    end
  end

  # NOTE: enqueue-time async invocation logging (log once, success-level gating, disabled,
  # sensitive-field filtering) is covered against the real generic-worker Sidekiq adapter in the
  # Rails dummy app: spec_rails/dummy_app/spec/axn/core/automatic_logging_spec.rb
end
