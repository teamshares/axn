# frozen_string_literal: true

RSpec.describe Action::Configuration do
  subject(:config) { described_class.new }

  describe "defaults (in test mode)" do
    it { expect(config.top_level_around_hook).to be_nil }
    it { expect(config.additional_includes).to eq([]) }
    it { expect(config.logger).to be_a(Logger) }
    it { expect(config.env.test?).to eq(true) }
  end

  describe "#env" do
    it "can be set to production" do
      expect(config.env.test?).to eq(true)
      config.env = "production"
      expect(config.env.production?).to eq(true)
    end
  end
end
