# frozen_string_literal: true

# TODO: was used for manual testing -- clean up or remove when done

RSpec.describe "One-off confirmation: error :from" do
  module OneoffConfirmation
    class InnerAction
      include Action

      def call
        raise ArgumentError, "inner failed"
      end
    end

    class OuterAction
      include Action

      error from: InnerAction do |e|
        "PREFIXED: #{e.cause.message}"
      end

      def call
        InnerAction.call!
      end
    end
  end

  subject(:result) { OneoffConfirmation::OuterAction.call }

  it "can be configured on an action" do
    expect(result).not_to be_ok
    expect(result.error).to eq("PREFIXED: inner failed")
  end
end
