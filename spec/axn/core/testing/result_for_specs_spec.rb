# frozen_string_literal: true

RSpec.describe "Action spec helpers" do
  describe "Axn::Result.ok" do
    context "bare" do
      subject(:result) { Axn::Result.ok }

      it { is_expected.to be_ok }
      it { expect(result.success).to eq("Action completed successfully") }
    end

    context "allow blank exposures" do
      subject(:result) { Axn::Result.ok(still_exposable: "", another: nil) }

      it { is_expected.to be_ok }
      it { expect(result.success).to eq("Action completed successfully") }
      it { expect(result.still_exposable).to eq("") }
      it { expect(result.another).to be_nil }
    end

    context "with custom message and exposure" do
      subject(:result) { Axn::Result.ok("optional success message", custom_exposure: 123) }

      it { is_expected.to be_ok }
      it { expect(result.success).to eq("optional success message") }
      it { expect(result.custom_exposure).to eq(123) }
    end
  end

  describe "Axn::Result.error" do
    context "bare" do
      subject(:result) { Axn::Result.error }

      it { is_expected.not_to be_ok }
      it { expect(result.error).to eq("Something went wrong") }
    end

    context "with custom message and exposure" do
      subject(:result) { Axn::Result.error("Custom error message", still_exposable: 456) }

      it { is_expected.not_to be_ok }
      it { expect(result.error).to eq("Custom error message") }
      it { expect(result.exception).to be_a(Axn::Failure) }
      it { expect(result.still_exposable).to eq(456) }
    end

    context "allow blank exposures" do
      subject(:result) { Axn::Result.error(still_exposable: "", another: nil) }

      it { is_expected.not_to be_ok }
      it { expect(result.error).to eq("Something went wrong") }
      it { expect(result.exception).to be_a(Axn::Failure) }
      it { expect(result.still_exposable).to eq("") }
      it { expect(result.another).to be_nil }
    end

    context "with exception" do
      subject(:result) do
        Axn::Result.error("default msg", still_exposable: 456) do
          raise StandardError, "Custom error message"
        end
      end

      it { is_expected.not_to be_ok }
      it { expect(result.error).to eq("default msg") }
      it { expect(result.exception).to be_a(StandardError) }
      it { expect(result.exception.message).to eq("Custom error message") }
      it { expect(result.still_exposable).to eq(456) }
    end
  end

  describe "Axn::Result#outcome" do
    it "returns success for ok results" do
      expect(Axn::Result.ok.outcome.success?).to be true
      expect(Axn::Result.ok.outcome.failure?).to be false
      expect(Axn::Result.ok.outcome.exception?).to be false
    end

    it "returns failure for error results" do
      expect(Axn::Result.error.outcome.success?).to be false
      expect(Axn::Result.error.outcome.failure?).to be true
      expect(Axn::Result.error.outcome.exception?).to be false
    end

    it "returns exception for results with exceptions" do
      result = Axn::Result.error { raise "error" }
      expect(result.outcome.success?).to be false
      expect(result.outcome.failure?).to be false
      expect(result.outcome.exception?).to be true
    end
  end

  describe "Axn::Result#elapsed_time" do
    it "returns elapsed time for action results" do
      action = build_axn
      result = action.call
      expect(result.elapsed_time).to be_a(Float)
      expect(result.elapsed_time).to be >= 0
    end

    it "returns elapsed time for factory-created results" do
      result = Axn::Result.ok
      expect(result.elapsed_time).to be_a(Float)
      expect(result.elapsed_time).to be >= 0
    end
  end

  describe "Axn::Result#finalized?" do
    context "for factory-created results" do
      it "returns true for newly created ok results" do
        result = Axn::Result.ok
        expect(result.finalized?).to be true
      end

      it "returns true for newly created error results" do
        result = Axn::Result.error
        expect(result.finalized?).to be true
      end
    end

    context "for action execution results" do
      let(:action) { build_axn }

      it "returns true after successful execution" do
        result = action.call
        expect(result.finalized?).to be true
      end

      it "returns true after failed execution" do
        action = build_axn do
          def call
            fail! "intentional error"
          end
        end
        result = action.call
        expect(result.finalized?).to be true
      end

      it "returns true after exception during execution" do
        action = build_axn do
          def call
            raise "unhandled error"
          end
        end
        result = action.call
        expect(result.finalized?).to be true
      end
    end

    context "for factory methods" do
      it "returns finalized results from Axn::Result.ok" do
        result = Axn::Result.ok
        expect(result.finalized?).to be true
      end

      it "returns finalized results from Axn::Result.error" do
        result = Axn::Result.error
        expect(result.finalized?).to be true
      end

      it "returns finalized results from Axn::Result.error with block" do
        result = Axn::Result.error { raise "test error" }
        expect(result.finalized?).to be true
      end
    end
  end

  describe "Axn::Result.ok and Axn::Result.error skip logging and error handlers" do
    let(:log_messages) { [] }
    let(:original_handler) { Axn.config.instance_variable_get(:@on_exception) }

    before do
      Axn.config.instance_variable_set(:@on_exception, nil)
    end

    after do
      Axn.config.instance_variable_set(:@on_exception, original_handler)
    end

    describe "Axn::Result.ok" do
      context "when logging is enabled by default" do
        before do
          allow_any_instance_of(Axn::Result).to receive(:info) do |_instance, message, **options|
            log_messages << { level: :info, message:, options: }
          end
        end

        it "does not log when using Result.ok" do
          result = Axn::Result.ok
          expect(result).to be_ok
          expect(log_messages).to be_empty
        end
      end

      context "when global on_exception handler is set" do
        before do
          Axn.config.on_exception = proc do |_e, action:, context:|
            log_messages << { type: :global_handler, action: action.class.name, context: }
          end
        end

        it "does not trigger global on_exception handler" do
          result = Axn::Result.ok
          expect(result).to be_ok
          expect(log_messages).to be_empty
        end
      end
    end

    describe "Axn::Result.error" do
      context "when logging is enabled by default" do
        before do
          allow_any_instance_of(Axn::Result).to receive(:info) do |_instance, message, **options|
            log_messages << { level: :info, message:, options: }
          end
          allow_any_instance_of(Axn::Result).to receive(:warn) do |_instance, message, **options|
            log_messages << { level: :warn, message:, options: }
          end
        end

        it "does not log when using Result.error" do
          result = Axn::Result.error
          expect(result).not_to be_ok
          expect(log_messages).to be_empty
        end

        it "does not log when using Result.error with exception block" do
          result = Axn::Result.error { raise StandardError, "test error" }
          expect(result).not_to be_ok
          expect(log_messages).to be_empty
        end
      end

      context "when global on_exception handler is set" do
        before do
          Axn.config.on_exception = proc do |_e, action:, context:|
            log_messages << { type: :global_handler, action: action.class.name, context: }
          end
        end

        it "does not trigger global on_exception handler for fail!" do
          result = Axn::Result.error("test error")
          expect(result).not_to be_ok
          expect(log_messages).to be_empty
        end

        it "does not trigger global on_exception handler for exception in block" do
          result = Axn::Result.error { raise StandardError, "test error" }
          expect(result).not_to be_ok
          expect(result.exception).to be_a(StandardError)
          expect(log_messages).to be_empty
        end
      end

      context "when action has on_error callback" do
        it "triggers on_error callback" do
          result = Axn::Result.error("test error")
          expect(result).not_to be_ok
          # Error handlers are still triggered for Result.error
          expect(result.error).to eq("test error")
        end
      end
    end
  end
end
