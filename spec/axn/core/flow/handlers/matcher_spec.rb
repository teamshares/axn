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
end
