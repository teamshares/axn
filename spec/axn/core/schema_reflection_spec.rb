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

  describe "unrepresentable-subfield omission warning" do
    let(:deep_klass) do
      Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id, :profile), finder: :find }
        expects :name, on: "user.profile", type: String # deep under a model: parent — no object representation
      end
    end

    it "warns, naming the omitted field" do
      expect(Axn.config.logger).to receive(:warn).with(/input_schema omits deep subfield.*model: or non-object parent.*\bname\b/m)
      deep_klass.input_schema
    end

    it "warns at most once per class across repeated input_schema calls" do
      expect(Axn.config.logger).to receive(:warn).once
      3.times { deep_klass.input_schema }
    end

    it "warns for a dotted-NAME model config (its id is not JSON-consumable)" do
      dotted_model_klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects "org.company", on: :payload, model: { klass: Struct.new(:id), finder: :find }
      end
      expect(Axn.config.logger).to receive(:warn).with(/input_schema omits deep subfield.*dotted-name model.*org\.company/m)
      dotted_model_klass.input_schema
    end

    it "does not warn for a representable deep chain (object-shaped parents)" do
      representable = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash
        expects :id, on: :meta, type: Integer
      end
      expect(Axn.config.logger).not_to receive(:warn)
      representable.input_schema
    end

    it "does not warn when every subfield is shallow" do
      shallow_klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: String
      end
      expect(Axn.config.logger).not_to receive(:warn)
      shallow_klass.input_schema
    end
  end
end
