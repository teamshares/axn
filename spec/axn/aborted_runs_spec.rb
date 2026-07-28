# frozen_string_literal: true

require "timeout"

# An exception from outside StandardError is still a bug in the run, reachable from anywhere user code runs
# (the body, any hook, a preprocess:/coerce:/default:/validate: callable). Nothing rescued those, so the run
# used to settle as nothing at all: `outcome` read `success`, the completion line said so, the global report
# never fired, and it escaped `.call` — breaking the consistent-return guarantee that only `call!` opts
# out of (docs/usage/using.md).
RSpec.describe "a run aborted by a non-StandardError" do
  let(:reported) { [] }
  let(:log_lines) { [] }

  around do |example|
    Axn.config.on_exception = ->(exception, action:, context:) { reported << [exception, context] } # rubocop:disable Lint/UnusedBlockArgument
    example.run
  ensure
    Axn.config.on_exception = nil
  end

  # Records every callback the run fires, in order, so the documented superset contract
  # (on_error co-fires with whichever of on_failure/on_exception applies) is checked as a whole.
  def action_raising(exception_class, message = "aborted")
    events = []
    klass = build_axn do
      exposes :v
      on_error { |e| events << [:on_error, e.class] }
      on_failure { |e| events << [:on_failure, e.class] }
      on_exception { |e| events << [:on_exception, e.class] }
      on_success { events << :on_success }
      after { events << :after_hook }
    end
    klass.define_method(:call) do
      expose(v: 1)
      raise exception_class, message
    end
    allow(klass).to receive(:info) { |msg, **| log_lines << msg }
    allow(klass).to receive(:warn)
    [klass, events]
  end

  describe "an exception that indicates a fault in the action (SystemStackError, ScriptError, …)" do
    # The whole point of `.call`: a bug becomes a result, and only `call!` opts out of that.
    it "settles into an exception-outcome result that .call returns rather than raising" do
      klass, = action_raising(SystemStackError)

      result = klass.call

      expect(result).not_to be_ok
      expect(result.outcome).to eq("exception")
      expect(result.exception).to be_a(SystemStackError)
    end

    it "still raises through call!, as the original object" do
      klass, = action_raising(SystemStackError)

      expect { klass.call! }.to raise_error(SystemStackError)
    end

    it "reports it once, so a runaway recursion is no longer invisible to error tracking" do
      klass, = action_raising(SystemStackError)
      klass.call

      expect(reported.map(&:first).map(&:class)).to eq([SystemStackError])
    end

    it "fires on_error alongside on_exception (the documented superset), and neither on_failure nor the success path" do
      klass, events = action_raising(NotImplementedError)
      klass.call

      expect(events).to eq([[:on_error, NotImplementedError], [:on_exception, NotImplementedError]])
    end

    it "records an honest exception outcome rather than leaving the run reading as a success" do
      klass, = action_raising(SystemStackError)
      captured = nil
      klass.on_error { captured = result.outcome.to_s }
      klass.call

      expect(captured).to eq("exception")
    end

    it "logs the completion line at the exception outcome, not as a success" do
      klass, = action_raising(SystemStackError)
      klass.call

      expect(log_lines.last).to include("outcome: exception")
    end

    it "covers the whole ScriptError family, not just SystemStackError" do
      [NotImplementedError, LoadError, SyntaxError].each do |klass|
        action, = action_raising(klass)

        expect(action.call.exception).to be_a(klass)
      end
    end

    # Reachable from every place user code runs, not just the body.
    {
      "a before hook" => ->(k) { k.before { raise SystemStackError } },
      "an around hook" => ->(k) { k.around { |_hooked| raise SystemStackError } },
      "a preprocess: callable" => ->(k) { k.expects :thing, preprocess: ->(_v) { raise SystemStackError } },
      "an exposes default: callable" => ->(k) { k.exposes :other, default: -> { raise SystemStackError } },
    }.each do |label, declare|
      it "settles the same way when raised from #{label}" do
        klass = build_axn { exposes :v }
        klass.define_method(:call) { expose(v: 1) }
        declare.call(klass)
        allow(klass).to receive(:info)
        allow(klass).to receive(:warn)

        result = klass.call(thing: 1)

        expect(result.outcome).to eq("exception")
        expect(result.exception).to be_a(SystemStackError)
      end
    end

    # `fails_on` means "treat this as a failure", so it does exactly that for anything axn absorbs —
    # silently ignoring the declaration would be the worst outcome. Only classes axn never absorbs are
    # unreachable, and those are rejected at declaration instead (see fails_on_spec).
    context "when the action declares fails_on for it" do
      it "reclassifies to a failure outcome, firing on_failure and skipping the report" do
        klass, events = action_raising(SystemStackError)
        klass.fails_on SystemStackError

        result = klass.call

        expect(result.outcome).to eq("failure")
        expect(result.exception).to be_a(SystemStackError)
        expect(events.map(&:first)).to eq(%i[on_error on_failure])
        expect(reported).to be_empty
      end

      it "honors a broad `fails_on Exception` for the classes axn absorbs" do
        klass, = action_raising(SystemStackError)
        klass.fails_on Exception

        expect(klass.call.outcome).to eq("failure")
      end
    end

    # A callback is dispatched from the executor's rescue clause, so a raise there does not reach the
    # sibling `rescue Exception` and would escape `.call` while REPLACING the failure it was invoked to
    # observe.
    context "when a callback itself raises a non-StandardError" do
      it "keeps the action's own exception and still returns a result" do
        klass = build_axn { exposes :v }
        klass.on_error { raise SystemStackError }
        klass.define_method(:call) { raise "the real failure" }
        allow(klass).to receive(:info)
        allow(klass).to receive(:warn)

        result = klass.call

        expect(result.exception).to be_a(RuntimeError)
        expect(result.exception.message).to eq("the real failure")
        expect(reported.map(&:first).map(&:class)).to eq([RuntimeError])
      end

      it "still propagates one axn never absorbs" do
        klass = build_axn { exposes :v }
        klass.on_error { raise Interrupt }
        klass.define_method(:call) { raise "the real failure" }
        allow(klass).to receive(:info)
        allow(klass).to receive(:warn)

        expect { klass.call }.to raise_error(Interrupt)
      end
    end

    it "still applies outbound defaults, so the returned result reads like any other failed one" do
      klass = build_axn { exposes :v, default: -> { 9 } }
      klass.define_method(:call) { raise SystemStackError }
      allow(klass).to receive(:info)
      allow(klass).to receive(:warn)

      expect(klass.call.v).to eq(9)
    end

    # Settling must not itself break the guarantee it exists to uphold.
    it "does not escape .call when a default: callable blows the stack while settling" do
      klass = build_axn { exposes :v, default: -> { raise SystemStackError } }
      klass.define_method(:call) { raise "ordinary failure" }
      allow(klass).to receive(:info)
      allow(klass).to receive(:warn)

      expect(klass.call.outcome).to eq("exception")
    end

    context "when nested" do
      it "reports once, at the innermost action, with the call chain" do
        inner, = action_raising(SystemStackError)
        outer = build_axn { exposes :v }
        outer.define_method(:call) { inner.call! }
        allow(outer).to receive(:info)
        allow(outer).to receive(:warn)

        result = outer.call

        expect(result.outcome).to eq("exception")
        expect(reported.length).to eq(1)
        expect(reported.first.last[:axn_stack].length).to eq(2)
      end
    end
  end

  # Gated on an ALLOWLIST (Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR), so anything axn does not
  # positively recognize as a fault in the code passes through untouched — no recorded outcome, no
  # callbacks, no report, no log line. A denylist would instead absorb the open-ended tail of this set:
  # process signals, another library's private control flow, and classes that do not exist yet.
  describe "an exception that axn must not interfere with" do
    [Interrupt, SystemExit, Timeout::ExitException, NoMemoryError].each do |klass|
      context klass.name do
        it "escapes with no report and no callbacks" do
          action, events = action_raising(klass)

          expect { action.call }.to raise_error(klass)
          expect(reported).to be_empty
          expect(events).to be_empty
        end

        it "logs no completion line for a run that never settled" do
          action, = action_raising(klass)

          expect { action.call }.to raise_error(klass)
          expect(log_lines.grep(/Execution completed/)).to be_empty
        end
      end
    end

    it "covers Sidekiq's shutdown signal, which subclasses Interrupt" do
      shutdown = Class.new(Interrupt) # Sidekiq::Shutdown < Interrupt < SignalException
      action, events = action_raising(shutdown)

      expect { action.call }.to raise_error(shutdown)
      expect(reported).to be_empty
      expect(events).to be_empty
    end

    # The case a denylist cannot cover: axn has never heard of this class, and absorbing it into a
    # result would silently break whatever the library uses it to signal.
    it "covers a library's own private control-flow signal" do
      gem_signal = Class.new(Exception) # rubocop:disable Lint/InheritException
      action, events = action_raising(gem_signal)

      expect { action.call }.to raise_error(gem_signal)
      expect(reported).to be_empty
      expect(events).to be_empty
    end

    # Raised outside StandardError precisely so that nothing swallows it.
    it "covers ActiveSupport::ErrorReporter::UnexpectedError" do
      action, events = action_raising(ActiveSupport::ErrorReporter::UnexpectedError)

      expect { action.call }.to raise_error(ActiveSupport::ErrorReporter::UnexpectedError)
      expect(reported).to be_empty
      expect(events).to be_empty
    end

    # Timeout identifies its own ExitException by object identity, so axn must re-raise THAT object and
    # never a wrapper — otherwise the timeout silently does not fire.
    it "leaves an enclosing Timeout.timeout able to convert its own signal" do
      action = build_axn { exposes :v }
      action.define_method(:call) { sleep 0.2 }
      allow(action).to receive(:info)
      allow(action).to receive(:warn)

      expect { Timeout.timeout(0.02) { action.call } }.to raise_error(Timeout::Error)
      expect(reported).to be_empty
    end
  end

  it "drains the nesting stack either way" do
    klass, = action_raising(SystemStackError)
    klass.call

    expect(Axn::Core::NestingTracking._current_axn_stack).to be_empty
  end
end
