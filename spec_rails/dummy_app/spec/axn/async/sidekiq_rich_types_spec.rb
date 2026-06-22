# frozen_string_literal: true

require "tempfile"

RSpec.describe Actions::Async::TestActionSidekiqRichTypes, :sidekiq do
  before do
    Sidekiq::Testing.inline!
    Sidekiq.strict_args!(false)
    Sidekiq::Job.jobs.clear
  end

  after do
    Sidekiq::Testing.fake!
    Sidekiq.strict_args!(true)
    Sidekiq::Job.jobs.clear
  end

  it "delivers a Time (not a String) to the worker through the Sidekiq payload" do
    serialized = Axn::Internal::AsyncSerialization.serialize(occurred_at: Time.at(1_700_000_000))
    context = Axn::Internal::AsyncSerialization.deserialize(serialized)
    result = described_class.call(**context)
    expect(result).to be_ok
    expect(result.klass_name).to eq("Time")
  end

  it "raises a field-aware error when enqueued with an unserializable arg" do
    expect { described_class.call_async(occurred_at: Tempfile.new("x")) }
      .to raise_error(Axn::Async::UnserializableArgument, /occurred_at/)
  end
end
