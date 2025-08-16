# frozen_string_literal: true

RSpec.describe Action do
  let(:inner_action_class) do
    stub_const("InnerAction", Class.new do
      include Action

      expects :type

      error "default inner error"

      error if: ArgumentError do |e|
        "that wasn't a nice arg (#{e.message})"
      end

      def call
        raise ArgumentError, "handled" if type == :handled

        raise StandardError, "inner failed unhandled"
      end
    end)
  end

  let(:outer_action_class) do
    # Ensure InnerAction is defined first
    inner_action_class

    stub_const("OuterAction", Class.new do
      include Action

      expects :type

      error from: InnerAction do |e|
        "PREFIXED: #{e.message}"
      end

      def call
        InnerAction.call!(type:)
      end
    end)
  end

  it "can be configured on an action" do
    expect(outer_action_class.call(type: :handled).error).to eq(
      "PREFIXED: that wasn't a nice arg (handled)",
    )

    expect(outer_action_class.call(type: :unhandled).error).to eq(
      "PREFIXED: default inner error",
    )
  end
end
