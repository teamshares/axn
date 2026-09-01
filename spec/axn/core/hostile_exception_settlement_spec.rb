# frozen_string_literal: true

# Settlement asks a raised exception several type questions — is it a Failure, does `fails_on` cover it, does
# it settle user-facing, which declared `error` handler matches — and every one of them decides something the
# exception has an interest in: whether its own bug is reported, and whether its technical message reaches a
# caller. All of them are answered from the class hierarchy (`Internal::Identity.kind?`), never asked of the
# instance, so an exception cannot pick its own classification and cannot replace the settlement it is being
# classified by.
#
# The escape being prevented is specific. `_settle_exception!` records the exception, resolves and stamps the
# presentation, and THEN dispatches on_error/on_failure/on_exception. A raise between the record and the
# dispatch loses every callback and the global report, and leaves `.call` raising where it promised a result.
RSpec.describe "settling an exception that answers type questions for itself" do
  # Outside StandardError AND outside SWALLOWABLE_BEYOND_STANDARD_ERROR (SystemStackError, ScriptError), so
  # if any of these questions were dispatched, the answer would escape `.call` rather than be absorbed by a
  # guard. A ScriptError here — NotImplementedError being the tempting choice — is inside the swallowed set
  # and would prove the opposite of what it looks like.
  unswallowable = Class.new(Exception) # rubocop:disable Lint/InheritException

  # Raises rather than lies, because a raise is the strictly stronger claim: it fails the test if the question
  # is dispatched at all, where a lie only fails if the wrong branch is then taken.
  let(:hostile_class) do
    Class.new(StandardError) do
      define_method(:is_a?) { |_klass| raise(unswallowable, "type questions must not be asked of the instance") }
      def kind_of?(klass) = is_a?(klass)
    end
  end

  describe "a `fails_on`-reclassified exception" do
    it "settles as a failure with its callbacks and message intact" do
      klass = hostile_class
      fired = []
      action = build_axn do
        fails_on klass
        error "Sync failed"
        on_failure { fired << :failure }
        on_error { fired << :error }
        on_exception { fired << :exception }
      end.tap { |a| a.define_method(:call) { raise klass, "underlying cause" } }

      result = nil
      expect { result = action.call }.not_to raise_error

      expect(result.ok?).to be(false)
      expect(result.outcome.failure?).to be(true)
      expect(fired).to contain_exactly(:error, :failure)

      # The headline alone, with the technical cause NOT attached: a `fails_on`-reclassified foreign
      # exception is not an owned failure, so its own message stays dev-facing. That is the same
      # `owned_failure?` verdict the presentation stamping turns on, read here through what a caller sees.
      expect(result.error).to eq("Sync failed")
      expect(result.error).not_to include("underlying cause")
    end
  end

  describe "an exception NOT covered by `fails_on`" do
    it "settles as an exception outcome and still reports" do
      klass = hostile_class
      fired = []
      action = build_axn do
        on_exception { fired << :exception }
        on_error { fired << :error }
        on_failure { fired << :failure }
      end.tap { |a| a.define_method(:call) { raise klass, "a genuine bug" } }

      result = nil
      expect { result = action.call }.not_to raise_error

      expect(result.ok?).to be(false)
      expect(result.outcome.exception?).to be(true)
      expect(fired).to contain_exactly(:error, :exception)
    end
  end

  # A `fails_on if:`/`unless:` gate runs USER code (unlike everything else in this file, which is
  # undispatched ancestry) -- so it is a genuinely different hazard: not "the exception lies about its
  # own type," but "the caller's own condition proc breaks." `Handlers::Invoker`'s error policy already
  # owns this (see error-paths.md): a swallowable raise warns and reads as no match; anything else
  # propagates, exactly like any other matcher.
  describe "a `fails_on` condition that raises" do
    it "a StandardError from the condition is swallowed, warned, and read as no match -- settlement completes and still reports" do
      fired = []
      action = build_axn do
        fails_on(ArgumentError, if: -> { raise "boom in condition" })
        on_exception { fired << :exception }
        on_error { fired << :error }
        on_failure { fired << :failure }
      end.tap { |a| a.define_method(:call) { raise ArgumentError, "the real exception" } }

      result = nil
      expect { result = action.call }.not_to raise_error

      expect(result.outcome.exception?).to be(true)
      expect(result.exception.message).to eq("the real exception")
      expect(fired).to contain_exactly(:error, :exception)
    end

    it "an exception outside StandardError/SystemStackError/ScriptError from the condition escapes .call" do
      unswallowable_from_condition = Class.new(Exception) # rubocop:disable Lint/InheritException
      action = build_axn do
        fails_on(ArgumentError, if: -> { raise unswallowable_from_condition, "boom in condition" })
      end.tap { |a| a.define_method(:call) { raise ArgumentError, "the real exception" } }

      expect { action.call }.to raise_error(unswallowable_from_condition, "boom in condition")
    end
  end

  # Codex review finding (PR #261), round 7: deferring `__finalize!` until classification is decided
  # (so a reentrant `result.outcome` read never freezes in a pre-classification answer -- see
  # fails_on_spec.rb) opened a window of its own: `Axn::ValidationError.user_facing?` -- one of the
  # OR terms deciding classification -- dispatches the exception's OWN `#user_facing?`, and a hostile
  # override raising there escapes `_settle_exception!` entirely, past the explicit `__finalize!`
  # call. `_settle_exception`'s outer rescue then warns-and-swallows a result that never finalized,
  # which (per this file's own premise) breaks completion logging/tracing/metrics gated on
  # `finalized?`. Fixed with an `ensure` in `_settle_exception!` that finalizes when the exception has
  # actually been recorded (see round 9 below for why "unconditionally" was the wrong shape).
  #
  # NOTE (found while verifying, deliberately NOT fixed here -- out of this ticket's scope): this
  # hostile class also makes `result.outcome` itself raise, on every read, forever -- because
  # `Axn::ValidationError.user_facing?` dispatches `exception.user_facing?`, which is NOT the
  # undispatched-ancestry pattern this whole file is about. That gap predates this PR: the OLD,
  # never-memoized `outcome` had the identical unguarded dispatch, so a hostile `user_facing?`
  # override would have raised on every read of `result.outcome` before any of this ticket's changes
  # existed. Reported rather than patched, per the hostile-object-audit doctrine (error-paths.md).
  describe "a hostile ValidationError subclass whose #user_facing? raises during classification" do
    it "still finalizes the result (completion logging/tracing/metrics are not left permanently stuck)" do
      hostile_validation_error = Class.new(Axn::ValidationError) do
        def initialize = super([], user_facing: false)
        def user_facing? = raise("boom in user_facing?")
      end

      action = build_axn { define_method(:call) { raise hostile_validation_error } }

      result = nil
      expect { result = action.call }.not_to raise_error

      expect(result.finalized?).to be(true)
      expect(result.ok?).to be(false)
    end
  end

  # Codex review finding (PR #261), round 9: the round-7 fix ("finalize unconditionally in an
  # `ensure`") was ITSELF wrong in the other direction. `apply_defaults!(:outbound)`'s own
  # `best_effort`, at the TOP of `_settle_exception!`, runs BEFORE `__record_exception` -- so a
  # pass-through signal (`Interrupt`, `Timeout::ExitException`) escaping THERE reaches the `ensure`
  # with the context completely untouched (`@exception` still nil, `@failure` still false from
  # `Context#initialize`). Finalizing unconditionally there marks that untouched context as a
  # FINISHED SUCCESS while the signal is still unwinding -- verified live: `finalized?` and `ok?`
  # both read `true` on a call that was aborted before it ever recorded anything. An outer `ensure`
  # (tracing, logging) reading the result during that same unwind would report a false success for
  # an abandoned call. Fixed by gating the `ensure`'s finalize on `@context.exception` being present
  # -- i.e. only finalizing once `__record_exception` has actually run.
  describe "a pass-through signal escaping before the exception is even recorded" do
    it "does NOT finalize the result as a false success" do
      action = build_axn { def call = raise ArgumentError, "the real bug" }
      result_ref = nil

      allow_any_instance_of(Axn::Core::Executor).to receive(:apply_defaults!) do |executor, direction|
        result_ref = Axn::Internal::ActionState.result(executor.instance_variable_get(:@action))
        raise Interrupt if direction == :outbound
      end

      expect { action.call }.to raise_error(Interrupt)

      expect(result_ref.finalized?).to be(false)
      expect(result_ref.exception).to be_nil
    end
  end

  # The declared-handler match is the same question in a different place: `SingleRuleMatcher` resolves an
  # exception-class rule against the exception, and which handler wins decides the message a caller reads.
  describe "matching a declared `error` handler by exception class" do
    it "picks the handler from the hierarchy rather than from the exception" do
      klass = hostile_class
      action = build_axn do
        error "Wrong handler", if: ArgumentError
        error "Right handler", if: klass
      end.tap { |a| a.define_method(:call) { raise klass, "boom" } }

      result = nil
      expect { result = action.call }.not_to raise_error

      expect(result.error).to eq("Right handler")
    end
  end

  # Stamping the resolved presentation runs through axn's OWN `__present_as`, bound rather than dispatched.
  # `owned_failure?` admits a subclass by ancestry, so a subclass that makes the method private or undefines it
  # is still admitted — and dispatching to it raised `NoMethodError` from inside `_settle_exception!`, after the
  # exception was recorded and before any callback ran, costing on_error AND on_failure.
  #
  # A bound call has no availability question to get wrong, so it is strictly stronger than the `respond_to?`
  # guard this replaced: that one kept the callbacks but silently skipped the stamping.
  describe "an Axn::Failure subclass that removes __present_as" do
    {
      "private" => Class.new(Axn::Failure) { private :__present_as },
      "undefined" => Class.new(Axn::Failure) { undef_method :__present_as },
    }.each do |label, failure_class|
      it "settles fully, with callbacks, when the subclass makes it #{label}" do
        fired = []
        action = build_axn do
          on_error { fired << :on_error }
          on_failure { fired << :on_failure }
          define_method(:call) { raise failure_class, "boom" }
        end

        result = nil
        expect { result = action.call }.not_to raise_error

        expect(result.outcome.failure?).to be(true)
        expect(fired).to eq(%i[on_error on_failure])
        expect(result.error).to eq("boom")
      end
    end
  end

  # `result.error`/`#inspect` re-ask these questions on every later read, outside any settlement guard — so a
  # result handed back to a caller has to stay readable, not merely settle once.
  describe "reading the settled result afterwards" do
    it "renders inspect and re-reads the message without raising" do
      klass = hostile_class
      action = build_axn { fails_on klass }.tap { |a| a.define_method(:call) { raise klass, "boom" } }

      result = action.call

      expect { result.inspect }.not_to raise_error
      expect { 3.times { result.error } }.not_to raise_error
    end
  end
end
