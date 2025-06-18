# frozen_string_literal: true

RSpec.describe Action::Enqueueable::EnqueueAllWorker do
  subject { described_class.call(klass_name:) }

  let(:klass_name) { "SomeSpecificAction" }
  let(:klass) do
    build_action do
      on_success { puts "success" }
    end
  end

  before do
    allow(klass).to receive(:name).and_return(klass_name)
    stub_const(klass_name, klass)
    allow(klass).to receive(:enqueue_all)
  end

  it "calls the enqueue_all method" do
    expect(klass).to receive(:enqueue_all)
    is_expected.to be_ok
  end
end
