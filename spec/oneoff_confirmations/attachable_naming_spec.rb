# frozen_string_literal: true

# TODO: was used for manual testing -- clean up or remove when done

class SomeFakeClient
  include Action

  axnable_method :by_100 do |num:|
    raise "it was a zero" if num.zero?

    num * 100
  end
end

RSpec.describe "One-off confirmation: attachable naming" do
  it "works" do
    expect(SomeFakeClient.by_100!(num: 1)).to eq 100
  end

  # Run with DEBUG=1 to manually confirm the error message is prefixed with the correct class/action names
  it "errors ok" do
    expect { SomeFakeClient.by_100!(num: 0) }.to raise_error("it was a zero")
  end
end
