# frozen_string_literal: true

# Pins the execution guarantee published in docs/usage/writing.md ("What runs when"): which user
# hooks and callbacks run for each way a call can settle. The layering in Executor#run —
#
#   tracking → tracing → logging → timing → exception_handling → contract → hooks → @action.call
#
# — puts user hooks INSIDE the contract, so an outcome settled during inbound resolution never
# reaches them, while callbacks fire on every settlement.
#
# Each row asserts the ordered hook trace, not just which blocks ran: the `around` hook rescues (and
# re-raises) every exception, so a halt the hook OBSERVED traces `:around_rescued`, while a raise from
# outbound resolution — which happens after the hook body has returned — traces `:around_post`. That
# distinction is the documented reason a rescuing `around` cannot stand in for `on_exception`. The
# callbacks that follow are asserted as a set: which ones fire is the guarantee, their relative order
# is not.
RSpec.describe "Hook and callback execution guarantee" do
  def run_traced(declare: nil, body: nil, before_raises: false, after_raises: false, **inputs)
    trace = []
    action = build_axn do
      class_eval(&declare) if declare

      before do
        trace << :before
        raise "before hook raised" if before_raises
      end

      after do
        trace << :after
        raise "after hook raised" if after_raises
      end

      around do |chain|
        trace << :around_entry
        chain.call
        trace << :around_post
      rescue Exception # rubocop:disable Lint/RescueException -- recording every halt, including done!/fail!
        trace << :around_rescued
        raise
      ensure
        trace << :around_ensure
      end

      on_success { trace << :on_success }
      on_failure { trace << :on_failure }
      on_exception { trace << :on_exception }
      on_error { trace << :on_error }

      define_method(:call) do
        trace << :call
        instance_exec(&body) if body
      end
    end

    [action.call(**inputs), trace]
  end

  in_call_halt = %i[around_entry before call around_rescued around_ensure].freeze
  ran_to_completion = %i[around_entry before call after around_post around_ensure].freeze

  rows = {
    "an inbound validation failure" => {
      args: { declare: proc { expects :n, type: Integer }, n: "not an integer" },
      outcome: :exception, exception: Axn::InboundValidationError,
      hooks: []
    },
    "an inbound preprocess: that raises" => {
      args: { declare: proc { expects :n, preprocess: ->(_v) { raise "preprocess raised" } }, n: 1 },
      outcome: :exception, exception: Axn::ContractViolation::PreprocessingError,
      hooks: []
    },
    "an inbound default: that raises" => {
      args: { declare: proc { expects :n, default: -> { raise "default raised" } } },
      outcome: :exception, exception: Axn::ContractViolation::DefaultAssignmentError,
      hooks: []
    },
    "a call that succeeds" => {
      args: {},
      outcome: :success,
      hooks: ran_to_completion,
    },
    "done! in call" => {
      args: { body: proc { done!("finished early") } },
      outcome: :success,
      hooks: in_call_halt,
    },
    "fail! in call" => {
      args: { body: proc { fail!("nope") } },
      outcome: :failure, exception: Axn::Failure,
      hooks: in_call_halt
    },
    "a call that raises" => {
      args: { body: proc { raise ArgumentError, "call raised" } },
      outcome: :exception, exception: ArgumentError,
      hooks: in_call_halt
    },
    "a before hook that raises" => {
      args: { before_raises: true },
      outcome: :exception, exception: RuntimeError,
      hooks: %i[around_entry before around_rescued around_ensure]
    },
    "an after hook that raises" => {
      args: { after_raises: true },
      outcome: :exception, exception: RuntimeError,
      hooks: %i[around_entry before call after around_rescued around_ensure]
    },
    # Outbound resolution runs after the hook body has returned: every hook runs to completion and
    # the `around` never sees the raise.
    "an outbound validation failure" => {
      args: { declare: proc { exposes :out, type: Integer } },
      outcome: :exception, exception: Axn::OutboundValidationError,
      hooks: ran_to_completion
    },
    "an outbound (exposes) default: that raises" => {
      args: { declare: proc { exposes :out, default: -> { raise "default raised" } } },
      outcome: :exception, exception: Axn::ContractViolation::DefaultAssignmentError,
      hooks: ran_to_completion
    },
  }.freeze

  callbacks = {
    success: %i[on_success],
    failure: %i[on_failure on_error],
    exception: %i[on_exception on_error],
  }.freeze

  rows.each do |origin, row|
    context "when the call settles via #{origin}" do
      subject(:traced) { run_traced(**row[:args]) }

      let(:result) { traced.first }
      let(:trace) { traced.last }

      it "settles as #{row[:outcome]}" do
        expect(result.outcome.to_s).to eq(row[:outcome].to_s)
        expect(result.exception).to be_a(row[:exception]) if row[:exception]
      end

      it "runs exactly the expected hooks, in order" do
        expect(trace.take(row[:hooks].length)).to eq(row[:hooks])
      end

      it "then fires exactly the callbacks matching the outcome" do
        expect(trace.drop(row[:hooks].length)).to match_array(callbacks.fetch(row[:outcome]))
      end
    end
  end

  # Framework observability sits OUTSIDE the contract, so a call that never reaches the hooks is still
  # traced, timed and logged.
  describe "framework observability on a call settled before the hooks" do
    let(:action) { build_axn { expects :n, type: Integer } }

    it "still emits the axn.call notification with an elapsed time" do
      payloads = []
      subscriber = ActiveSupport::Notifications.subscribe("axn.call") { |*, payload| payloads << payload }
      action.call(n: "not an integer")
      expect(payloads.length).to eq(1)
      expect(payloads.first[:action].result.outcome).to be_exception
      expect(payloads.first[:action].result.elapsed_time).to be_a(Float)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "still logs the completed execution" do
      logger = instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil, fatal: nil,
                                       debug?: true, info?: true, warn?: true, error?: true, fatal?: true)
      messages = []
      allow(logger).to receive(:info) { |message| messages << message }
      allow(Axn.config).to receive(:logger).and_return(logger)

      action.call(n: "not an integer")

      expect(messages).to include(a_string_including("Execution completed", "exception"))
    end
  end
end
