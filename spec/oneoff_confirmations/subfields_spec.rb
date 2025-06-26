# frozen_string_literal: true

# TODO: was used for manual testing -- clean up or remove when done

RSpec.describe "One-off confirmation" do
  let(:foo_module) do
    Module.new do
      extend ActiveSupport::Concern

      included do
        expects :message
        expects :data, on: :message
        expects :model_name, :model_id, :status, on: :data
        expects :error_message, :json_debug_info, presence: false, on: :data
      end
    end
  end

  let(:action) do
    build_action do
      def call
        model_id # this confirms with_indifferent_access is working
        error_message # this confirms that the subfield reader is working when field given validations
      end
    end.tap do |a|
      a.include(foo_module)
    end
  end

  let(:message) do
    {
      "data" => {
        "model_name" => "model_name",
        "model_id" => "model_id",
        "status" => "status",
        "error_message" => "error_message",
        "json_debug_info" => "json_debug_info",
      },
    }
  end
  subject { action.call!(message:) }

  it { is_expected.to be_ok }
end
