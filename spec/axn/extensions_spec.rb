# frozen_string_literal: true

require "timeout"

RSpec.describe Axn::Extensions do
  describe ".best_effort" do
    let(:boom) { -> { raise StandardError, "fail message" } }
    let(:logger) { double(:logger) }

    before do
      allow(Axn).to receive_message_chain(:config, :logger).and_return(logger)
      allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(false)
      allow(logger).to receive(:warn)
      # backtrace shape for the "from" extraction
      allow_any_instance_of(StandardError).to receive(:backtrace).and_return(["/foo/bar/baz.rb:42:in `block'"])
    end

    it "returns the block's value on success" do
      allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
      expect(described_class.best_effort("foo") { 7 }).to eq(7)
    end

    context "in production" do
      before { allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true) }

      it "logs a concise warning and returns nil" do
        expect(logger).to receive(:warn).with(/Ignoring exception raised while foo/)
        expect(described_class.best_effort("foo", &boom)).to be_nil
      end
    end

    context "in non-production" do
      before { allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false) }

      it "logs a verbose warning and returns nil" do
        expect(logger).to receive(:warn).with(/IGNORING EXCEPTION RAISED WHILE FOO/)
        expect(described_class.best_effort("foo", &boom)).to be_nil
      end
    end

    context "with a custom action warn-target" do
      let(:action) { double(:action) }

      it "warns on the action instead of the config logger" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        expect(action).to receive(:warn).with(/Ignoring exception raised while foo/)
        described_class.best_effort("foo", action:, &boom)
      end
    end

    context "with best_effort_raises_in_dev enabled" do
      before { allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(true) }

      it "re-raises in development" do
        allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(true)
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        expect(logger).not_to receive(:warn)
        expect { described_class.best_effort("foo", &boom) }.to raise_error(StandardError, "fail message")
      end

      it "logs (does not raise) in test" do
        allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(false)
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        expect(logger).to receive(:warn)
        expect { described_class.best_effort("foo", &boom) }.not_to raise_error
      end

      it "re-raises a swallowable non-StandardError in development too" do
        allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(true)
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        expect { described_class.best_effort("foo") { raise SystemStackError } }.to raise_error(SystemStackError)
      end
    end

    # A side channel (a log line, a span update, an error report) must never be what takes down the
    # call it is describing, and SystemStackError — raised by a self-referential value reaching a
    # recursive formatter — is not a StandardError, so nothing else catches it. The same allowlist
    # decides what Core::Executor may settle onto a result, so this is the one answer to "what will
    # axn ever swallow".
    describe "the non-StandardError allowlist" do
      before do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        allow_any_instance_of(Exception).to receive(:backtrace).and_return(["/foo/bar/baz.rb:42:in `block'"])
      end

      it "swallows every class on the allowlist by default" do
        described_class::SWALLOWABLE_BEYOND_STANDARD_ERROR.each do |klass|
          expect(logger).to receive(:warn).with(/Ignoring exception raised while foo/)
          expect(described_class.best_effort("foo") { raise klass }).to be_nil
        end
      end

      # An allowlist, never a denylist: the non-StandardError set in a live process is OPEN (gems and
      # stdlib add their own direct Exception subclasses) and several exist precisely so nothing can
      # swallow them. Eating Timeout::ExitException makes an enclosing Timeout.timeout silently not
      # fire; eating Interrupt/SystemExit strands a process mid-shutdown; and a gem is free to invent
      # its own such signal tomorrow, which must pass through without axn knowing anything about it.
      it "propagates every non-StandardError that is not on the allowlist" do
        # Inheriting Exception directly is the point: that is what a library's own control-flow signal
        # looks like, and axn must pass one through without recognizing it.
        gem_signal = Class.new(Exception) # rubocop:disable Lint/InheritException

        [Interrupt, SystemExit, NoMemoryError, Timeout::ExitException, gem_signal].each do |klass|
          expect { described_class.best_effort("foo") { raise klass } }.to raise_error(klass)
        end
      end

      it "swallows the whole ScriptError family, which are faults in the code being run" do
        [NotImplementedError, LoadError, SyntaxError].each do |klass|
          allow(logger).to receive(:warn)
          expect(described_class.best_effort("foo") { raise klass }).to be_nil
        end
      end

      it "keeps an enclosing Timeout.timeout working" do
        expect do
          Timeout.timeout(0.02) { described_class.best_effort("foo") { sleep 0.2 } }
        end.to raise_error(Timeout::Error)
      end
    end

    # This guard often runs from inside an `ensure`, where raising would replace the exception already
    # in flight — so the warn path itself must not be able to raise. `raise` repopulates a nil
    # backtrace, but an exception reconstructed with `set_backtrace([])` (what a death handler
    # rebuilding one from job data hands us) keeps it empty.
    describe "an exception carrying no usable backtrace" do
      before do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        allow_any_instance_of(StandardError).to receive(:backtrace).and_return([])
      end

      it "still warns and swallows rather than raising out of the warn path" do
        expect(logger).to receive(:warn).with(/Ignoring exception raised while foo.*unknown location/)
        expect(described_class.best_effort("foo", &boom)).to be_nil
      end
    end

    # For a block whose return value or side effect feeds the call's real behavior, swallowing a
    # SystemStackError would report a runaway user finder/filter/matcher as a benign-looking absence
    # instead of the stack that names the recursion.
    describe "standard_errors_only: true" do
      before { allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true) }

      it "still swallows StandardError" do
        expect(logger).to receive(:warn).with(/Ignoring exception raised while foo/)
        expect(described_class.best_effort("foo", standard_errors_only: true, &boom)).to be_nil
      end

      it "returns the block's value on success" do
        expect(described_class.best_effort("foo", standard_errors_only: true) { 7 }).to eq(7)
      end

      it "propagates everything outside StandardError, allowlist included" do
        [SystemStackError, Interrupt, Timeout::ExitException].each do |klass|
          expect { described_class.best_effort("foo", standard_errors_only: true) { raise klass } }.to raise_error(klass)
        end
      end
    end
  end
end
