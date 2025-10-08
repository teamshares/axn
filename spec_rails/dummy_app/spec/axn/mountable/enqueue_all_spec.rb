# frozen_string_literal: true

RSpec.describe "Axn::Mountable with enqueue_all" do
  before do
    Sidekiq::Testing.fake!
  end

  it "can call the basic Tester action" do
    result = Actions::EnqueueAll::Tester.call(number: 1)

    expect(result).to be_ok
  end

  it "can call enqueue_all method" do
    result = Actions::EnqueueAll::Tester.enqueue_all(max: 2)

    expect(result).to be_ok
  end
end
