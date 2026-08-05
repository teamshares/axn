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
