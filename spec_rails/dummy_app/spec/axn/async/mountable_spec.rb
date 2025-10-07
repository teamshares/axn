# frozen_string_literal: true

RSpec.describe "Axn::Async with mountable" do
  let(:action) { Actions::EnqueueAll::Tester }

  before do
    allow(Axn.config.logger).to receive(:info).and_call_original
  end

  it "can run mountable axns via async" do
    Sidekiq::Testing.inline! do
      action.enqueue_all_async(max: 3)
    end

    expect(Axn.config.logger).to have_received(:info).with(
      "[Actions::EnqueueAll::Tester] Action executed: I was called with number: 1 | instance_helper | class_helper",
    )
    expect(Axn.config.logger).to have_received(:info).with(
      "[Actions::EnqueueAll::Tester] Action executed: I was called with number: 2 | instance_helper | class_helper",
    )
    expect(Axn.config.logger).to have_received(:info).with(
      "[Actions::EnqueueAll::Tester] Action executed: I was called with number: 3 | instance_helper | class_helper",
    )
  end

  it "can execute axn blocks that call async methods" do
    # Test that the axn block can execute and return job IDs
    result = action.enqueue_all(max: 2)

    expect(result).to be_ok
    expect(result.value).to be_an(Array)
    expect(result.value.length).to eq(2)
    expect(result.value.all? { |id| id.is_a?(String) }).to be true
  end

  it "can access instance and class helpers from the axn block" do
    allow(Actions::EnqueueAll::Tester).to receive(:call_async)
    action.enqueue_all(max: 3)

    expect(Actions::EnqueueAll::Tester).to have_received(:call_async).exactly(3).times
  end
end
