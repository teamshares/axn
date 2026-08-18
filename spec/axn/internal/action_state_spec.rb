# frozen_string_literal: true

RSpec.describe Axn::Internal::ActionState do
  describe ".result" do
    it "reaches the real result through a `def result` shadow" do
      klass = build_axn do
        def result = "shadowed"
      end
      action = klass.send(:new)

      expect(action.result).to eq("shadowed")
      expect(described_class.result(action)).to be_a(Axn::Result)
    end

    it "reaches the real result through an `expects :result` reader shadow" do
      klass = build_axn { expects :result }
      action = klass.send(:new, result: 42)

      expect(action.result).to eq(42)
      expect(described_class.result(action)).to be_a(Axn::Result)
    end

    it "preserves memoization (same object across calls)" do
      action = build_axn {}.send(:new)

      expect(described_class.result(action)).to be(described_class.result(action))
    end
  end

  describe ".internal_context" do
    it "reaches the real context through a shadow" do
      klass = build_axn { expects :internal_context }
      action = klass.send(:new, internal_context: "shadowed")

      expect(described_class.internal_context(action)).to be_a(Axn::Core::InternalContext)
    end
  end

  describe ".log" do
    it "reaches the logger through a `log` shadow" do
      logged = []
      allow(Axn.config.logger).to receive(:warn) { |msg| logged << msg }

      klass = build_axn { expects :log }
      action = klass.send(:new, log: "an input value")

      described_class.log(action, "internal message", level: :warn)

      expect(logged.last).to include("internal message")
    end

    it "accepts an action CLASS and nil, which several guards legitimately hold" do
      logged = []
      allow(Axn.config.logger).to receive(:warn) { |msg| logged << msg }

      described_class.log(build_axn {}, "from a class", level: :warn)
      described_class.log(nil, "from nil", level: :warn)

      expect(logged).to include(a_string_including("from a class"), a_string_including("from nil"))
    end

    it "warns through the configured logger for a target it cannot identify" do
      logged = []
      allow(Axn.config.logger).to receive(:warn) { |msg| logged << msg }

      described_class.log(Object.new, "from a stranger", level: :warn)

      expect(logged.last).to include("from a stranger")
    end
  end

  describe ".expose / .inputs" do
    it "reaches the real implementations through shadows" do
      klass = build_axn do
        expects :name
        exposes :out
        def inputs = raise("user's inputs must not be called by internals")
        def expose(*) = raise("user's expose must not be called by internals")
      end
      action = klass.send(:new, name: "an input value")

      described_class.expose(action, out: 7)

      expect(described_class.result(action).out).to eq(7)
      expect(described_class.inputs(action)).to eq({ name: "an input value" })
    end

    # Sugar reaching sugar is the same defect: `inputs` read its values off a self-sent
    # `internal_context`, so taking that name redirected the whole hash at the user's own value.
    it "resolves `inputs` without dispatching a shadowed `internal_context`" do
      klass = build_axn do
        expects :name
        def internal_context = :taken_by_the_user
      end
      action = klass.send(:new, name: "an input value")

      expect(described_class.inputs(action)).to eq({ name: "an input value" })
    end
  end

  describe "the sugar that reads through internal_context" do
    it "answers default_error / default_success through a shadow" do
      klass = build_axn do
        error "declared failure"
        success "declared success"
        def internal_context = :taken_by_the_user
      end
      action = klass.send(:new)

      expect(action.default_error).to eq("declared failure")
      expect(action.default_success).to eq("declared success")
    end
  end

  describe ".execution_context / .ambient_context / the logging slices" do
    it "reaches the real implementations through shadows" do
      klass = build_axn do
        expects :name
        def execution_context = raise("user's execution_context must not be called by internals")
        def ambient_context = raise("user's ambient_context must not be called by internals")
        def inputs_for_logging = raise("user's inputs_for_logging must not be called by internals")
        def outputs_for_logging = raise("user's outputs_for_logging must not be called by internals")
      end
      action = klass.send(:new, name: "an input value")

      expect(described_class.execution_context(action)).to include(inputs: { name: "an input value" })
      expect(described_class.ambient_context(action)).to eq({})
      expect(described_class.inputs_for_logging(action)).to eq({ name: "an input value" })
      expect(described_class.outputs_for_logging(action)).to eq({})
    end
  end

  describe ".expose_from_result" do
    it "forwards a sub-result's exposures through a shadow" do
      klass = build_axn do
        exposes :out
        def expose(*) = raise("user's expose must not be called by internals")
        def _expose_from_result(*, **) = raise("user's _expose_from_result must not be called by internals")
      end
      action = klass.send(:new)

      described_class.expose_from_result(action, Axn::Result.ok(out: 7), require_overlap: false)

      expect(described_class.result(action).out).to eq(7)
    end
  end

  describe ".instance? / .result_or_nil" do
    it "discriminates an action instance from a class, nil, and an unrelated object" do
      klass = build_axn {}

      expect(described_class.instance?(klass.send(:new))).to be true
      expect(described_class.instance?(klass)).to be false
      expect(described_class.instance?(nil)).to be false
      expect(described_class.instance?(Object.new)).to be false
    end

    it "returns nil rather than raising for a non-instance" do
      expect(described_class.result_or_nil(nil)).to be_nil
      expect(described_class.result_or_nil(build_axn {})).to be_nil
    end

    it "is not fooled by an object that merely responds to :result" do
      impostor = Class.new { def result = "not an action" }.new

      expect(impostor).to respond_to(:result)
      expect(described_class.result_or_nil(impostor)).to be_nil
    end
  end
  describe ".report_proxy? / proxy handling" do
    let(:proxy) { Axn::Async::ExceptionReporting::DiscardedJobAction.new(build_axn {}, RuntimeError.new("boom")) }

    it "recognises a proxy axn built in place of an instance" do
      expect(described_class.report_proxy?(proxy)).to be true
      expect(described_class.instance?(proxy)).to be false
    end

    it "reads the proxy's own result rather than reporting none" do
      expect(described_class.result_or_nil(proxy).error).to eq("boom")
    end

    it "routes the proxy's log through the proxy, keeping its level and prefix" do
      lines = []
      allow(Axn.config.logger).to receive(:warn) { |message| lines << message }

      described_class.log(proxy, "MSG")

      expect(lines).to eq(["[Axn::DiscardedJob] MSG"])
    end

    it "cannot be claimed by a user's declaration" do
      impostor = build_axn { expects :result }.send(:new, result: "mine")

      expect(described_class.report_proxy?(impostor)).to be false
      expect(described_class.result_or_nil(impostor)).to be_a(Axn::Result)
    end

    it "is nil for a plain foreign object" do
      expect(described_class.report_proxy?(Object.new)).to be false
      expect(described_class.result_or_nil(Object.new)).to be_nil
    end
  end
  describe "both supported inclusion paths" do
    # A base class may `include Axn::Core` directly instead of `include Axn` (see
    # spec/inheritance_callback_spec.rb). Those are real actions, and asking `Axn === obj` rejected them —
    # so the funnel discarded their result and their reports degraded to the raw exception.
    let(:core_only) do
      Class.new do
        include Axn::Core
        exposes :out
        def call = expose(out: "ran")
      end
    end

    it "recognises an instance of a class that includes Axn::Core directly" do
      action = core_only.send(:new)

      expect(described_class.instance?(action)).to be true
      expect(described_class.result_or_nil(action)).to be_a(Axn::Result)
    end

    it "still recognises an instance of a class that includes Axn" do
      action = build_axn {}.send(:new)

      expect(described_class.instance?(action)).to be true
      expect(described_class.result_or_nil(action)).to be_a(Axn::Result)
    end

    it "reads the real result through a shadow on either path" do
      shadowed = Class.new do
        include Axn::Core
        def result = "shadowed"
      end.send(:new)

      expect(shadowed.result).to eq("shadowed")
      expect(described_class.result(shadowed)).to be_a(Axn::Result)
    end
  end
end
