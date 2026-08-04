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

  describe ".owned_failure?" do
    it "is true for an Axn::Failure" do
      expect(described_class.owned_failure?(Axn::Failure.new("nope"))).to be(true)
    end

    it "is true for a user-facing validation error" do
      action = build_axn { expects :name, user_facing: true }
      result = action.call

      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(described_class.owned_failure?(result.exception)).to be(true)
    end

    # The nearer boundary, and the one the executor's stamping branch actually turns on: this IS an
    # Axn::ValidationError travelling axn's failure path, so only the `user_facing?` half separates it
    # from the owned case above. Its message names the field for a developer, not for a client.
    it "is false for a validation error that is not user-facing" do
      action = build_axn { expects :name }
      result = action.call

      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(described_class.owned_failure?(result.exception)).to be(false)
    end

    it "is false for a foreign exception" do
      expect(described_class.owned_failure?(ArgumentError.new("boom"))).to be(false)
    end
  end

  describe ".best_effort" do
    let(:boom) { -> { raise StandardError, "fail message" } }
    let(:logger) { double(:logger) }

    before do
      allow(Axn).to receive_message_chain(:config, :logger).and_return(logger)
      allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(false)
      allow(logger).to receive(:warn)
      # No `backtrace` stub: the guard reads through a BOUND `Exception#backtrace`, which ignores an
      # `allow_any_instance_of` entirely — and worse, a stub that answers non-nil makes CRuby skip recording a
      # real backtrace at all, so the "from" it was meant to supply degrades to "unknown location". `raise`
      # inside these blocks records a real frame, which is the shape the extraction is for. An example that
      # needs a specific backtrace sets it on the exception itself (see below).
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
      before { allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true) }

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
      before { allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true) }

      # Genuinely empty, not stubbed: `set_backtrace([])` on the object BEFORE it is raised is what survives to
      # the bound reader, since `raise` only repopulates a backtrace that is still nil. A stubbed `backtrace`
      # would prove nothing here — the bound reader never consults it, and the stub answering non-nil at raise
      # time leaves the real backtrace unrecorded, so the example would pass on the nil path instead.
      it "still warns and swallows rather than raising out of the warn path" do
        empty_backtrace = -> { raise(StandardError.new("fail message").tap { |e| e.set_backtrace([]) }) }

        expect(logger).to receive(:warn).with(/Ignoring exception raised while foo.*unknown location/)
        expect(described_class.best_effort("foo", &empty_backtrace)).to be_nil
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
      raising_backtrace = Class.new(StandardError) do
        def backtrace = raise(NotImplementedError, "backtrace explodes")
      end
      # An override is the only route to Location frames on either Ruby the gem supports: `set_backtrace`
      # refuses them on 3.3 (TypeError) and accepts them on 3.4, where `backtrace` hands them back as
      # Strings. So this row pins the BOUND `Exception#backtrace` reader — the thing that keeps an override
      # from being consulted at all — rather than the frame type test that backs it up.
      location_backtrace = Class.new(StandardError) do
        def backtrace = caller_locations(0, 1)
      end
      non_string_message = Class.new(StandardError) do
        def message = Object.new.tap { |o| o.define_singleton_method(:to_s) { raise "to_s explodes" } }
      end
      # The one dispatch no rescue inside the guard can cover: `raise` calls the 0-arg `#exception` on whatever
      # object it is handed, a bare `raise` re-raising `$!` included. Both forms defeat a faithful re-raise —
      # the first substitutes a different object for the block's exception, the second replaces it with
      # something else entirely — so the dev-loud path avoids the dispatch instead (see `hijack_labels` below).
      hijacking_exception = Class.new(StandardError) do
        def exception(*) = RuntimeError.new("hijacked")
      end
      raising_exception = Class.new(StandardError) do
        def exception(*) = raise(NotImplementedError, "exception explodes")
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
        "a backtrace override that raises" => -> { raise raising_backtrace },
        "a backtrace override answering Thread::Backtrace::Location frames" => -> { raise location_backtrace },
        "a rebuilt backtrace holding a blank frame" => lambda {
          raise(ArgumentError.new("rebuilt").tap { |e| e.set_backtrace([""]) })
        },
        "a valid multibyte message" => -> { raise ArgumentError, "café" },
        "a Latin-1 message" => -> { raise ArgumentError, "caf\xE9".dup.force_encoding("ISO-8859-1") },
        "an #exception answering a different object" => -> { raise hijacking_exception },
        "an #exception that raises" => -> { raise raising_exception },
      }

      # The two shapes `raise` cannot hand back AS THEMSELVES, so the dev-loud outcome is axn's own error
      # carrying the original as `cause` rather than the original object. Kept as their own set rather than
      # branched on inline so the identity example below still covers every OTHER shape: an example that
      # accepted "either the same object or an axn error" would have quietly stopped asserting identity for all
      # eleven of them.
      hijacks = {
        "an #exception answering a different object" => hijacking_exception,
        "an #exception that raises" => raising_exception,
      }

      %i[production development test].each do |environment|
        context "in #{environment}" do
          before do
            allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(environment == :production)
          end

          shapes.each do |label, block|
            # Swallowing is only half the contract: a guard that absorbed one of these silently would lose
            # every diagnostic and still satisfy a nil return, so the warning is asserted to ARRIVE here.
            # What it SAYS is pinned separately below, for the shapes whose rendering is the question.
            it "swallows #{label}, and warns rather than losing the diagnostic" do
              expect(logger).to receive(:warn).once

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

        # `[what the block raised, what left the guard]`, both captured rather than reconstructed: the object
        # the block raised is caught from INSIDE the guarded block, so every assertion below can be identity
        # rather than class. A reporting failure of the same class as the block's exception would satisfy a
        # class comparison, and so would both sides coming back nil.
        def dev_loud_outcome(block)
          thrown = nil

          escaped = begin
            Axn::Extensions.best_effort("guarding") do
              block.call
            rescue Exception => e # rubocop:disable Lint/RescueException
              thrown = e
              raise
            end
            nil
          rescue Exception => e # rubocop:disable Lint/RescueException
            e
          end

          expect(Axn::Internal::Identity.nil_value?(thrown)).to be(false)
          expect(Axn::Internal::Identity.nil_value?(escaped)).to be(false)

          [thrown, escaped]
        end

        # What left the guard, with nothing in between: the harness above cannot be used for a hijacking shape,
        # because CAPTURING the block's exception means re-raising it and every `raise` re-runs the hijack — the
        # wrapper's own bare `raise` produced the substitute before `best_effort` was ever entered.
        def escaping_exception(block)
          Axn::Extensions.best_effort("guarding", &block)
          nil
        rescue Exception => e # rubocop:disable Lint/RescueException
          e
        end

        (shapes.keys - hijacks.keys).each do |label|
          it "re-raises #{label} itself, never a reporting failure" do
            thrown, escaped = dev_loud_outcome(shapes.fetch(label))

            expect(Axn::Internal::Identity.same?(escaped, thrown)).to be(true)
          end
        end

        # Dev-loud stays LOUD for the two shapes it cannot re-raise faithfully — degrading to log-and-swallow
        # would lose the raise a developer configured. Only the CLASS is given up: the original is reachable as
        # `cause`, which the guard sets EXPLICITLY rather than leaving to `$!`, since the rescues that build the
        # message have already cleared it. `cause` is asserted by class rather than by identity because the object
        # cannot be captured, and the class is one this file defines and raises nowhere else.
        hijacks.each do |label, klass|
          it "raises an axn-owned error carrying #{label} as its cause, not what the hijack produced" do
            escaped = escaping_exception(shapes.fetch(label))

            expect(escaped).to be_a(Axn::UnreraisableException)
            expect(escaped.cause).to be_a(klass)
            expect(escaped.message).to include("guarding", Axn::Internal::ClassName.of_module(klass))
          end
        end

        # A shape that is not a hijack but an ABSENCE: `raise <instance>` dispatches the 0-arg `#exception` on the
        # object, and this one removes itself while answering — so by the time the guard asks which module owns
        # `#exception`, nothing does. Asking for an owner of a method that does not exist raises `NameError`,
        # inside the guard whose entire promise is that it never emits a third exception.
        #
        # The INSTANCE form is what makes it reachable, and is why a first attempt at reproducing it looks like a
        # false positive: `raise <Class>, msg` calls the CLASS's `exception` and never invokes the instance's, so
        # the singleton is never touched and the guard behaves perfectly.
        #
        # `cause` is asserted by IDENTITY here, unlike the hijack cases above: the object is built before it is
        # raised and answers the dispatch with itself, so it can be held onto and compared.
        it "raises an axn-owned error carrying the original OBJECT when its #exception undefines itself" do
          original = Class.new(StandardError) do
            def exception(*)
              singleton_class.send(:undef_method, :exception)
              self
            end
          end.new("the original")

          escaped = escaping_exception(-> { raise original })

          expect(escaped).to be_a(Axn::UnreraisableException)
          expect(Axn::Internal::Identity.same?(escaped.cause, original)).to be(true)
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

      # A `desc` that IS a String is still foreign BYTES. Non-production is the case that bites: the wording
      # decorates with `'⌵' * 30`, which puts real non-ASCII UTF-8 on axn's own side of the join, so an
      # unrenderable desc raised `Encoding::CompatibilityError` there where the pure-ASCII production wording
      # concatenated fine. Escaped rather than dropped, so the line still names the intent.
      it "renders a String desc whose bytes have no UTF-8 rendering" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        expect(logger).to receive(:warn).with(/\\XFF/)

        expect(described_class.best_effort("guarding \xFF".dup.force_encoding("ASCII-8BIT")) do
          raise ArgumentError, "ordinary"
        end).to be_nil
      end

      # Every fact ABOUT the exception is now rendered rather than dispatched, so no exception the block can
      # raise reaches the backstop under the report path — verified by deleting that rescue and watching the
      # table above stay green. What still reaches it is the guard's own collaborators: `Axn.config.env`
      # decides the wording and is a configured seam, so a host application supplying a broken or half-booted
      # env object raises here, while reporting, from inside an `ensure`. That is the same failure as a
      # hostile `#message` — a warning nobody reads replacing the exception in flight — and it is what the
      # backstop exists for.
      describe "a reporting failure raised by the guard's own collaborators" do
        # A realistically broken `env` — a half-booted host application, a config whose backing object is
        # gone — cannot answer ANY predicate, so the double refuses both. Breaking one predicate at a time is
        # what let the `development?` read hide: `production?` is read while reporting, where the backstop
        # covers it, but `development?` is read one line earlier to decide whether dev-loud applies, where
        # nothing did.
        def break_env_with(exception)
          env = double(:env)
          allow(env).to receive(:production?).and_raise(exception)
          allow(env).to receive(:development?).and_raise(exception)
          allow(Axn).to receive_message_chain(:config, :env).and_return(env)
        end

        it "swallows a StandardError from the environment seam" do
          break_env_with(NoMethodError.new("env is half-booted"))

          expect(described_class.best_effort("guarding") { raise ArgumentError, "ordinary" }).to be_nil
        end

        it "swallows an allowlisted non-StandardError from the environment seam" do
          break_env_with(SystemStackError.new)

          expect(described_class.best_effort("guarding") { raise ArgumentError, "ordinary" }).to be_nil
        end

        # The backstop is narrow on the same terms as `best_effort` itself: a signal arriving mid-report is
        # still a signal, and axn absorbing one would break the control flow it belongs to.
        it "lets a signal through rather than absorbing it into a swallowed warning" do
          break_env_with(Interrupt.new)

          expect { described_class.best_effort("guarding") { raise ArgumentError, "ordinary" } }.to raise_error(Interrupt)
        end

        # Deciding whether dev-loud applies is itself two reads into caller-owned config, and it happens
        # BEFORE the reporting the backstop covers — so a seam that cannot answer must not make the guard
        # raise. Failing to decide is not an answer, and the safe answer is the one that keeps swallowing.
        it "swallows rather than raising when the dev-loud decision cannot read the environment" do
          allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(true)
          break_env_with(NoMethodError.new("env is half-booted"))

          expect(described_class.best_effort("guarding") { raise ArgumentError, "ordinary" }).to be_nil
        end

        # Same narrowness as the reporting path, for the same reason: a signal is not a broken config.
        #
        # Modelled as TRANSIENT — only the decision's read raises, and the reporting's read answers — which
        # is what a signal actually is: an event arriving at one moment, not a property of the env object.
        # A uniformly broken env would make this pass either way, since the second read would raise the
        # signal again where nothing absorbs it, and the decision's own narrowness would go unpinned.
        it "lets a signal through from the dev-loud decision too" do
          env = double(:env)
          allow(env).to receive(:development?).and_raise(Interrupt)
          allow(env).to receive(:production?).and_return(false)
          allow(Axn).to receive_message_chain(:config, :env).and_return(env)
          allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(true)

          expect { described_class.best_effort("guarding") { raise ArgumentError, "ordinary" } }.to raise_error(Interrupt)
        end

        it "swallows rather than raising when the dev-loud setting itself cannot be read" do
          allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev)
            .and_raise(NoMethodError, "config is half-booted")
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)

          expect(described_class.best_effort("guarding") { raise ArgumentError, "ordinary" }).to be_nil
        end
      end
    end
  end
end
