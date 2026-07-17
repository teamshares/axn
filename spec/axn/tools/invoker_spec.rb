# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Tools::Invoker do
  let(:action) do
    Class.new do
      include Axn
      expects :name, type: String
      expects :age, type: Integer
      exposes :name
      def call = expose(name:)
    end
  end

  it "returns a plain Axn::Result on success" do
    result = described_class.new.call(action, { name: "ada", age: 36 })
    expect(result).to be_a(Axn::Result)
    expect(result).to be_ok
    expect(result.name).to eq("ada")
  end

  it "coerces wire strings without any per-field coerce: (coerce always on for tools)" do
    result = described_class.new.call(action, { name: "ada", age: "36" })
    expect(result).to be_ok
  end

  it "surfaces an inbound violation as a non-reported failure when user_facing_input_errors is on" do
    expect(Axn.config).not_to receive(:on_exception)
    invoker = described_class.new(user_facing_input_errors: true)
    result = invoker.call(action, { name: 123, age: 36 })
    expect(result).not_to be_ok
    expect(described_class.input_invalid?(result)).to be(true)
    expect(result.error).to match(/name/i)
  end

  it "input_invalid? is false for a success" do
    ok = described_class.new.call(action, { name: "ada", age: 36 })
    expect(described_class.input_invalid?(ok)).to be(false)
  end

  it "input_invalid? is false for a fail!" do
    failing = Class.new do
      include Axn
      def call = fail!("nope")
    end
    result = described_class.new.call(failing, {})
    expect(result).not_to be_ok
    expect(described_class.input_invalid?(result)).to be(false)
  end

  it "strips a model-supplied ambient_context from untrusted args" do
    sensing = Class.new do
      include Axn
      expects :x, type: Integer
      define_method(:call) { @seen = ambient_context }
      attr_reader :seen
    end
    result = described_class.new.call(sensing, { x: 1, ambient_context: { tenant: "evil" } })
    expect(result.__action__.seen).to eq({})
  end

  it "strips a model-supplied ambient_context passed as a STRING key from untrusted args" do
    # A declared ambient subfield is required here: with none declared, `ambient_context` short-circuits
    # to {} unconditionally (Bug Z1), which would pass this assertion even if the strip predicate were
    # broken to symbol-only comparison. Declaring :tenant (optional, so a stripped/absent value doesn't
    # fail validation before `call` runs) forces real resolution against `provided_data`, so a leaked
    # string-keyed "ambient_context" surfaces as `{ tenant: "evil" }` instead of `{}`.
    sensing = Class.new do
      include Axn
      expects :tenant, on: :ambient_context, type: String, optional: true
      define_method(:call) { @seen = ambient_context }
      attr_reader :seen
    end
    result = described_class.new.call(sensing, { "ambient_context" => { tenant: "evil" } })
    expect(result).to be_ok
    expect(result.__action__.seen).to eq({})
  end

  it "injects the adapter's trusted ambient_context after stripping" do
    sensing = Class.new do
      include Axn
      expects :tenant, on: :ambient_context, type: String
      exposes :tenant
      def call = expose(tenant:)
    end
    result = described_class.new.call(
      sensing,
      { ambient_context: { tenant: "evil" } },
      ambient_context: { tenant: "trusted" },
    )
    expect(result).to be_ok
    expect(result.tenant).to eq("trusted")
  end

  it "clears CurrentCallOptions after the call" do
    described_class.new(user_facing_input_errors: true).call(action, { name: "ada", age: 36 })
    expect(Axn::Internal::CurrentCallOptions.current).to be_nil
  end
end
