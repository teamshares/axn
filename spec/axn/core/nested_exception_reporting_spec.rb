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

  it "reports once at the outer when the inner fails_on the exception (no inner report) but the outer does not" do
    # inner: ArgumentError reclassified to a failure → no report there, original preserved on result.exception.
    # outer call! re-raises the original ArgumentError → outer is the first level to treat it as a reportable
    # exception, so it reports exactly once (and tags it).
    stub_const("FailsOnInner", build_axn do
      fails_on(ArgumentError)
      def call = raise(ArgumentError, "expected business error")
    end)
    stub_const("OuterNoFailsOn", build_axn { def call = FailsOnInner.call! })
    expect(OuterNoFailsOn.call).not_to be_ok
    expect(reports.size).to eq(1)
    expect(reports.first.last).to eq(OuterNoFailsOn)
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
end
