# frozen_string_literal: true

RSpec.describe Axn::Enqueueable do
  let(:action) { build_axn }

  context "when ActiveJob is available" do
    it "includes ViaActiveJob" do
      expect(action.ancestors).to include(Axn::Enqueueable::ViaActiveJob)
    end

    it "provides perform_later method" do
      expect(action).to respond_to(:perform_later)
    end

    it "provides perform_now method" do
      expect(action).to respond_to(:perform_now)
    end

    it "perform_later works without raising" do
      expect { action.perform_later(foo: "bar") }.not_to raise_error
    end

    it "perform_now works without raising" do
      expect { action.perform_now(foo: "bar") }.not_to raise_error
    end
  end
end
