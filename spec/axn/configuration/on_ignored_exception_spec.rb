# frozen_string_literal: true

# An exception raised inside a `best_effort` guard is IGNORED: it never reaches the result, so nothing
# downstream can observe that it happened. `on_ignored_exception` is the only channel by which it
# becomes visible — see docs/reference/configuration.md.
RSpec.describe "Axn.config.on_ignored_exception" do
  def build_axn(&declaration)
    Class.new do
      include Axn
      def call = nil
    end.tap { |klass| klass.class_eval(&declaration) }
  end

  let(:reports) { [] }
  let(:reporter) { ->(e, action:, context:) { reports << { exception: e, action:, context: } } }

  before do
    Axn.config.on_exception = nil
    Axn.config.on_ignored_exception = nil
  end

  after do
    Axn.config.on_exception = nil
    Axn.config.on_ignored_exception = nil
  end

  # An action that succeeds while its on_success callback blows up: the caller sees ok?, and the
  # side effect silently did not happen. The case the hook exists for.
  let(:succeeds_with_broken_callback) do
    build_axn do
      on_success { raise "boom in on_success" }
    end
  end

  describe "routing" do
    it "defaults to the configured on_exception handler" do
      Axn.config.on_exception = reporter

      expect(succeeds_with_broken_callback.call).to be_ok
      expect(reports.size).to eq(1)
      expect(reports.first[:exception].message).to eq("boom in on_success")
    end

    it "prefers an explicit on_ignored_exception handler over on_exception" do
      Axn.config.on_exception = ->(*) { raise "on_exception should not be used" }
      Axn.config.on_ignored_exception = reporter

      succeeds_with_broken_callback.call
      expect(reports.size).to eq(1)
    end

    it "is disabled by assigning false, even with on_exception configured" do
      Axn.config.on_exception = reporter
      Axn.config.on_ignored_exception = false

      expect(succeeds_with_broken_callback.call).to be_ok
      expect(reports).to be_empty
    end

    it "assigning nil restores the default routing" do
      Axn.config.on_exception = reporter
      Axn.config.on_ignored_exception = false
      Axn.config.on_ignored_exception = nil

      succeeds_with_broken_callback.call
      expect(reports.size).to eq(1)
    end

    it "does nothing when no handler is configured anywhere" do
      expect { succeeds_with_broken_callback.call }.not_to raise_error
      expect(reports).to be_empty
    end

    it "rejects a non-callable at assignment" do
      expect { Axn.config.on_ignored_exception = "nope" }.to raise_error(ArgumentError, /must be callable/)
    end
  end

  describe "the reported exception" do
    before { Axn.config.on_ignored_exception = reporter }

    # NOT wrapped in an axn-owned class: the reporter's grouping (Honeybadger et al) keys on the
    # exception class and backtrace, and a wrapper would collapse every ignored failure into one bucket
    # while hiding the class that actually raised.
    it "is the original exception, unwrapped" do
      succeeds_with_broken_callback.call

      reported = reports.first[:exception]
      expect(reported).to be_a(RuntimeError)
      expect(reported.message).to eq("boom in on_success")
    end
  end

  describe "context[:axn_ignored]" do
    before { Axn.config.on_ignored_exception = reporter }

    def ignored_context = reports.first[:context][:axn_ignored]

    it "names what was being attempted, per callback phase" do
      succeeds_with_broken_callback.call
      expect(ignored_context[:while]).to eq("executing on_success callback")
    end

    it "distinguishes an on_error callback from an on_success one" do
      build_axn do
        on_error { raise "boom in on_error" }
        def call = raise("real body failure")
      end.call

      expect(ignored_context[:while]).to eq("executing on_error callback")
    end

    # The severity discriminator: a swallowed failure on an action that SUCCEEDED means the caller got
    # their result and a side effect vanished. One on an already-failed action is collateral to a
    # failure that on_exception is reporting separately.
    it "reports the surrounding outcome as success when the action succeeded" do
      succeeds_with_broken_callback.call
      expect(ignored_context[:outcome]).to eq("success")
    end

    it "reports the surrounding outcome as exception when the action raised" do
      build_axn do
        on_error { raise "boom in on_error" }
        def call = raise("real body failure")
      end.call

      expect(ignored_context[:outcome]).to eq("exception")
    end

    it "reports the surrounding outcome as failure when the action failed" do
      build_axn do
        on_failure { raise "boom in on_failure" }
        def call = fail!("nope")
      end.call

      expect(ignored_context[:outcome]).to eq("failure")
    end

    # Mid-flight, `outcome` reads "success" only because nothing has settled yet — a lie. Gated on
    # finalized?, so the key is omitted rather than misleading.
    it "omits the outcome when the action has not settled yet" do
      build_axn do
        tag(:region) { raise "boom in tag resolver" }
      end.call

      expect(ignored_context[:while]).to eq("resolving observability facet region")
      expect(ignored_context).not_to have_key(:outcome)
    end

    it "omits the outcome when there is no action to ask" do
      Axn::Extensions.best_effort("doing something unattached") { raise "boom" }

      expect(ignored_context[:while]).to eq("doing something unattached")
      expect(ignored_context).not_to have_key(:outcome)
    end
  end

  describe "resilience" do
    # `trigger_on_exception` runs INSIDE a best_effort guard, so an on_exception handler that raises is
    # itself an ignored exception. It is deliberately NOT reported back through the handler that just
    # raised: useless when the handler is persistently broken, and an amplifier when a provider is
    # degraded (two calls per exception instead of one). The warning log still names it. See
    # `best_effort(report_ignored:)`.
    it "does not report a failing on_exception handler back through itself" do
      calls = 0
      Axn.config.on_exception = lambda { |*|
        calls += 1
        raise "reporter is down"
      }

      build_axn { def call = raise("real body failure") }.call

      expect(calls).to eq(1)
    end

    # ...but a per-action `on_exception do … end` callback is guarded separately (Handlers::Invoker), so
    # one of those raising is still surfaced rather than lost with it.
    it "still reports a per-action on_exception callback that raises" do
      Axn.config.on_ignored_exception = reporter

      build_axn do
        on_exception { raise "boom in the action's own on_exception callback" }
        def call = raise("real body failure")
      end.call

      whiles = reports.map { |r| r[:context][:axn_ignored][:while] }
      expect(whiles).to include("executing on_exception callback")
    end

    # The recursion the guard genuinely exists to stop: a handler that runs an Axn action of its own (to
    # enrich or route the report) arrives back at the seam from underneath itself, with the outer
    # handler still on the stack. Unguarded this has no bound.
    it "does not re-enter a handler that runs an axn whose own guard trips" do
      calls = 0
      inner = build_axn { on_success { raise "boom inside the reporter's own axn" } }
      Axn.config.on_ignored_exception = lambda { |*|
        calls += 1
        inner.call
      }

      succeeds_with_broken_callback.call

      expect(calls).to eq(1)
    end

    it "does not let a raising handler change the action's outcome" do
      Axn.config.on_ignored_exception = ->(*) { raise "reporter is down" }

      expect(succeeds_with_broken_callback.call).to be_ok
    end

    it "still emits the warning log when the handler raises" do
      Axn.config.on_ignored_exception = ->(*) { raise "reporter is down" }
      expect(Axn.config.logger).to receive(:warn).with(/IGNORING EXCEPTION/i).at_least(:once)

      succeeds_with_broken_callback.call
    end

    it "arity-filters the handler like on_exception does" do
      seen = []
      Axn.config.on_ignored_exception = ->(e) { seen << e }

      succeeds_with_broken_callback.call
      expect(seen.first.message).to eq("boom in on_success")
    end
  end

  describe "interaction with best_effort_raises_in_dev" do
    # Dev-loud RAISES rather than ignoring, so there is nothing ignored to report.
    it "does not report when the guard re-raises instead" do
      Axn.config.on_ignored_exception = reporter
      allow(Axn.config).to receive(:best_effort_raises_in_dev).and_return(true)
      allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))

      expect { Axn::Extensions.best_effort("doing something") { raise "boom" } }.to raise_error(/boom/)
      expect(reports).to be_empty
    end
  end
end
