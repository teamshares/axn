# frozen_string_literal: true

# Regression: the framework memoizes its context facades into namespaced instance variables
# (@__result / @__internal_context) so that a user who innocently assigns their own @result or
# @internal_context inside an action does not clobber exposed-value extraction or message rendering.
# See PRO-2664.
RSpec.describe "internal instance variable isolation" do
  let(:action) do
    build_axn do
      expects :name, type: String
      exposes :greeting, type: String
      exposes :user_result, allow_blank: true

      success "static success"

      def call
        # A user innocently reusing these common names for their own state must not
        # corrupt the framework's facades.
        @result = "user's own result"
        @internal_context = "user's own context"

        expose greeting: "hi #{name}", user_result: @result
      end
    end
  end

  subject(:result) { action.call(name: "bob") }

  it "does not let a user @result clobber exposed-value extraction" do
    expect(result).to be_ok
    expect(result.greeting).to eq("hi bob")
  end

  it "renders messages correctly despite a user-defined @internal_context" do
    expect(result.success).to eq("static success")
  end

  it "preserves the user's own @result value" do
    expect(result.user_result).to eq("user's own result")
  end
end
