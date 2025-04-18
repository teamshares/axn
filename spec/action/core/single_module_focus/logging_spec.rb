# frozen_string_literal: true

require "action/core/logging"

RSpec.describe Action::Logging do
  let(:interactor) do
    build_interactor(described_class) do
      def call
        log("Hello, World!")
      end
    end
  end
  let(:logger) { instance_double(Logger, info: nil, error: nil, debug: nil) }

  subject { interactor.call }

  before do
    allow(Action.config).to receive(:logger).and_return(logger)
  end

  it "logs" do
    expect(logger).to receive(:info).with("[Anonymous Class] Hello, World!")
    is_expected.to be_success
  end
end
