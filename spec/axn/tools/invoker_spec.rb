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

  it "rejects a model-supplied top-level key matching an ambient leaf name under reject_undeclared_inputs" do
    ambient_action = Class.new do
      include Axn
      expects :name, type: String
      expects :current_user, on: :ambient_context, type: String
      def call; end
    end
    invoker = described_class.new(reject_undeclared_inputs: true, user_facing_input_errors: true)
    result = invoker.call(
      ambient_action,
      { name: "ok", current_user: "evil" }, # hallucinated top-level key mirroring the ambient leaf
      ambient_context: { current_user: "trusted" },
    )
    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
    expect(result.error).to include("unknown input: current_user")
    expect(described_class.input_invalid?(result)).to be(true)
  end

  it "accepts the trusted ambient value alongside a declared field under reject_undeclared_inputs" do
    ambient_action = Class.new do
      include Axn
      expects :name, type: String
      expects :current_user, on: :ambient_context, type: String
      def call; end
    end
    invoker = described_class.new(reject_undeclared_inputs: true, user_facing_input_errors: true)
    result = invoker.call(ambient_action, { name: "ok" }, ambient_context: { current_user: "trusted" })
    expect(result).to be_ok
  end

  it "keeps a MISSING ambient value dev-facing under user_facing_input_errors (input_invalid? false)" do
    expect(Axn.config).to receive(:on_exception).at_least(:once)
    ambient_action = Class.new do
      include Axn
      expects :current_user, on: :ambient_context, type: String
      def call; end
    end
    invoker = described_class.new(user_facing_input_errors: true)
    result = invoker.call(ambient_action, {}) # adapter injects NO ambient_context
    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
    expect(Axn::ValidationError.user_facing?(result.exception)).to be(false)
    expect(described_class.input_invalid?(result)).to be(false)
  end

  it "keeps a MALFORMED adapter-supplied ambient value dev-facing (input_invalid? false)" do
    expect(Axn.config).to receive(:on_exception).at_least(:once)
    ambient_action = Class.new do
      include Axn
      expects :current_user, on: :ambient_context, type: String
      def call; end
    end
    invoker = described_class.new(user_facing_input_errors: true)
    result = invoker.call(ambient_action, {}, ambient_context: { current_user: 123 })
    expect(result).not_to be_ok
    expect(described_class.input_invalid?(result)).to be(false)
  end

  it "reports the whole set (input_invalid? false) when ambient and model-supplied fail together" do
    expect(Axn.config).to receive(:on_exception).at_least(:once)
    mixed = Class.new do
      include Axn
      expects :name, type: String
      expects :current_user, on: :ambient_context, type: String
      def call; end
    end
    invoker = described_class.new(user_facing_input_errors: true)
    result = invoker.call(mixed, { name: 123 })
    expect(result).not_to be_ok
    expect(described_class.input_invalid?(result)).to be(false)
  end

  it "clears CurrentCallOptions after the call" do
    described_class.new(user_facing_input_errors: true).call(action, { name: "ada", age: 36 })
    expect(Axn::Internal::CurrentCallOptions.current).to be_nil
  end
end
