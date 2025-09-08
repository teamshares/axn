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
end
