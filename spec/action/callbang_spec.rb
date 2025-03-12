RSpec.describe Action do
  describe ".call!" do
    subject { action.call! }

    context "with success" do
      let(:action) do
        build_action {}
      end

      it "is ok" do
        is_expected.to be_success
      end
    end

    context "with exception" do
      let(:action) do
        build_action do
          def call
            raise ZeroDivisionError, "manual bad thing"
          end
        end
      end

      it "confirming call case" do
        result = action.call
        expect(result).not_to be_success
        expect(result.error).to eq("Something went wrong")
      end

      it "call! raises original exception" do
        expect { subject }.to raise_error(ZeroDivisionError, "manual bad thing")
      end
    end

    context "with user-facing failure" do
      let(:action) do
        build_action do
          def call
            fail_with "User-facing error"
          end
        end
      end

      it "confirming call case" do
        result = action.call
        expect(result).not_to be_success
        expect(result.error).to eq("User-facing error")
      end

      it "call! raises our own Failure class" do
        expect { subject }.to raise_error(described_class::Failure, "User-facing error")
      end
    end
  end
end
