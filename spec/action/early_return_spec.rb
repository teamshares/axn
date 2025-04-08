# frozen_string_literal: true

RSpec.describe Action do
  describe "early return" do
    subject(:result) { action.call(early_return:) }

    let(:early_return) { nil }

    let(:action) do
      build_action do
        expects :early_return, allow_blank: true

        before do
          log "before"
          success!("some message") if early_return
        end

        def call
          log "in call"
        end

        after do
          fail!("Did not return early (early return skips after block)")
        end
      end
    end

    it "base case" do
      is_expected.not_to be_ok
      expect(subject.error).to eq("Did not return early (early return skips after block)")
    end

    context "with early return" do
      let(:early_return) { true }

      it "returns early" do
        is_expected.to be_ok
        expect(result.success).to eq("some message")
      end
    end
  end
end
