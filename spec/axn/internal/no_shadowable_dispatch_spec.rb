# frozen_string_literal: true

RSpec.describe "internal dispatch through shadowable instance names" do
  # Axn's user-facing sugar: names a user's `def` or field reader can take over on the action
  # instance. If internals ever dispatched one of these by name again, a shadow would silently
  # break the framework instead of merely costing the helper.
  #
  # `call` is deliberately absent. The executor MUST invoke the user's own method, so that dispatch
  # is the point rather than a bypass of it — and listing it would flag every `some_proc.call` on a
  # receiver whose name happens to contain "action".
  let(:sugar) do
    %w[result internal_context inputs_for_logging outputs_for_logging inputs expose
       log debug info warn error fatal
       set_execution_context clear_execution_context execution_context ambient_context
       default_error default_success fail! done! forward!]
  end

  # Any receiver whose name says it holds an action instance — `action`, `@action`,
  # `@action_instance`, `context_instance`. A receiver named `*_class` holds the action CLASS, where
  # a class-level shadow (`def self.log`) is a separate question this rule does not cover.
  let(:receiver) { /(?<receiver>@?\w*(?:action|instance)\w*)/ }

  # `send(:name)` / `respond_to?(:name)` reach the same method the same way, and a `respond_to?`
  # probe is worse than a plain dispatch: a shadow answers it as truthfully as the real method, so
  # the guard passes and the call lands on the user's value.
  let(:indirection) { /(?:(?:public_send|send|respond_to\?)\(\s*:)?/ }

  let(:lib_files) { Dir[File.join(__dir__, "../../../lib/**/*.rb")] }

  it "walks a non-empty set of library files" do
    # A guard that silently scans zero files passes forever without checking anything — the
    # exact failure this spec exists to prevent.
    expect(lib_files).not_to be_empty
  end

  it "does not appear anywhere in lib/" do
    # `\b` cannot terminate `fail!`/`done!`, so the boundary is spelled as a lookahead instead.
    pattern = /#{receiver}\.#{indirection}(?:#{sugar.join('|')})(?![\w!?])/
    offenders = lib_files.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")

        match = line.match(pattern)
        next unless match
        next if match[:receiver].end_with?("_class")

        "#{path.sub(%r{.*/lib/}, 'lib/')}:#{index + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, <<~MSG
      Internals must read action state through Axn::Internal::ActionState, which binds the
      implementation rather than dispatching a name a user can take. Offending lines:

      #{offenders.join("\n")}
    MSG
  end
end
