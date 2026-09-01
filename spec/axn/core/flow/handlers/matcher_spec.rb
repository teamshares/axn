# frozen_string_literal: true

RSpec.describe Axn::Core::Flow::Handlers::SingleRuleMatcher do
  describe ".applicable?" do
    # A declaration-time guard (fails_on's if:/unless:) asks this rather than re-listing accepted
    # rule forms, so the two cannot drift. This spec pins the relationship both ways: every form
    # `.applicable?` admits is one `SingleRuleMatcher` actually applies (never falls through to
    # `handle_invalid`), and the one deliberate asymmetry is documented rather than silently passing.
    let(:action) do
      Class.new do
        def some_method = true
      end.new
    end

    describe "admitted forms actually apply (never reach handle_invalid)" do
      let(:exception) { ArgumentError.new("boom") }

      {
        "a Proc" => -> { true },
        "a Symbol naming an action method" => :some_method,
        "a String naming a constant" => "ArgumentError",
        "an Exception class" => ArgumentError,
      }.each do |label, rule|
        it "applies #{label}" do
          expect(described_class.applicable?(rule)).to be(true)

          # No log means it never reached handle_invalid (which always warns).
          expect(Axn::Internal::ActionState).not_to receive(:log)
          described_class.new(rule).call(exception:, action:)
        end
      end
    end

    describe "rejected forms" do
      call_only = Object.new
      def call_only.call = true

      {
        "a plain Integer" => 42,
        "a Regexp" => /re/,
        "a boolean (true)" => true,
        "a boolean (false)" => false,
        "a #call-only object (no to_proc/arity)" => call_only,
      }.each do |label, rule|
        it "does not admit #{label}" do
          expect(described_class.applicable?(rule)).to be(false)
        end
      end
    end

    # The one deliberate asymmetry: #matches?'s own `callable?` is a bare `respond_to?(:call)`, wider
    # than Invoker's `to_proc`+`arity` requirement. A #call-only object therefore reaches
    # `apply_callable`, which calls `Invoker.call` -- Invoker itself falls through to `literal_value`
    # (neither Symbol nor Invoker-callable), returning the object itself, which is truthy: an
    # unconditional match, silently. `.applicable?` refuses this shape so a DECLARATION can't produce
    # it, but the underlying #matches? behavior for `error`/`success` (which don't pre-validate) is
    # unchanged -- pinned here so a future edit doesn't accidentally "fix" it without noticing the
    # rest of the DSL depends on the old behavior.
    it "documents the #call-only asymmetry: #matches? treats it as an unconditional match" do
      call_only = Object.new
      def call_only.call = true

      expect(described_class.applicable?(call_only)).to be(false)
      expect(described_class.new(call_only).call(exception: ArgumentError.new, action:)).to be(true)
    end
  end

  # Codex review finding (PR #261): a rule that raises is swallowed and coerced to a definite
  # `false` by `apply_callable`/`apply_symbol` (`!!Invoker.call(...)`) BEFORE `#call` gets a chance
  # to invert it -- so `invert: true` (`unless:`) turned "the rule blew up" into "the exclusion
  # doesn't apply, so it's a match", the opposite of "a broken condition is inert." Fixed by having
  # `Invoker.call`'s `on_swallow:` report a distinct sentinel through `apply_callable`/`apply_symbol`,
  # so `#call` can tell "swallowed" apart from "genuinely returned falsy" and skip the invert.
  describe "invert: true (unless:) with a raising rule" do
    let(:action) do
      Class.new do
        def broken_predicate? = raise("boom")
      end.new
    end
    let(:exception) { ArgumentError.new("boom") }

    it "a raising Proc stays false (no match), not inverted to true" do
      matcher = described_class.new(-> { raise "boom" }, invert: true)
      expect(matcher.call(exception:, action:)).to be(false)
    end

    it "a raising Symbol (action method) stays false (no match), not inverted to true" do
      matcher = described_class.new(:broken_predicate?, invert: true)
      expect(matcher.call(exception:, action:)).to be(false)
    end

    it "a genuinely false rule still inverts to true (control: the fix doesn't touch honest results)" do
      matcher = described_class.new(-> { false }, invert: true)
      expect(matcher.call(exception:, action:)).to be(true)
    end

    it "a genuinely true rule still inverts to false (control)" do
      matcher = described_class.new(-> { true }, invert: true)
      expect(matcher.call(exception:, action:)).to be(false)
    end

    it "invert: false (if:) is unaffected either way -- a raising rule was already false, not inverted" do
      matcher = described_class.new(-> { raise "boom" })
      expect(matcher.call(exception:, action:)).to be(false)
    end
  end

  # Codex review finding (PR #261), round 6: a rule that never RUNS at all -- an unresolved Symbol
  # (names neither an action method nor a real constant), or any shape `handle_invalid` catches --
  # was ALSO coerced to a bare `false` (via the NameError-rescue branch, or handle_invalid's own
  # literal `false`) rather than the SWALLOWED sentinel, so it suffered the exact same invert bug as
  # a raising rule: `unless:` turned "never ran" into "match."
  describe "invert: true (unless:) with a rule that never runs" do
    let(:action) do
      Class.new do
        def some_method = true
      end.new
    end
    let(:exception) { ArgumentError.new("boom") }

    it "an unresolved Symbol (no such method, no such constant) stays false, not inverted to true" do
      matcher = described_class.new(:this_symbol_names_nothing_at_all_zzz, invert: true)
      expect(matcher.call(exception:, action:)).to be(false)
    end

    it "an unrecognized rule shape (handle_invalid) stays false, not inverted to true" do
      matcher = described_class.new(Object.new, invert: true)
      expect(matcher.call(exception:, action:)).to be(false)
    end
  end
end
