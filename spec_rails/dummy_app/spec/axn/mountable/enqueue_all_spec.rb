# frozen_string_literal: true

RSpec.describe "Axn::Mountable with enqueue_all" do
  before do
    Sidekiq::Testing.fake!
  end

  it "can call the basic Tester action with puts output and helpers" do
    expect do
      Actions::EnqueueAll::Tester.call(number: 1)
    end.to output(
      "Action executed: I was called with number: 1 | instance_helper | class_helper\n",
    ).to_stdout

    result = Actions::EnqueueAll::Tester.call(number: 1)
    expect(result).to be_ok
  end

  it "can call enqueue_all method and executes puts output" do
    expect do
      Actions::EnqueueAll::Tester.enqueue_all(max: 2)
    end.to output(
      "About to enqueue_all: max: 2 | instance_helper | class_helper\n",
    ).to_stdout

    result = Actions::EnqueueAll::Tester.enqueue_all(max: 2)
    expect(result).to be_ok
  end

  it "can call Tester action async" do
    allow(Actions::EnqueueAll::Tester).to receive(:call_async).and_call_original

    result = Actions::EnqueueAll::Tester.call_async(number: 1)

    expect(result).to be_a(String) # Job ID
    expect(Actions::EnqueueAll::Tester).to have_received(:call_async).once
  end

  it "can call enqueue_all_async method" do
    result = Actions::EnqueueAll::Tester.enqueue_all_async(max: 2)

    expect(result).to be_a(String) # Job ID
  end
end
