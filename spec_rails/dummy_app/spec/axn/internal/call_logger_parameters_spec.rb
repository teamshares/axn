# frozen_string_literal: true

# The call logger renders an ActionController::Parameters input by converting it with #to_unsafe_h —
# which recursively rebuilds every nested container, and so blows the stack on a self-referential value
# BEFORE the formatter's cycle guard can observe the repeated container. Needs real Parameters, so it
# lives here rather than in the non-Rails suite.
RSpec.describe "auto-log rendering of ActionController::Parameters" do
  let(:log_messages) { [] }

  def action_expecting_payload
    action = build_axn do
      expects :payload
      exposes :v
    end
    action.define_method(:call) { expose(v: 1) }
    allow(Axn.config.logger).to receive(:info) { |message| log_messages << message }
    allow(Axn.config.logger).to receive(:warn)
    action
  end

  it "renders the converted hash for ordinary Parameters" do
    expect(action_expecting_payload.call(payload: ActionController::Parameters.new(name: "Alice"))).to be_ok
    expect(log_messages.first).to include("Alice")
  end

  # A cycle gets inside Parameters only by in-place mutation of an already-nested Array: `new` and `[]=`
  # both convert eagerly, so they raise at assignment rather than storing one.
  it "falls back to a placeholder rather than losing the line to a stack overflow" do
    params = ActionController::Parameters.new(list: [1])
    nested = params[:list]
    nested << nested

    expect(action_expecting_payload.call(payload: params)).to be_ok
    expect(log_messages.first).to include("About to execute").and include("{...}")
    expect(log_messages.length).to eq(2) # the completion line still emits too
  end
end
