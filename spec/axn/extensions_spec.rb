# frozen_string_literal: true

require "timeout"

RSpec.describe Axn::Extensions do
  describe ".swallowable?" do
    it "answers from the class hierarchy, not from the instance" do
      # This predicate authorizes SWALLOWING, and only the allowlist actually being in the ancestry
      # can authorize that. Asking `exception.is_a?` made the answer depend on a method the exception
      # defines, so a direct Exception subclass claiming to be a StandardError was treated as
      # absorbable — and a cancellation absorbed is the worst outcome available in the tracing path.
      # Inheriting from Exception rather than StandardError is the whole point: the lie is the claim
      # to be swallowable, so the class must genuinely not be.
      liar = Class.new(Exception) do # rubocop:disable Lint/InheritException
        def is_a?(klass) = klass == StandardError ? true : super
        def kind_of?(klass) = is_a?(klass)
      end.new("cancellation in disguise")

      expect(described_class.swallowable?(liar)).to be(false)
    end

    it "still answers true for the allowlist and its subclasses" do
      expect(described_class.swallowable?(StandardError.new)).to be(true)
      expect(described_class.swallowable?(ArgumentError.new)).to be(true)
      expect(described_class.swallowable?(SystemStackError.new)).to be(true)
      expect(described_class.swallowable?(Class.new(ScriptError).new)).to be(true)
      expect(described_class.swallowable?(Interrupt.new)).to be(false)
    end
  end

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

    # This guard runs from inside an `ensure`, so the WARNING must not raise either — a logging backend
    # that can't write would otherwise replace the exception in flight, the exact failure the guard
    # exists to prevent, moved one line later.
    describe "when emitting the warning itself fails" do
      let(:broken) { double(:broken_logger) }

      before do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        allow(broken).to receive(:warn).and_raise(IOError, "closed stream")
      end

      it "swallows rather than escaping when the configured logger cannot write" do
        allow(Axn).to receive_message_chain(:config, :logger).and_return(broken)

        expect { described_class.best_effort("foo", &boom) }.not_to raise_error
      end

      it "gives the configured logger an independent attempt when an action's warn is the broken one" do
        action = double(:action)
        allow(action).to receive(:warn).and_raise(SystemStackError)
        expect(logger).to receive(:warn).with(/Ignoring exception raised while foo/)

        expect { described_class.best_effort("foo", action:, &boom) }.not_to raise_error
      end

      it "still swallows when both targets are broken" do
        action = double(:action)
        allow(action).to receive(:warn).and_raise(SystemStackError)
        allow(Axn).to receive_message_chain(:config, :logger).and_return(broken)

        expect { described_class.best_effort("foo", action:, &boom) }.not_to raise_error
      end
    end

    # Same reason: the warn path must not raise. `raise` repopulates a nil backtrace, but an exception
    # reconstructed with `set_backtrace([])` — what a death handler rebuilding one from job data hands
    # us — keeps it empty.
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

    describe "the guarantee that reporting cannot replace the block's exception" do
      # `best_effort` builds its warning FROM the exception it caught, inside the rescue, so every read of
      # that exception is a second chance for it to escape through the code meant to contain it. This is the
      # invariant as a property rather than as a list of inputs: whatever the block raises, the only thing
      # that can come out is that same object.
      hostile_message = Class.new(StandardError) do
        def message = raise(NotImplementedError, "message explodes")
      end
      hostile_class_name = Class.new(StandardError) do
        def self.name = raise(NotImplementedError, "name explodes")
      end
      hostile_backtrace = Class.new(StandardError) do
        def backtrace = "not an array"
      end
      non_string_message = Class.new(StandardError) do
        def message = Object.new.tap { |o| o.define_singleton_method(:to_s) { raise "to_s explodes" } }
      end

      # Every shape is built INSIDE its lambda. These lambdas are created in the example-group body, so
      # their `self` is the group CLASS rather than an example instance — a helper defined with `def` here
      # would be an instance method and unreachable from them.
      shapes = {
        "an ordinary exception" => -> { raise ArgumentError, "ordinary" },
        "a message that raises" => -> { raise hostile_message },
        "a message holding bytes with no UTF-8 rendering" => lambda {
          raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT")
        },
        "a message that is not a String and whose to_s raises" => -> { raise non_string_message },
        "a class whose name raises" => -> { raise hostile_class_name },
        "a backtrace override answering a non-Array" => -> { raise hostile_backtrace },
        "a rebuilt backtrace holding a blank frame" => lambda {
          raise(ArgumentError.new("rebuilt").tap { |e| e.set_backtrace([""]) })
        },
        "a valid multibyte message" => -> { raise ArgumentError, "café" },
        "a Latin-1 message" => -> { raise ArgumentError, "caf\xE9".dup.force_encoding("ISO-8859-1") },
      }

      %i[production development test].each do |environment|
        context "in #{environment}" do
          before do
            allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(environment == :production)
          end

          shapes.each do |label, block|
            it "swallows #{label} and returns nil" do
              expect(described_class.best_effort("guarding", &block)).to be_nil
            end
          end
        end
      end

      context "with best_effort_raises_in_dev enabled" do
        before do
          allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(true)
          allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(true)
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        end

        shapes.each do |label, block|
          it "re-raises #{label} itself, never a reporting failure" do
            raised = begin
              described_class.best_effort("guarding", &block)
              nil
            rescue Exception => e # rubocop:disable Lint/RescueException
              e
            end

            expected = begin
              block.call
              nil
            rescue Exception => e # rubocop:disable Lint/RescueException
              e
            end

            expect(Axn::Internal::Identity.class_of(raised)).to eq(Axn::Internal::Identity.class_of(expected))
          end
        end
      end

      it "keeps a valid multibyte message verbatim in the warning" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        expect(logger).to receive(:warn).with(/café/)

        described_class.best_effort("guarding") { raise ArgumentError, "café" }
      end

      it "renders a Latin-1 message as its text rather than as escapes" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        expect(logger).to receive(:warn).with(/café/)

        described_class.best_effort("guarding") { raise ArgumentError, "caf\xE9".dup.force_encoding("ISO-8859-1") }
      end

      it "escapes a message with no UTF-8 rendering rather than losing the line" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        expect(logger).to receive(:warn).with(/\\xFF/)

        described_class.best_effort("guarding") { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }
      end

      it "tolerates a desc that is not a String" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)

        expect(described_class.best_effort(Object.new) { raise ArgumentError, "ordinary" }).to be_nil
      end

      # Every fact ABOUT the exception is now rendered rather than dispatched, so no exception the block can
      # raise reaches the backstop under the report path — verified by deleting that rescue and watching the
      # table above stay green. What still reaches it is the guard's own collaborators: `Axn.config.env`
      # decides the wording and is a configured seam, so a host application supplying a broken or half-booted
      # env object raises here, while reporting, from inside an `ensure`. That is the same failure as a
      # hostile `#message` — a warning nobody reads replacing the exception in flight — and it is what the
      # backstop exists for.
      describe "a reporting failure raised by the guard's own collaborators" do
        it "swallows a StandardError from the environment seam" do
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_raise(NoMethodError, "env is half-booted")

          expect(described_class.best_effort("guarding") { raise ArgumentError, "ordinary" }).to be_nil
        end

        it "swallows an allowlisted non-StandardError from the environment seam" do
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_raise(SystemStackError)

          expect(described_class.best_effort("guarding") { raise ArgumentError, "ordinary" }).to be_nil
        end

        # The backstop is narrow on the same terms as `best_effort` itself: a signal arriving mid-report is
        # still a signal, and axn absorbing one would break the control flow it belongs to.
        it "lets a signal through rather than absorbing it into a swallowed warning" do
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_raise(Interrupt)

          expect { described_class.best_effort("guarding") { raise ArgumentError, "ordinary" } }.to raise_error(Interrupt)
        end
      end
    end
  end
end
