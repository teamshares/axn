# frozen_string_literal: true

require "pathname"

# axn's fiber-safety rests on a single invariant: per-execution shared state lives ONLY in
# ActiveSupport::IsolatedExecutionState (which inherits the host's isolation_level), and never in
# storage that is hardcoded to the thread or shared at the class level. The patterns banned below are
# precisely the ones that isolation_level CANNOT save you from — they would leak across fibers (and,
# for class variables, across everything) no matter how the host is configured.
#
# If you genuinely need ambient per-execution state, use ActiveSupport::IsolatedExecutionState[...].
# See docs/advanced/concurrency.md.
RSpec.describe "no unscoped per-execution state in lib/" do
  let(:lib_root) { Pathname.new(File.expand_path("../../lib", __dir__)) }

  let(:forbidden_patterns) do
    {
      "Thread.current[...] thread-local (use ActiveSupport::IsolatedExecutionState)" => /Thread\.current\s*\[/,
      "Thread#thread_variable_get/set (use ActiveSupport::IsolatedExecutionState)" => /\.thread_variable_(get|set)\b/,
      "@@class_variable (shared across all instances/subclasses; not concurrency-safe)" => /(?<![A-Za-z0-9_])@@[a-z_]/,
    }
  end

  it "uses no thread-locals or class variables for state" do
    offenders = []

    Dir.glob(lib_root.join("**", "*.rb")).each do |path|
      rel = Pathname.new(path).relative_path_from(lib_root)
      File.foreach(path).with_index(1) do |line, lineno|
        forbidden_patterns.each do |label, pattern|
          offenders << "#{rel}:#{lineno}  [#{label}]  #{line.strip}" if line.match?(pattern)
        end
      end
    end

    expect(offenders).to be_empty, <<~MSG
      Found per-execution state stored outside ActiveSupport::IsolatedExecutionState.
      These patterns leak across fibers regardless of isolation_level. See docs/advanced/concurrency.md.

      #{offenders.join("\n")}
    MSG
  end
end
