# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe Axn::Enqueueable::ViaActiveJob, type: :job do
  include ActiveJob::TestHelper
  context "Action" do
    let(:action) { build_axn { puts "test" } }

    describe "#perform_later" do
      it "enqueues a job" do
        expect { action.perform_later(this: "this", that: "that") }.not_to raise_error
      end
    end

    describe "#perform_now" do
      subject do
        action.perform_now(name: "Joe", address: "123 Nope")
      end

      it "calls the Action#call directly" do
        expect(action).to receive(:call).with({ name: "Joe", address: "123 Nope" })
        subject
      end

      it "executes immediately" do
        expect { subject }.to output(/test/).to_stdout
      end
    end
  end

  describe "params" do
    let(:action) { build_axn { log "test" } }
    subject { action.perform_later(foo:) }

    context "with string" do
      let(:foo) { "bar" }

      it "doesn't raise" do
        expect { subject }.not_to raise_error
      end
    end

    context "with complex object" do
      let(:foo) { action }

      it "raises serialization error" do
        expect { subject }.to raise_error(ArgumentError, /Cannot pass non-serializable objects to ActiveJob/)
      end
    end
  end

  describe "GlobalID serialization" do
    let(:action) { build_axn { puts "test" } }
    let(:user) { double("User", to_global_id: double("GlobalID", to_s: "gid://app/User/123")) }

    it "converts GlobalID objects to strings" do
      expect { action.perform_later(user:) }.not_to raise_error
    end
  end
end
