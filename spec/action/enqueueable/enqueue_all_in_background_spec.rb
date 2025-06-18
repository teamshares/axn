# frozen_string_literal: true

RSpec.describe Action::Enqueueable::EnqueueAllInBackground do
  subject { klass.enqueue_all_in_background }

  let(:klass_name) { "SomeSpecificAction" }
  let(:klass) { build_action }

  before do
    allow(klass).to receive(:name).and_return(klass_name)
  end

  context "when the class does not implement .enqueue_all" do
    it "raises an error" do
      expect do
        subject
      end.to raise_error(NotImplementedError, "#{klass_name} must implement a .enqueue_all method in order to use .enqueue_all_in_background")
    end
  end

  context "when the class implements .enqueue_all" do
    before do
      allow(klass).to receive(:enqueue_all)
    end

    it "queues job to the default queue" do
      expect(Action::Enqueueable::EnqueueAllWorker).to receive(:enqueue).with(klass_name: "SomeSpecificAction")
      subject
    end
  end
end
