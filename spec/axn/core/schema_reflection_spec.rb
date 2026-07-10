# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn class-level schema reflection" do
  let(:klass) do
    Class.new do
      include Axn
      expects :token, type: String, sensitive: true, description: "secret"
      exposes :status, type: String
      def call = expose(status: "ok")
    end
  end

  it "exposes input_schema over expects" do
    expect(klass.input_schema[:properties][:token]).to include(type: "string", description: "secret")
    expect(klass.input_schema[:required]).to eq(["token"])
  end

  it "exposes output_schema over exposes" do
    expect(klass.output_schema[:properties][:status]).to include(type: "string")
  end

  it "does NOT let sensitive: true change the input schema" do
    plain = Class.new do
      include Axn
      expects :token, type: String, description: "secret"
    end
    expect(klass.input_schema).to eq(plain.input_schema)
  end
end
