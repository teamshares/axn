# frozen_string_literal: true

# A nested `call!` re-raises the same exception object up the stack. The global on_exception report
# (e.g. Honeybadger) must fire ONCE per exception, not once per executor it passes through.
RSpec.describe "Nested exception reporting (report once)" do
  let(:reports) { [] }
  let(:original) { Axn.config.instance_variable_get(:@on_exception) }

  before do
    sink = reports
    Axn.config.instance_variable_set(:@on_exception, ->(exception, action:, **) { sink << [exception, action.class] })
  end

  after { Axn.config.instance_variable_set(:@on_exception, original) }

  it "reports a top-level unhandled exception once (baseline)" do
    stub_const("TopBug", build_axn { def call = raise("top boom") })
    expect(TopBug.call).not_to be_ok
    expect(reports.size).to eq(1)
  end

  it "reports once when re-raised through a nested call! (depth 2)" do
    stub_const("InnerBug", build_axn { def call = raise("kaboom") })
    stub_const("OuterBug", build_axn { def call = InnerBug.call! })
    expect(OuterBug.call).not_to be_ok
    expect(reports.size).to eq(1)
    expect(reports.first.first.message).to eq("kaboom")
  end

  it "reports once through two levels of nested call! (depth 3)" do
    stub_const("InnerBug3", build_axn { def call = raise("deep boom") })
    stub_const("MidBug3", build_axn { def call = InnerBug3.call! })
    stub_const("OuterBug3", build_axn { def call = MidBug3.call! })
    expect(OuterBug3.call).not_to be_ok
    expect(reports.size).to eq(1)
  end

  describe "a fails_on classification is sticky across nested call!" do
    it "treats a fails_on-reclassified exception as a failure (no report, failure outcome) when bubbled via call!" do
      stub_const("ExpectedInner", build_axn do
        fails_on(ArgumentError) # "email already used" style: expected, not a bug
        def call = raise(ArgumentError, "expected business outcome")
      end)
      stub_const("BubblingParent", build_axn { def call = ExpectedInner.call! }) # parent knows nothing of ArgumentError

      result = BubblingParent.call
      expect(result).not_to be_ok
      expect(result.outcome).to eq("failure")          # not "exception"
      expect(result.exception).to be_a(ArgumentError)  # original preserved
      expect(reports).to be_empty                      # not reported at the parent
    end

    it "stays sticky through two levels of call!" do
      stub_const("ExpectedInner3", build_axn do
        fails_on(ArgumentError)
        def call = raise(ArgumentError, "expected")
      end)
      stub_const("MidPassthrough", build_axn { def call = ExpectedInner3.call! })
      stub_const("OuterPassthrough", build_axn { def call = MidPassthrough.call! })

      result = OuterPassthrough.call
      expect(result.outcome).to eq("failure")
      expect(reports).to be_empty
    end

    it "does NOT make an unrelated same-class exception a failure (tag is per-object, not per-class)" do
      # ExpectedOk declares fails_on(ArgumentError) but never raises it; the parent then raises its
      # OWN ArgumentError. That object was never classified by a fails_on, so it stays an exception.
      stub_const("ExpectedOk", build_axn do
        fails_on(ArgumentError)
        def call = nil
      end)
      stub_const("ParentOwnBug", build_axn do
        def call
          ExpectedOk.call!
          raise ArgumentError, "outer's own unrelated bug"
        end
      end)

      result = ParentOwnBug.call
      expect(result).not_to be_ok
      expect(result.outcome).to eq("exception") # unrelated ArgumentError is still a bug
      expect(reports.size).to eq(1) # and is reported
      expect(reports.first.last).to eq(ParentOwnBug)
    end
  end

  it "still fires each action's own on_exception callback at its level (only the global report is deduped)" do
    callbacks = []
    stub_const("CB_SINK", callbacks)
    stub_const("CbInner", build_axn do
      on_exception { |_e| CB_SINK << :inner }
      def call = raise("cb boom")
    end)
    stub_const("CbOuter", build_axn do
      on_exception { |_e| CB_SINK << :outer }
      def call = CbInner.call!
    end)

    expect(CbOuter.call).not_to be_ok
    expect(callbacks).to contain_exactly(:inner, :outer) # per-action callbacks fire at BOTH levels
    expect(reports.size).to eq(1)                        # but the global report fires once
  end

  describe "dedup/classification is scoped to one execution, not stored on the exception forever" do
    it "reports the same exception object again when re-raised by a later, independent run" do
      stub_const("SHARED_BUG", RuntimeError.new("shared boom"))
      stub_const("RaiserA", build_axn { def call = raise SHARED_BUG })
      stub_const("RaiserB", build_axn { def call = raise SHARED_BUG })

      RaiserA.call
      RaiserB.call
      expect(reports.size).to eq(2) # once per independent execution — not deduped across runs
    end

    it "does not let a stale fails_on classification suppress a later independent run" do
      stub_const("SHARED_ARGERR", ArgumentError.new("shared"))
      stub_const("FailsOnReuser", build_axn do
        fails_on(ArgumentError)
        def call = raise SHARED_ARGERR
      end)
      stub_const("PlainReuser", build_axn { def call = raise SHARED_ARGERR }) # no fails_on

      FailsOnReuser.call # classifies SHARED_ARGERR as a failure (no report) — then its tree clears
      result = PlainReuser.call # fresh tree: same object is now an unhandled bug
      expect(result.outcome).to eq("exception")
      expect(reports.size).to eq(1)
    end
  end
end
