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

  it "reports at most once, at the innermost action — no ancestor retry when the attempt raises" do
    # Delivery is best-effort EXACTLY once: the exception is marked reported BEFORE the attempt, so if
    # the innermost report raises (swallowed + logged via piping-error) it is NOT retried from an
    # ancestor. Deterministic regardless of nesting depth; a persistently-failing handler drops the
    # report either way, and we don't butt our head against it once per level.
    attempts = 0
    always_fails = lambda do |_exception, **|
      attempts += 1
      raise "reporter boom"
    end
    Axn.config.instance_variable_set(:@on_exception, always_fails)

    stub_const("InnerReportFails", build_axn { def call = raise("kaboom") })
    stub_const("OuterReporter", build_axn { def call = InnerReportFails.call! })

    expect(OuterReporter.call).not_to be_ok
    expect(attempts).to eq(1) # one attempt at the innermost; never retried at the ancestor
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

    it "reports outcome `failure` to an ancestor's on_error, even though it runs before the context flag is set" do
      # The ancestor doesn't declare fails_on, so its own _fails_on? is false and the executor only
      # sets __classify_as_failure! *after* dispatching on_error. The sticky classification (set by
      # the inner action) must make result.outcome read `failure` at on_error time anyway.
      observed = []
      stub_const("StickyInner", build_axn do
        fails_on(ArgumentError)
        def call = raise(ArgumentError, "expected")
      end)
      stub_const("BubbleParent", build_axn do
        on_error { observed << result.outcome.to_s }
        def call = StickyInner.call!
      end)

      result = BubbleParent.call
      expect(result.outcome).to eq("failure")
      expect(observed).to eq(["failure"]) # not "exception"
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

    it "keeps an already-reported inner exception reported even when an ancestor's fails_on reclassifies it to failure" do
      # Mixed outcome (documented sharp edge): classification flows OUTWARD only. The inner action
      # does not expect ArgumentError → it reports it as a bug. The ancestor's fails_on then
      # reclassifies the bubbled object to a failure for the *outcome*, but cannot un-send the report
      # the inner level already emitted. Declare fails_on on the action that RAISES to suppress it.
      stub_const("InnerReportsBug", build_axn { def call = raise(ArgumentError, "boom") }) # no fails_on
      stub_const("OuterReclassifies", build_axn do
        fails_on(ArgumentError) # ancestor treats it as expected — too late to suppress the report
        def call = InnerReportsBug.call!
      end)

      result = OuterReclassifies.call
      expect(result.outcome).to eq("failure") # ancestor's classification wins for the outcome
      expect(reports.size).to eq(1)           # ...but the inner level already reported it
      expect(reports.first.last).to eq(InnerReportsBug)
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

    # The dedup set keys on object identity (compare_by_identity), not value equality — so an
    # exception class that overrides ==/eql?/hash can't make two distinct, separately-raised
    # exceptions collapse into one and silently drop a report.
    it "dedupes by object identity even when exceptions are value-equal (==/eql?)" do
      # Every instance claims equality with every other (value equality, not identity).
      eq_class = Class.new(StandardError) do
        def eql?(_other) = true
        def hash = 42
        alias_method :==, :eql?
      end
      stub_const("ValueEqualError", eq_class)
      stub_const("InnerEq", build_axn { def call = raise ValueEqualError, "inner" })
      stub_const("OuterEq", build_axn do
        def call
          InnerEq.call! # inner raises + reports one instance, then we discard it...
        rescue ValueEqualError
          raise ValueEqualError, "outer" # ...and raise a DIFFERENT, value-equal instance
        end
      end)

      OuterEq.call
      expect(reports.size).to eq(2) # both distinct objects reported, not deduped by value
    end

    # Defensive: the normal lifecycle clears state on the way OUT (when the stack empties). But if a
    # prior run ever left state behind without draining the stack (e.g. an executor invoked outside
    # NestingTracking.tracking, or an aborted teardown), a fresh top-level run must NOT inherit a
    # stale "already reported" mark and silently drop a real report. tracking also resets on the way
    # IN whenever it opens a fresh (empty-stack) tree.
    it "does not inherit report-dedup state leaked from a prior run (entry-guard reset)" do
      leaked = RuntimeError.new("leaked boom")
      Axn::Internal::ExceptionClassification.mark_reported!(leaked) # simulate leftover state
      expect(Axn::Internal::ExceptionClassification.reported?(leaked)).to be(true)

      klass = build_axn {}
      klass.send(:define_method, :call) { raise leaked } # raise the SAME object that was pre-marked

      expect(klass.call).not_to be_ok
      expect(reports.size).to eq(1) # reported despite the stale mark — entry-guard cleared it
    end
  end
end
