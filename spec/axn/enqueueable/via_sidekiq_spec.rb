# frozen_string_literal: true

require "sidekiq/testing"
require "axn/enqueueable"
require "fixtures/enqueueable"

RSpec.describe Axn::Enqueueable::ViaSidekiq, type: :worker do
  context "Interactor" do
    describe "#perform_later" do
      subject { TestEnqueueableInteractor.perform_later(this: "this", that: "that") }

      it "queues job to the default queue" do
        expect(TestEnqueueableInteractor.queue).to eq("default")
      end

      it "sets the options" do
        expect(TestEnqueueableInteractor.sidekiq_options_hash).to include("retry" => 10, "queue" => "default",
                                                                          "retry_queue" => "low")
      end

      it "performs later" do
        expect(TestEnqueueableInteractor).to receive(:perform_async).with(hash_including({ "this" => "this" }))
        subject
      end
    end

    describe "#perform_later execution" do
      subject do
        Sidekiq::Testing.inline! do
          TestEnqueueableInteractor.perform_later(this: "this", that: "that")
        end
      end

      it "calls the Interactor#call" do
        expect_any_instance_of(TestEnqueueableInteractor).to receive(:perform).with(hash_including({ "this" => "this" })).and_call_original
        expect(TestEnqueueableInteractor).to receive(:call).with(hash_including({ this: "this" }))
        subject
      end
    end

    describe "#perform_now" do
      subject do
        TestEnqueueableInteractor.perform_now(name: "Joe", address: "123 Nope")
      end

      it "calls the Interactor#call directly" do
        expect(TestEnqueueableInteractor).to receive(:call).with({ name: "Joe", address: "123 Nope" })
        subject
      end

      it "executes immediately" do
        expect { subject }.to output(/Name: Joe\nAddress: 123 Nope\n/).to_stdout
      end
    end
  end

  describe "params" do
    subject { AnotherEnqueueableInteractor.perform_later(foo:) }

    context "with string" do
      let(:foo) { "bar" }

      it "doesn't raise" do
        subject
      end
    end

    context "with complex object" do
      let(:foo) { AnotherEnqueueableInteractor }

      it "raises" do
        expect do
          subject
        end.to raise_error(ArgumentError,
                           "Cannot pass non-JSON-serializable objects to Sidekiq. Make sure all expected arguments are serializable (or respond to to_global_id).") # rubocop:disable Layout/LineLength
      end
    end
  end
end
