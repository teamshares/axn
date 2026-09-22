# frozen_string_literal: true

# Pins the execution guarantee published in docs/usage/writing.md ("What runs when"). Two independent
# axes decide what runs:
#
# - WHERE a halt originates decides which user hooks run. The layering in Executor#run —
#
#     tracking → tracing → logging → timing → exception_handling → contract → hooks → @action.call
#
#   — puts hooks INSIDE the contract, so a halt during inbound resolution never reaches them, and a
#   halt during outbound resolution happens after the hook body has returned.
# - WHAT KIND of halt it is (a raise, `fail!`, `done!`, or an exception axn does not capture) decides
#   the outcome and which callbacks fire — identically from every origin.
#
# The grid is the full cross product, so a new origin or halt kind cannot hold for one axis and
# silently not the other. Each case asserts the ordered hook trace, not just which blocks ran: the
# `around` hook rescues (and re-raises) everything, so a halt the hook OBSERVED traces
# `:around_rescued`, while a halt from outbound resolution traces `:around_post`. That distinction is
# the documented reason a rescuing `around` cannot stand in for `on_exception`. Callbacks are asserted
# as a set: which ones fire is the guarantee, their relative order is not.
RSpec.describe "Hook and callback execution guarantee" do
  def run_traced(declare: nil, body: nil, before_body: nil, after_body: nil, **inputs)
    trace = []
    action = build_axn do
      class_eval(&declare) if declare

      before do
        trace << :before
        instance_exec(&before_body) if before_body
      end

      after do
        trace << :after
        instance_exec(&after_body) if after_body
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

    begin
      [action.call(**inputs), trace]
    rescue Interrupt => e
      [e, trace]
    end
  end

  observed_halt = ->(*reached) { %i[around_entry before] + reached + %i[around_rescued around_ensure] }
  ran_to_completion = %i[around_entry before call after around_post around_ensure].freeze

  # Each origin injects the halt (a proc run against the action instance) at one point in the pipeline.
  origins = {
    "an inbound preprocess:" => {
      hooks: [],
      args: ->(halt) { { declare: proc { expects :n, preprocess: ->(_v) { instance_exec(&halt) } }, n: 1 } },
    },
    "an inbound default:" => {
      hooks: [],
      args: ->(halt) { { declare: proc { expects :n, default: -> { instance_exec(&halt) } } } },
    },
    "a before hook" => {
      hooks: observed_halt.call,
      args: ->(halt) { { before_body: halt } },
    },
    "call" => {
      hooks: observed_halt.call(:call),
      args: ->(halt) { { body: halt } },
    },
    "an after hook" => {
      hooks: observed_halt.call(:call, :after),
      args: ->(halt) { { after_body: halt } },
    },
    # Outbound resolution runs after the hook body has returned: every hook runs to completion and the
    # `around` never sees the halt.
    "an outbound (exposes) default:" => {
      hooks: ran_to_completion,
      args: ->(halt) { { declare: proc { exposes :out, default: -> { instance_exec(&halt) } } } },
    },
  }

  halts = {
    "raises" => { halt: proc { raise ArgumentError, "raised" }, outcome: :exception },
    "calls fail!" => { halt: proc { fail!("failed") }, outcome: :failure },
    "calls done!" => { halt: proc { done!("finished early") }, outcome: :success },
    # Outside what axn captures (docs/usage/using.md): never settled, so no outcome and no callbacks.
    "raises Interrupt" => { halt: proc { raise Interrupt }, outcome: nil },
  }

  callbacks = {
    success: %i[on_success],
    failure: %i[on_failure on_error],
    exception: %i[on_exception on_error],
    nil => [],
  }.freeze

  shared_examples "the execution guarantee" do |hooks:, outcome:|
    let(:result) { traced.first }
    let(:trace) { traced.last }

    if outcome
      it "settles as #{outcome}" do
        expect(result.outcome.to_s).to eq(outcome.to_s)
      end
    else
      it "is never settled: .call re-raises" do
        expect(result).to be_a(Interrupt)
      end
    end

    it "runs exactly the expected hooks, in order" do
      expect(trace.take(hooks.length)).to eq(hooks)
    end

    it "then fires exactly the callbacks matching the outcome" do
      expect(trace.drop(hooks.length)).to match_array(callbacks.fetch(outcome))
    end
  end

  origins.each do |origin, where|
    halts.each do |halt_name, halt|
      context "when #{origin} #{halt_name}" do
        subject(:traced) { run_traced(**where[:args].call(halt[:halt])) }

        it_behaves_like "the execution guarantee", hooks: where[:hooks], outcome: halt[:outcome]
      end
    end
  end

  context "when the call completes without a halt" do
    subject(:traced) { run_traced }

    it_behaves_like "the execution guarantee", hooks: ran_to_completion, outcome: :success
  end

  context "when inbound validation fails" do
    subject(:traced) { run_traced(declare: proc { expects :n, type: Integer }, n: "not an integer") }

    it_behaves_like "the execution guarantee", hooks: [], outcome: :exception
  end

  context "when outbound validation fails" do
    subject(:traced) { run_traced(declare: proc { exposes :out, type: Integer }) }

    it_behaves_like "the execution guarantee", hooks: ran_to_completion, outcome: :exception
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
