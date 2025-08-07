# frozen_string_literal: true

RSpec.describe Action::Configuration do
  subject(:config) { described_class.new }

  describe "defaults (in test mode)" do
    it { expect(config.emit_metrics).to be_nil }
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

  describe "#on_exception" do
    let(:exception) { StandardError.new("fail!") }
    let(:action) { double("Action", log: nil) }
    let(:context) { { foo: :bar } }
    subject(:config) { described_class.new }

    it "calls proc with only e if no kwargs expected" do
      called = nil
      config.on_exception = proc { |e| called = [e] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception])
    end

    it "calls proc with e and action if action: is expected" do
      called = nil
      config.on_exception = proc { |e, action:| called = [e, action] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, action])
    end

    it "calls proc with e and context if context: is expected" do
      called = nil
      config.on_exception = proc { |e, context:| called = [e, context] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, context])
    end

    it "calls proc with e, action, and context if both are expected" do
      called = nil
      config.on_exception = proc { |e, action:, context:| called = [e, action, context] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, action, context])
    end

    it "does not pass unknown kwargs" do
      called = nil
      config.on_exception = proc { |e, foo: nil| called = [e, foo] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, nil])
    end
  end
end
