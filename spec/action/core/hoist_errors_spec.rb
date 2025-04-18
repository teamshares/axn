# frozen_string_literal: true

RSpec.describe Action do
  describe "#hoist_errors" do
    subject { action.call(subaction:) }

    let(:subaction) { build_action }

    let(:action) do
      build_action do
        expects :subaction
        def call
          hoist_errors(prefix: "FROM HOIST:") { subaction.call }
        end
      end
    end

    it { is_expected.to be_ok }

    context "when the subaction fails" do
      let(:subaction) do
        build_action do
          def call = fail!("subaction failed")
        end
      end

      it { is_expected.not_to be_ok }
      it { expect(subject.error).to eq("FROM HOIST: subaction failed") }
      it { expect(subject.exception).to be_nil }
    end

    context "when the subaction is not an Action" do
      let(:subaction) { -> { "arbitrary logic" } }

      it { is_expected.not_to be_ok }
      # NOTE: no error_prefix, because the parent action called wrong, rather than bubbled failure from child
      it { expect(subject.error).to eq("Something went wrong") }
      it { expect(subject.exception).to be_a(ArgumentError) }
      it {
        expect(subject.exception.message).to eq("#hoist_errors is expected to wrap an Action call, but it returned a String instead")
      }

      context "and it raises" do
        let(:subaction) { -> { raise "subaction raised" } }

        before do
          expect(action).to receive(:warn).with("hoist_errors block swallowed an exception: subaction raised")
        end

        it { is_expected.not_to be_ok }
        it { expect(subject.error).to eq("FROM HOIST: Something went wrong") }
        it { expect(subject.exception).not_to eq(nil) }
      end
    end

    context "when the hoist_errors not given a block" do
      let(:action) do
        build_action do
          expects :subaction
          def call
            hoist_errors(prefix: "FROM HOIST:")
          end
        end
      end

      it { is_expected.not_to be_ok }
      it { expect(subject.exception).to be_a(ArgumentError) }
      it { expect(subject.exception.message).to eq("#hoist_errors must be given a block to execute") }
    end
  end
end
