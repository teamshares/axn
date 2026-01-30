# frozen_string_literal: true

require "axn/async/adapters/sidekiq/auto_configure"

RSpec.describe Axn::Async::Adapters::Sidekiq::AutoConfigure do
  before do
    described_class.reset!
  end

  after do
    described_class.reset!
  end

  describe ".registered?" do
    it "returns false initially" do
      expect(described_class.registered?).to be false
    end

    it "returns true after register!" do
      # Mock Sidekiq
      stub_const("Sidekiq", Module.new)
      allow(Sidekiq).to receive(:configure_server).and_yield(double(
                                                               server_middleware: ->(&block) { block.call(double(add: nil, any?: false)) },
                                                               death_handlers: [],
                                                             ))

      described_class.register!
      expect(described_class.registered?).to be true
    end
  end

  describe ".validate_configuration!" do
    context "with :every_attempt mode" do
      it "does not raise even without middleware" do
        expect { described_class.validate_configuration!(:every_attempt) }.not_to raise_error
      end
    end

    context "with :first_and_exhausted mode" do
      it "raises when middleware is not registered" do
        expect { described_class.validate_configuration!(:first_and_exhausted) }
          .to raise_error(Axn::Async::Adapters::Sidekiq::ConfigurationError, /middleware not registered/)
      end

      it "raises when death handler is not registered" do
        # Simulate middleware registered but not death handler
        described_class.instance_variable_set(:@middleware_registered, true)

        expect { described_class.validate_configuration!(:first_and_exhausted) }
          .to raise_error(Axn::Async::Adapters::Sidekiq::ConfigurationError, /death handler not registered/)
      end

      it "does not raise when both are registered" do
        described_class.instance_variable_set(:@middleware_registered, true)
        described_class.instance_variable_set(:@death_handler_registered, true)

        expect { described_class.validate_configuration!(:first_and_exhausted) }.not_to raise_error
      end
    end

    context "with :only_exhausted mode" do
      it "raises when death handler is not registered" do
        described_class.instance_variable_set(:@middleware_registered, true)

        expect { described_class.validate_configuration!(:only_exhausted) }
          .to raise_error(Axn::Async::Adapters::Sidekiq::ConfigurationError, /death handler not registered/)
      end
    end
  end
end
