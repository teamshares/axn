# frozen_string_literal: true

RSpec.describe "internal dispatch through shadowable instance names" do
  # Axn's user-facing sugar: names a user's `def` or field reader can take over on the action
  # instance. If internals ever dispatched one of these by name again, a shadow would silently
  # break the framework instead of merely costing the helper.
  let(:sugar) do
    %w[result internal_context inputs expose log debug info warn error fatal
       execution_context ambient_context default_error default_success]
  end

  # The executor must invoke the user's own method, so this one dispatch is the point rather
  # than a bypass of it.
  let(:allowed) { ["@action.call"] }

  let(:lib_files) { Dir[File.join(__dir__, "../../../lib/**/*.rb")] }

  it "walks a non-empty set of library files" do
    # A guard that silently scans zero files passes forever without checking anything — the
    # exact failure this spec exists to prevent.
    expect(lib_files).not_to be_empty
  end

  it "does not appear anywhere in lib/" do
    pattern = /(@?action)\.(#{sugar.join('|')})\b/
    offenders = lib_files.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")
        next unless line.match?(pattern)
        next if allowed.any? { |allowance| line.include?(allowance) }

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
