# frozen_string_literal: true

require "timeout"

# An exception from outside StandardError aborts a run. Nothing rescues those, so the run used to settle
# as nothing at all: `outcome` read `success`, the completion line said so, and the global report never
# fired — a user's own runaway recursion was invisible to error tracking even though the exception did
# escape to the caller.
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
    it "still escapes to the caller, unwrapped" do
      klass, = action_raising(SystemStackError)

      expect { klass.call }.to raise_error(SystemStackError)
    end

    it "reports it once, so a runaway recursion is no longer invisible to error tracking" do
      klass, = action_raising(SystemStackError)

      expect { klass.call }.to raise_error(SystemStackError)
      expect(reported.map(&:first).map(&:class)).to eq([SystemStackError])
    end

    it "fires on_error alongside on_exception (the documented superset), and neither on_failure nor the success path" do
      klass, events = action_raising(NotImplementedError)

      expect { klass.call }.to raise_error(NotImplementedError)
      expect(events).to eq([[:on_error, NotImplementedError], [:on_exception, NotImplementedError]])
    end

    it "records an honest exception outcome rather than leaving the run reading as a success" do
      klass, = action_raising(SystemStackError)
      captured = nil
      klass.on_error { captured = result.outcome.to_s }

      expect { klass.call }.to raise_error(SystemStackError)
      expect(captured).to eq("exception")
    end

    it "logs the completion line at the exception outcome, not as a success" do
      klass, = action_raising(SystemStackError)

      expect { klass.call }.to raise_error(SystemStackError)
      expect(log_lines.last).to include("outcome: exception")
    end

    # `fails_on` is deliberately not consulted: a matcher broad enough to catch a non-StandardError would
    # otherwise turn an abort into a returned failure result, swallowing it.
    context "when the action declares a fails_on matcher broad enough to catch it" do
      it "still re-raises instead of returning a failure result" do
        klass, = action_raising(SystemStackError)
        klass.fails_on Exception

        expect { klass.call }.to raise_error(SystemStackError)
      end

      it "labels the outcome `exception`, agreeing with the callbacks that fired" do
        klass, events = action_raising(SystemStackError)
        klass.fails_on Exception

        expect { klass.call }.to raise_error(SystemStackError)
        expect(log_lines.last).to include("outcome: exception")
        expect(events.map(&:first)).to eq(%i[on_error on_exception])
      end
    end

    context "when nested" do
      it "reports once, at the innermost action, with the call chain" do
        inner, = action_raising(SystemStackError)
        outer = build_axn { exposes :v }
        outer.define_method(:call) { inner.call! }
        allow(outer).to receive(:info)
        allow(outer).to receive(:warn)

        expect { outer.call }.to raise_error(SystemStackError)
        expect(reported.length).to eq(1)
        expect(reported.first.last[:axn_stack].length).to eq(2)
      end
    end
  end

  # Process lifecycle and another library's control flow say nothing about the action, so axn passes them
  # through untouched — no recorded outcome, no callbacks, no report, no log line.
  describe "an exception that axn must not interfere with" do
    [Interrupt, SystemExit, Timeout::ExitException].each do |klass|
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

    it "covers Sidekiq's shutdown signal by way of SignalException" do
      shutdown = Class.new(Interrupt) # Sidekiq::Shutdown < Interrupt < SignalException
      action, events = action_raising(shutdown)

      expect { action.call }.to raise_error(shutdown)
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

    expect { klass.call }.to raise_error(SystemStackError)
    expect(Axn::Core::NestingTracking._current_axn_stack).to be_empty
  end
end
