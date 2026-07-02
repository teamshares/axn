# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn ambient_context (reader + subfield parent)" do
  it "reads {} by default and does not appear in the input schema" do
    klass = Class.new { include Axn }
    expect(klass.input_schema[:properties]).not_to have_key(:ambient_context)
  end

  it "the ambient_context reader returns {} when nothing is provided" do
    klass = Class.new do
      include Axn
      exposes :ctx, allow_blank: true
      def call = expose(ctx: ambient_context)
    end
    expect(klass.call.ctx).to eq({})
  end

  it "reads an explicitly-passed ambient_context subfield" do
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      exposes :cid
      def call = expose(cid: company_id)
    end
    result = klass.call(ambient_context: { company_id: 42 })
    expect(result).to be_ok
    expect(result.cid).to eq(42)
  end

  it "keeps ambient_context subfields out of the input schema (nested under excluded parent)" do
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      expects :limit, type: Integer, default: 5
    end
    props = klass.input_schema[:properties]
    expect(props).to have_key(:limit)
    expect(props).not_to have_key(:company_id)
    expect(props).not_to have_key(:ambient_context)
  end

  it "rejects a user-declared top-level ambient_context field" do
    expect do
      Class.new do
        include Axn
        expects :ambient_context
      end
    end.to raise_error(Axn::ContractViolation::ReservedAttributeError)
  end
end
