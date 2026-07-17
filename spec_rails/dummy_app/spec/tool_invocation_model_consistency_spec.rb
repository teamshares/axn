# frozen_string_literal: true

RSpec.describe "tool invocation: model-consistency mismatch surfaces user-facing" do
  let(:action) do
    build_axn do
      expects :user, model: true
      def call; end
    end
  end

  it "composes a record/id mismatch into a non-reported user-facing failure" do
    user = User.create!(name: "Test User")
    other_user = User.create!(name: "Other User")

    expect(Axn.config).not_to receive(:on_exception)
    result = Axn::Tools::Invoker.new(user_facing_input_errors: true).call(
      action, { user:, user_id: other_user.id }
    )

    expect(result).not_to be_ok
    expect(Axn::Tools::Invoker.input_invalid?(result)).to be(true)
    expect(result.error).to match(/conflicts with user_id/)
  end
end
