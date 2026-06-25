# frozen_string_literal: true

# Regression guard for axn's fiber-safety contract.
#
# All of axn's per-execution shared state (nesting stack, exception-classification sets, async retry
# context) lives in ActiveSupport::IsolatedExecutionState, which is scoped by `isolation_level`. These
# tests pin the two halves of the contract:
#   * under :fiber, that state isolates across concurrent fibers on one thread (the safe config), and
#   * under :thread (the default), it is SHARED across fibers — the silent-corruption mode that the
#     mismatch warning (see fiber_isolation_warning_spec) exists to surface.
#
# We interleave raw Fibers manually (no async-gem dependency): resume fiber A so it suspends mid-call
# with state set, then run fiber B and observe whether it sees A's state.
RSpec.describe "Fiber isolation contract" do
  def with_isolation_level(level)
    previous = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = level
    yield
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous
  end

  # Generic primitive check: covers ALL four axn keys at once, since they share this one mechanism.
  describe "ActiveSupport::IsolatedExecutionState (the mechanism every axn key rides)" do
    # Fiber A sets a key and suspends; B reads it. Returns what B observed.
    def value_b_sees_after_a_sets(value)
      fiber_a = Fiber.new do
        ActiveSupport::IsolatedExecutionState[:_axn_isolation_probe] = value
        Fiber.yield
      end
      fiber_a.resume # set the key, then suspend

      observed = nil
      Fiber.new do
        observed = ActiveSupport::IsolatedExecutionState[:_axn_isolation_probe]
      end.resume

      fiber_a.resume # let A finish cleanly
      observed
    end

    it "is isolated per fiber when the host sets isolation_level = :fiber (axn's guarantee)" do
      with_isolation_level(:fiber) do
        expect(value_b_sees_after_a_sets("from-a")).to be_nil
      end
    end

    it "is shared across fibers under the default :thread (characterizes why a fiber host must opt into :fiber)" do
      with_isolation_level(:thread) do
        expect(value_b_sees_after_a_sets("from-a")).to eq("from-a")
      end
    end
  end

  describe "axn's nesting stack" do
    # Fiber A opens a call tree and suspends with :a on the stack; B opens its own and reports the
    # stack it observes.
    def stack_b_observes
      fiber_a = Fiber.new do
        Axn::Core::NestingTracking.tracking(:a) { Fiber.yield }
      end
      fiber_a.resume # push :a, suspend

      observed = nil
      Fiber.new do
        Axn::Core::NestingTracking.tracking(:b) do
          observed = Axn::Core::NestingTracking._current_axn_stack.dup
        end
      end.resume

      fiber_a.resume # drain :a
      observed
    end

    it "stays isolated per fiber when the host sets isolation_level = :fiber (axn's guarantee)" do
      with_isolation_level(:fiber) do
        expect(stack_b_observes).to eq(%i[b])
      end
    end

    it "is shared across fibers under the default :thread (characterizes why a fiber host must opt into :fiber)" do
      with_isolation_level(:thread) do
        expect(stack_b_observes).to eq(%i[a b])
      end
    end
  end
end
