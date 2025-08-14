# frozen_string_literal: true

RSpec.describe Action do
  describe "from filter" do
    let(:inner) do
      build_action do
        def call
          raise ArgumentError, "inner failed"
        end
      end
    end

    let(:outer) do
      build_action do
        error from: "InnerAction" do
          "message about inner failure"
        end

        def call
          self.class.inner.call!
        end
      end.tap do |action|
        inner_action = inner # Capture the variable
        action.define_singleton_method(:inner) { inner_action }
      end
    end

    subject(:result) { outer.call }

    it "can be configured on an action" do
      expect(result).not_to be_ok
      expect(result.error).to eq("message about inner failure")
    end
  end
end
