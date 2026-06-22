# frozen_string_literal: true

RSpec.describe "on_success without ActiveRecord" do
  it "dispatches on_success inline when ActiveRecord is not loaded" do
    expect(defined?(ActiveRecord)).to be_falsey

    collector = []
    action = build_axn do
      expects :collector, allow_blank: true
      on_success { collector << :success }

      def call; end
    end

    action.call!(collector:)
    expect(collector).to eq([:success])
  end
end
