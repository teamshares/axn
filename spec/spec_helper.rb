# frozen_string_literal: true

ENV["RACK_ENV"] ||= "test"

require "axn"
require "axn/testing/spec_helpers"
require "pry-byebug"

$LOAD_PATH.unshift(File.expand_path(__dir__))

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    # Catch stubs/mocks on real objects (partial doubles) whose methods don't actually
    # exist — prevents dead stubs from silently passing when an API is renamed/removed.
    mocks.verify_partial_doubles = true
  end

  config.before(:suite) do
    Axn.configure do |c|
      # Hide default logging
      c.logger = Logger.new(File::NULL) unless ENV["DEBUG"]
    end
  end

  # `Axn::Testing.reset!` deliberately leaves registered tool adapters alone (they register at
  # file-load time and cannot be re-established mid-process), so axn's own suite — which does
  # register adapters, unlike a host app — resets them separately here.
  config.before do
    Axn::Testing.reset!
    Axn::Tools::Registry.reset_adapters!
  end

  # `Strategies.clear!` resets the registry to the built-ins in lib/axn/strategies/, dropping every strategy
  # registered at file-load time from somewhere else — the opt-in extras, `:client` among them. Those cannot
  # re-register themselves once their file has been required, so a spec that clears the registry takes them
  # away from every example that runs after it, and which examples those are is the ordering seed's decision.
  # Snapshotted once every file has loaded and put back after each example.
  registered_strategies = nil
  config.before(:suite) { registered_strategies = Axn::Strategies.all.dup }
  # Through the public reader every time, not `instance_variable_set(:@items, ...)`: `Registry.all` is
  # `@items ||= built_in.dup`, and a spec that calls `.clear!` (which reassigns `@items` to a fresh
  # Hash) between examples means the CURRENT object behind `.all` can change — so restoring has to read
  # it fresh each time rather than caching one reference, and `#replace` mutates that live Hash in
  # place rather than leaving any caller still holding a reference to a Hash `.all` returned earlier
  # pointing at a now-discarded object.
  config.after { Axn::Strategies.all.replace(registered_strategies) }

  # The nesting stack is process-wide state that `NestingTracking.tracking` pops in an `ensure`, so a
  # frame outliving its example means something escaped that wrapper — a suspended Fiber abandoned
  # mid-body is the way it happens. One stranded frame silently rewrites `axn_stack`, log prefixes and
  # carried presentation for every example that runs afterwards, and whether that matters depends
  # entirely on execution order: a leak is invisible in defined order and poisons ~30 examples under a
  # reversed or randomised one. Fail the example that caused it rather than the innocent examples
  # downstream, and drain the stack so one leak doesn't cascade into a wall of unrelated failures.
  config.after do
    stack = Axn::Core::NestingTracking._current_axn_stack
    next if stack.empty?

    depth = stack.size
    stack.clear
    raise "Leaked #{depth} axn nesting-stack frame(s). Something entered an action without unwinding it " \
          "(an abandoned suspended Fiber is the usual cause) — drain it before the example ends."
  end
end

# The inbound context facade an action's field readers resolve through. It is a private implementation
# detail on the action (nothing may dispatch its name, so a user is free to declare a field called
# `internal_context`), so a spec that wants to assert on the facade itself — its `inspect` redaction,
# its memo ivars — reaches it the same way axn's own machinery does.
def inbound_facade(action) = Axn::Internal::ActionState.internal_context(action)

def expect_best_effort_called(message_substring:, action: nil, times: 1)
  # The transitional swallow-based call sites always forward an `action:` kwarg to
  # `best_effort` — even `nil` — via its `action:` shorthand, so the trailing kwarg is
  # present on every call regardless of whether the original call site supplied one.
  # `any_args` tolerates that trailing arg when we don't care about it, while still
  # matching cleanly once migrated call sites stop forwarding it at all.
  args = [a_string_including(message_substring)]
  args << (action.nil? ? any_args : hash_including(action:))
  expect(Axn::Extensions).to have_received(:best_effort).with(*args).exactly(times).times
end
