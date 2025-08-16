# frozen_string_literal: true

RSpec.describe Action do
  describe "from filter" do
    # Define the inner action class first
    inner_action_class = Class.new do
      include Action

      def call
        raise ArgumentError, "inner failed"
      end
    end

    let(:outer) do
      build_action do
        error from: inner_action_class do
          "message about inner failure"
        end

        def call
          self.class.inner.call!
        end
      end.tap do |action|
        action.define_singleton_method(:inner) { inner_action_class }
      end
    end

    subject(:result) { outer.call }

    it "can be configured on an action" do
      expect(result).not_to be_ok
      expect(result.error).to eq("message about inner failure")
    end
  end
end
