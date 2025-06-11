# frozen_string_literal: true

RSpec.describe Action::Failure do
  let(:context) { Interactor::Context.new(error_from_user:) }
  let(:error_from_user) { nil }
  let(:message) { nil }

  it "defaults to the default message" do
    expect(described_class.new.message).to eq(described_class::DEFAULT_MESSAGE)
  end

  context "with a error_from_user on the context" do
    let(:error_from_user) { "custom message" }

    it "uses the error_from_user" do
      expect(described_class.new(context:).message).to eq(error_from_user)
    end

    context "with a message" do
      let(:message) { "custom message" }

      it "uses the message" do
        expect(described_class.new(message, context:).message).to eq(message)
      end
    end
  end
end
