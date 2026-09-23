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
#   the outcome and which callbacks fire — identically from every origin, with one coupling pinned
#   separately below: outbound validation runs after a `done!` from the hook chain but not after one
#   raised by contract resolution itself.
#
# The grid is the full cross product, so a new origin or halt kind cannot hold for one axis and
# silently not the other. Each case asserts the ordered hook trace, not just which blocks ran: the
# `around` hook rescues (and re-raises) everything, so a halt the hook OBSERVED traces
# `:around_rescued`, while a halt from outbound resolution traces `:around_post`. That distinction is
# the documented reason a rescuing `around` cannot stand in for `on_exception`. Callbacks are asserted
# as a set: which ones fire is the guarantee, their relative order is not.
RSpec.describe "Hook and callback execution guarantee" do
  def run_traced(declare: nil, body: nil, before_body: nil, after_body: nil, inner_around_pre: nil, inner_around_post: nil, **inputs)
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

      # Declared after the traced hook, so it runs INSIDE it: a halt here is observed by the traced one.
      if inner_around_pre || inner_around_post
        around do |chain|
          instance_exec(&inner_around_pre) if inner_around_pre
          chain.call
          instance_exec(&inner_around_post) if inner_around_post
        end
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
    # A validation's if:/unless: condition runs where its field is validated: inbound for expects...
    "an expects validation's if: condition" => {
      hooks: [],
      args: ->(halt) { { declare: proc { expects :n, type: Integer, if: -> { instance_exec(&halt) } }, n: 1 } },
    },
    "an expects validator's callable option" => {
      hooks: [],
      args: ->(halt) { { declare: proc { expects :n, inclusion: { in: ->(action) { action.instance_exec(&halt) } } }, n: 1 } },
    },
    "a before hook" => {
      hooks: observed_halt.call,
      args: ->(halt) { { before_body: halt } },
    },
    # An inner `around` halting before its `chain.call`: nothing inside it (before/call/after) runs.
    "an inner around hook, before its chain.call," => {
      hooks: %i[around_entry around_rescued around_ensure],
      args: ->(halt) { { inner_around_pre: halt } },
    },
    "call" => {
      hooks: observed_halt.call(:call),
      args: ->(halt) { { body: halt } },
    },
    "an after hook" => {
      hooks: observed_halt.call(:call, :after),
      args: ->(halt) { { after_body: halt } },
    },
    # An inner `around` halting after its `chain.call`: everything inside it has already run.
    "an inner around hook, after its chain.call," => {
      hooks: observed_halt.call(:call, :after),
      args: ->(halt) { { inner_around_post: halt } },
    },
    # Outbound resolution runs after the hook body has returned: every hook runs to completion and the
    # `around` never sees the halt.
    "an outbound (exposes) default:" => {
      hooks: ran_to_completion,
      args: ->(halt) { { declare: proc { exposes :out, default: -> { instance_exec(&halt) } } } },
    },
    # A field both expected and exposed, carrying no validation and never read by the body, first
    # resolves its default: during the outbound copy-forward.
    "an inbound default: first resolved by the outbound copy-forward" => {
      hooks: ran_to_completion,
      args: lambda { |halt|
        { declare: proc {
          expects :v, optional: true, default: -> { instance_exec(&halt) }
          exposes :v, optional: true
        } }
      },
    },
    # ...and outbound, after the hook chain, for exposes.
    "an exposes validator's callable option" => {
      hooks: ran_to_completion,
      args: lambda { |halt|
        { declare: proc { exposes :o, optional: true, inclusion: { in: ->(action) { action.instance_exec(&halt) } } }, body: proc {
          expose o: 1
        } }
      },
    },
    "an exposes validation's if: condition" => {
      hooks: ran_to_completion,
      args: ->(halt) { { declare: proc { exposes :o, type: Integer, optional: true, if: -> { instance_exec(&halt) } } } },
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

  # Outbound resolution runs after a `done!` from `call` or a hook, so an unset required exposure turns
  # it into an exception; a `done!` raised by contract resolution itself (a preprocess:/default: or a
  # validation's if:/unless: running outside the hook chain) settles immediately and skips outbound
  # validation (PRO-3490).
  describe "done! with a required exposure left unset" do
    {
      "an inbound preprocess:" => [:success, ->(done) { { declare: proc { expects :n, preprocess: ->(_v) { instance_exec(&done) } }, n: 1 } }],
      "an inbound default:" => [:success, ->(done) { { declare: proc { expects :n, default: -> { instance_exec(&done) } } } }],
      "a before hook" => [:exception, ->(done) { { before_body: done } }],
      "call" => [:exception, ->(done) { { body: done } }],
      "an after hook" => [:exception, ->(done) { { after_body: done } }],
      "an around hook, before its chain.call," => [:exception, ->(done) { { inner_around_pre: done } }],
      "an around hook, after its chain.call," => [:exception, ->(done) { { inner_around_post: done } }],
      "an outbound (exposes) default:" => [:success, ->(done) { { declare: proc { exposes :other, default: -> { instance_exec(&done) } } } }],
      "an exposes validation's if: condition" => [:success, lambda { |done|
        { declare: proc { exposes :other, type: Integer, optional: true, if: -> { instance_exec(&done) } } }
      }],
      "an inbound default: first resolved by the outbound copy-forward" => [:success, lambda { |done|
        { declare: proc {
          expects :v, optional: true, default: -> { instance_exec(&done) }
          exposes :v, optional: true
        } }
      }],
    }.each do |origin, (outcome, args)|
      context "when #{origin} calls done!" do
        subject(:result) do
          kwargs = args.call(proc { done!("finished early") })
          declare = kwargs[:declare]
          kwargs[:declare] = proc do
            instance_exec(&declare) if declare
            exposes :out, type: Integer
          end
          run_traced(**kwargs).first
        end

        it "settles as #{outcome}" do
          expect(result.outcome.to_s).to eq(outcome.to_s)
          expect(result.exception).to be_a(Axn::OutboundValidationError) if outcome == :exception
        end
      end
    end
  end

  # While the call is already settling a raise or fail!, outbound defaults are applied best-effort: a
  # done! from one is swallowed, and the original halt stands.
  describe "done! from an outbound default while settling a halt" do
    {
      "a raise" => [proc { raise ArgumentError, "raised" }, :exception, ArgumentError],
      "fail!" => [proc { fail!("failed") }, :failure, Axn::Failure],
    }.each do |halt_name, (halt, outcome, exception_class)|
      it "keeps #{halt_name} as the outcome" do
        action = build_axn do
          exposes :o, default: -> { done!("finished early") }
          define_method(:call) { instance_exec(&halt) }
        end

        result = action.call
        expect(result.outcome.to_s).to eq(outcome.to_s)
        expect(result.exception).to be_a(exception_class)
      end
    end
  end

  # A field carrying no validation is not resolved by inbound validation: its preprocess: runs on first
  # read, so a halt from it lands inside the hook chain and follows the `call` row.
  context "when an inbound preprocess: on an unvalidated field raises on first read in call" do
    subject(:traced) do
      run_traced(declare: proc { expects :n, optional: true, preprocess: ->(_v) { raise ArgumentError, "raised" } },
                 body: proc { n }, n: 1)
    end

    it_behaves_like "the execution guarantee", hooks: observed_halt.call(:call), outcome: :exception
  end

  # A ✓ in the before/after columns means the phase was entered: hooks within a phase run one after
  # another, so a halt ends the phase and later hooks in it never run.
  describe "a halt within a phase of several hooks" do
    def run_phases(halting)
      trace = []
      action = build_axn do
        %i[before_1 before_2].each do |name|
          before do
            trace << name
            raise "#{name} raised" if name == halting
          end
        end
        %i[after_1 after_2].each do |name|
          after do
            trace << name
            raise "#{name} raised" if name == halting
          end
        end
        define_method(:call) { trace << :call }
      end
      [action.call, trace]
    end

    it "skips the before hooks after a halting before hook, and everything after it" do
      result, trace = run_phases(:before_1)
      expect(result.outcome).to be_exception
      expect(trace).to eq(%i[before_1])
    end

    it "skips the after hooks after a halting after hook" do
      result, trace = run_phases(:after_1)
      expect(result.outcome).to be_exception
      expect(trace).to eq(%i[before_1 before_2 call after_1])
    end
  end

  # Only some of the callables axn runs can halt a call. The rest contain a raise, `fail!` or `done!`
  # themselves: a validator turns it into a validation failure, and an observer (message, tag,
  # callback) is swallowed without changing the outcome. An exception axn does not capture still
  # passes through all of them — for a message callable, when the message is read, since messages
  # resolve lazily.
  describe "which callables can halt a call" do
    halt_kinds = {
      "raises" => proc { raise ArgumentError, "raised" },
      "calls fail!" => proc { fail!("failed") },
      "calls done!" => proc { done!("finished early") },
    }

    # [builder, inputs, expected outcome, expected exception class]
    containing_sites = {
      "an expects validate: callable" => [
        ->(h) { build_axn { expects :n, validate: ->(_v) { instance_exec(&h) } } }, { n: 1 },
        :exception, Axn::InboundValidationError
      ],
      "an exposes validate: callable" => [
        lambda { |h|
          build_axn do
            exposes :o, validate: ->(_v) { instance_exec(&h) }
            define_method(:call) { expose o: 1 }
          end
        }, {},
        :exception, Axn::OutboundValidationError
      ],
      "a success message callable" => [->(h) { build_axn { success -> { instance_exec(&h) } } }, {}, :success, NilClass],
      "a tag callable" => [->(h) { build_axn { tag :t, -> { instance_exec(&h) } } }, {}, :success, NilClass],
      "an on_success callback" => [->(h) { build_axn { on_success { instance_exec(&h) } } }, {}, :success, NilClass],
      "an error message callable" => [
        lambda { |h|
          build_axn do
            error -> { instance_exec(&h) }
            define_method(:call) { fail!("original") }
          end
        }, {},
        :failure, Axn::Failure
      ],
      "an on_error callback" => [
        lambda { |h|
          build_axn do
            on_error { instance_exec(&h) }
            define_method(:call) { raise NameError, "original" }
          end
        }, {},
        :exception, NameError
      ],
    }

    containing_sites.each do |site, (build, inputs, outcome, exception_class)|
      halt_kinds.each do |halt_name, halt|
        it "contains it when #{site} #{halt_name}: the call settles as #{outcome}" do
          result = instance_exec(halt, &build).call(**inputs)
          # Messages resolve lazily; read them so a message callable actually runs.
          result.success
          result.error
          expect(result.outcome.to_s).to eq(outcome.to_s)
          expect(result.exception.class).to eq(exception_class)
        end
      end

      it "still passes through an Interrupt raised by #{site}" do
        expect do
          result = instance_exec(proc { raise Interrupt }, &build).call(**inputs)
          result.success
          result.error
        end.to raise_error(Interrupt)
      end
    end

    # A model: finder runs on the model class, not the action, so fail!/done! do not exist there: a
    # fault it raises resolves the field to nil, which the field's validation
    # then classifies.
    describe "a model: finder" do
      def build_with_finder(&finder_body)
        model = Class.new { define_singleton_method(:find_it, &finder_body) }
        build_axn { expects :thing, model: { klass: model, finder: :find_it } }
      end

      it "contains a raise: the field resolves to nil and fails validation" do
        result = build_with_finder { |_id| raise ArgumentError, "finder raised" }.call(thing_id: 1)
        expect(result.exception).to be_a(Axn::InboundValidationError)
      end

      it "still passes through an Interrupt" do
        expect { build_with_finder { |_id| raise Interrupt }.call(thing_id: 1) }.to raise_error(Interrupt)
      end

      [SystemStackError, NotImplementedError].each do |uncontained|
        it "does not contain a #{uncontained}: the call settles as that exception" do
          result = build_with_finder { |_id| raise uncontained, "finder raised" }.call(thing_id: 1)
          expect(result.outcome).to be_exception
          expect(result.exception).to be_a(uncontained)
        end
      end
    end
  end

  describe "settlement-time callables" do
    it "falls back to the field's own message when a user_facing: override raises" do
      result = build_axn { expects :n, type: Integer, user_facing: -> { raise ArgumentError, "broken override" } }.call(n: "bad")
      expect(result.outcome).to be_failure
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end

    it "reads a raising fails_on gate as not matching" do
      result = build_axn do
        fails_on ArgumentError, if: -> { raise NameError, "broken gate" }
        define_method(:call) { raise ArgumentError, "original" }
      end.call
      expect(result.outcome).to be_exception
      expect(result.exception).to be_a(ArgumentError)
    end
  end

  # An `around` that returns without calling `chain.call` is not a halt: nothing inside it runs, and
  # the call then completes normally — including outbound validation.
  describe "an around hook that never calls chain.call" do
    def run_skipping(declare: nil)
      trace = []
      action = build_axn do
        class_eval(&declare) if declare
        around { |_chain| trace << :around }
        before { trace << :before }
        after { trace << :after }
        on_success { trace << :on_success }
        on_exception { trace << :on_exception }
        define_method(:call) { trace << :call }
      end
      [action.call, trace]
    end

    it "skips before, call and after, and settles as success" do
      result, trace = run_skipping
      expect(result).to be_ok
      expect(trace).to eq(%i[around on_success])
    end

    it "still runs outbound validation" do
      result, trace = run_skipping(declare: proc { exposes :o, type: Integer })
      expect(result.exception).to be_a(Axn::OutboundValidationError)
      expect(trace).to eq(%i[around on_exception])
    end
  end

  # A halt an enclosing `around` rescues without re-raising never reaches settlement: the chain returns
  # normally and the call settles by outbound resolution, as if nothing had halted.
  describe "an around hook that swallows a halt" do
    def run_swallowing(halt, declare: nil)
      action = build_axn do
        class_eval(&declare) if declare
        around do |chain|
          chain.call
        rescue StandardError
          nil
        end
        define_method(:call) { instance_exec(&halt) }
      end
      action.call
    end

    {
      "raise" => proc { raise ArgumentError, "raised" },
      "fail!" => proc { fail!("failed") },
      "done!" => proc { done!("finished early") },
    }.each do |halt_name, halt|
      it "settles a swallowed #{halt_name} as success" do
        expect(run_swallowing(halt)).to be_ok
      end

      it "still runs outbound validation after a swallowed #{halt_name}" do
        result = run_swallowing(halt, declare: proc { exposes :o, type: Integer })
        expect(result.exception).to be_a(Axn::OutboundValidationError)
      end
    end

    it "keeps the message of a done! swallowed by an enclosing around" do
      expect(run_swallowing(proc { done!("finished early") }).success).to eq("finished early")
    end

    it "loses the message of a done! raised by an inner around and swallowed by an outer one" do
      action = build_axn do
        around do |chain|
          chain.call
        rescue StandardError
          nil
        end
        around do |chain|
          done!("finished early")
          chain.call
        end
      end
      expect(action.call.success).to eq("Action completed successfully")
    end

    it "loses the message of a done! rescued in the same method that called it" do
      action = build_axn do
        define_method(:call) do
          done!("finished early")
        rescue StandardError
          nil
        end
      end
      expect(action.call.success).to eq("Action completed successfully")
    end
  end

  # call! runs the same hooks and fires the same callbacks; it only raises afterwards.
  describe "call!" do
    def run_bang(declare: nil, body: nil, **inputs)
      trace = []
      action = build_axn do
        class_eval(&declare) if declare
        around do |chain|
          trace << :around_entry
          chain.call
        end
        on_success { trace << :on_success }
        on_failure { trace << :on_failure }
        on_exception { trace << :on_exception }
        on_error { trace << :on_error }
        define_method(:call) { instance_exec(&body) if body }
      end
      [action.call!(**inputs), trace]
    rescue StandardError => e
      [e, trace]
    end

    it "fires the failure callbacks, then raises the failure" do
      raised, trace = run_bang(body: proc { fail!("failed") })
      expect(raised).to be_a(Axn::Failure)
      expect(trace).to contain_exactly(:around_entry, :on_failure, :on_error)
    end

    it "fires the exception callbacks on an inbound validation failure, then raises it" do
      raised, trace = run_bang(declare: proc { expects :n, type: Integer }, n: "not an integer")
      expect(raised).to be_a(Axn::InboundValidationError)
      expect(trace).to contain_exactly(:on_exception, :on_error)
    end

    it "fires on_success on done! and returns the result" do
      result, trace = run_bang(body: proc { done!("finished early") })
      expect(result).to be_ok
      expect(trace).to contain_exactly(:around_entry, :on_success)
    end
  end

  # A lazily resolved field's halt belongs to its first reader: read first by a contained callable (an
  # input tag here), it is swallowed with that callable's own raise and the call carries on.
  describe "an unvalidated field first read by a tag callable" do
    {
      "raises" => proc { raise ArgumentError, "raised" },
      "calls fail!" => proc { fail!("failed") },
      "calls done!" => proc { done!("finished early") },
    }.each do |halt_name, halt|
      it "swallows it when its preprocess: #{halt_name}, and the call carries on" do
        trace = []
        action = build_axn do
          expects :n, optional: true, preprocess: ->(_v) { instance_exec(&halt) }
          tag :t, -> { n }
          before { trace << :before }
          define_method(:call) { trace << :call }
        end

        expect(action.call(n: 1)).to be_ok
        expect(trace).to eq(%i[before call])
      end
    end
  end

  # The documented limit on "callbacks observe every settled call": in an async retry, the default
  # `:first_and_exhausted` reporting mode gates `on_exception` per attempt, while `on_error` still fires.
  context "when a call raises on an intermediate async retry" do
    subject(:traced) do
      retry_context = Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 2, max_retries: 5)
      Axn::Async::CurrentRetryContext.with(retry_context) { run_traced(body: proc { raise ArgumentError, "raised" }) }
    end

    it "settles as an exception but fires only on_error" do
      result, trace = traced
      expect(result.outcome).to be_exception
      hooks = observed_halt.call(:call)
      expect(trace).to eq(hooks + %i[on_error])
    end
  end

  # An exception axn does not capture, raised by a callback after the call has settled, still escapes
  # `.call`, and the callbacks after it never fire.
  it "lets an Interrupt from a settlement callback escape .call, skipping the later callbacks" do
    fired = []
    action = build_axn do
      on_error do
        fired << :on_error
        raise Interrupt
      end
      on_failure { fired << :on_failure }
      define_method(:call) { fail!("failed") }
    end

    expect { action.call }.to raise_error(Interrupt)
    expect(fired).to eq(%i[on_error])
  end

  # A `throw` is not an exception, so nothing axn wraps can contain it: it unwinds through `.call`
  # like an exception axn does not capture, before or after settlement.
  describe "a throw to a catch outside the call" do
    it "from call: the call never settles and no callback fires" do
      fired = []
      action = build_axn do
        on_success { fired << :on_success }
        on_exception { fired << :on_exception }
        define_method(:call) { throw :outside }
      end

      expect(catch(:outside) { action.call }).to be_nil
      expect(fired).to be_empty
    end

    it "from a callback: it escapes .call and the later callbacks never fire" do
      fired = []
      action = build_axn do
        on_error do
          fired << :on_error
          throw :outside
        end
        on_failure { fired << :on_failure }
        define_method(:call) { fail!("failed") }
      end

      expect(catch(:outside) { action.call }).to be_nil
      expect(fired).to eq(%i[on_error])
    end
  end

  # A limit on callback coverage: in development with best_effort_raises_in_dev, a raising callback is re-raised
  # rather than swallowed. Where it lands depends on the phase: a settlement callback escapes `.call`,
  # while an inline on_success raises inside the call and re-settles it as an exception.
  context "when a callback raises in development with best_effort_raises_in_dev" do
    before do
      allow(Axn.config).to receive(:best_effort_raises_in_dev).and_return(true)
      allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    end

    it "re-raises out of .call, and the later callbacks never fire" do
      fired = []
      action = build_axn do
        on_error do
          fired << :on_error
          raise ArgumentError, "broken on_error"
        end
        on_failure { fired << :on_failure }
        define_method(:call) { fail!("failed") }
      end

      expect { action.call }.to raise_error(ArgumentError, "broken on_error")
      expect(fired).to eq(%i[on_error])
    end

    it "settles a raising validate: callable as that exception, not a validation failure" do
      result = build_axn { expects :n, validate: ->(_v) { raise ArgumentError, "broken validator" } }.call(n: 1)
      expect(result.exception).to be_a(ArgumentError)
    end

    it "settles a raising model: finder as that exception, not a nil field" do
      model = Class.new { define_singleton_method(:find_it) { |_id| raise ArgumentError, "broken finder" } }
      result = build_axn { expects :thing, model: { klass: model, finder: :find_it } }.call(thing_id: 1)
      expect(result.exception).to be_a(ArgumentError)
    end

    it "keeps a raising sensitive: predicate contained" do
      expect(build_axn { expects :n, sensitive: -> { raise ArgumentError, "broken predicate" } }.call(n: 1)).to be_ok
    end

    it "settles a raising user_facing: override as that exception" do
      result = build_axn { expects :n, type: Integer, user_facing: -> { raise ArgumentError, "broken override" } }.call(n: "bad")
      expect(result.exception).to be_a(ArgumentError)
    end

    it "re-raises a raising fails_on gate out of .call before any callback fires" do
      fired = []
      action = build_axn do
        fails_on ArgumentError, if: -> { raise NameError, "broken gate" }
        on_error { fired << :on_error }
        on_exception { fired << :on_exception }
        define_method(:call) { raise ArgumentError, "original" }
      end
      expect { action.call }.to raise_error(NameError, "broken gate")
      expect(fired).to be_empty
    end

    it "re-raises a raising tag callable out of .call" do
      action = build_axn { tag :t, -> { raise ArgumentError, "broken tag" } }
      expect { action.call }.to raise_error(ArgumentError, "broken tag")
    end

    it "re-raises a raising error message out of .call before any callback fires" do
      fired = []
      action = build_axn do
        error -> { raise ArgumentError, "broken message" }
        on_error { fired << :on_error }
        on_failure { fired << :on_failure }
        define_method(:call) { fail!("failed") }
      end

      expect { action.call }.to raise_error(ArgumentError, "broken message")
      expect(fired).to be_empty
    end

    it "raises a raising success message where it is read, not out of .call" do
      result = build_axn { success -> { raise ArgumentError, "broken message" } }.call
      expect(result).to be_ok
      expect { result.success }.to raise_error(ArgumentError, "broken message")
    end

    it "re-settles the call as an exception when an inline on_success raises" do
      fired = []
      action = build_axn do
        on_success do
          fired << :on_success
          raise ArgumentError, "broken on_success"
        end
        on_error { fired << :on_error }
        on_exception { fired << :on_exception }
      end

      result = action.call
      expect(result.exception).to be_a(ArgumentError)
      expect(fired).to contain_exactly(:on_success, :on_error, :on_exception)
    end

    it "re-settles the call as a failure when an inline on_success calls fail!" do
      fired = []
      action = build_axn do
        on_success do
          fired << :on_success
          fail!("failed")
        end
        on_error { fired << :on_error }
        on_failure { fired << :on_failure }
      end

      expect(action.call.outcome).to be_failure
      expect(fired).to contain_exactly(:on_success, :on_error, :on_failure)
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
