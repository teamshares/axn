# frozen_string_literal: true

# A declaration's label is visible only to the fiber that entered it, whatever the isolation level, and no label
# outlives its declaration on any fiber. Under `isolation_level = :thread` every fiber of a thread shares one
# `IsolatedExecutionState`, so two block-form declarations that yield on separate fibers (no scheduler — resumed
# by hand) would otherwise read, and restore, each other's label.
RSpec.describe Axn::Core::Contract::DeclarationLabel do
  def with_isolation_level(level)
    previous = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = level
    yield
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous
  end

  # A block-form declaration that pauses inside its block, then (if `refuse`) declares a member option that is
  # refused, so the refusal is composed after the other fiber has entered a declaration of its own.
  def paused_declaration(name, refuse:)
    label = described_class
    Fiber.new do
      Class.new { include Axn }.expects(name, type: Hash) do
        Fiber.yield label.current
        refuse ? field(:x, type: Integer, default: 1) : field(:x, type: Integer)
      end
      label.current
    rescue ArgumentError => e
      e.message
    end
  end

  %i[thread fiber].each do |level|
    context "under isolation_level = :#{level}" do
      around { |example| with_isolation_level(level) { example.run } }

      it "names the refusing fiber's own declaration when two declarations interleave" do
        a = paused_declaration(:a, refuse: true)
        b = paused_declaration(:b, refuse: false)

        expect(a.resume).to eq("expects :a")
        expect(b.resume).to eq("expects :b")

        expect(a.resume).to eq("`default:` isn't allowed on shape member `x` in expects :a — drop it; a shape member " \
                               "declares validation and schema only.")
        expect(b.resume).to be_nil
        expect(described_class.current).to be_nil
      end

      it "leaves no label behind on any fiber when the entries end out of order" do
        a = paused_declaration(:a, refuse: false)
        b = paused_declaration(:b, refuse: true)
        a.resume
        b.resume

        expect(a.resume).to be_nil
        expect(b.resume).to start_with("`default:` isn't allowed on shape member `x` in expects :b — ")
        expect(described_class.current).to be_nil
        expect(Fiber.new { described_class.current }.resume).to be_nil
        expect(ActiveSupport::IsolatedExecutionState[:__axn_declaration_label]).to be_nil
      end
    end
  end
end
