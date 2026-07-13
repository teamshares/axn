# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn::Testing::SpecHelpers#with_ambient_context" do
  # Defensive: guarantee no provider leaks out of this file regardless of helper correctness.
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  let(:reader) do
    Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      exposes :cid
      def call = expose(cid: company_id)
    end
  end

  it "feeds a top-level on: :ambient_context input for the block" do
    result = nil
    with_ambient_context(company_id: 42) { result = reader.call }
    expect(result).to be_ok
    expect(result.cid).to eq(42)
  end

  it "feeds a nested action's ambient input (the win vs. the per-call kwarg)" do
    child = reader
    parent = Class.new do
      include Axn
      exposes :cid
      define_method(:call) { expose(cid: child.call!.cid) }
    end

    result = nil
    with_ambient_context(company_id: 7) { result = parent.call }
    expect(result).to be_ok
    expect(result.cid).to eq(7)
  end

  it "an explicit ambient_context: kwarg still overrides the provider inside the block" do
    result = nil
    with_ambient_context(company_id: 42) { result = reader.call(ambient_context: { company_id: 1 }) }
    expect(result.cid).to eq(1)
  end

  it "restores the previous provider afterwards" do
    previous = -> { { company_id: 99 } }
    Axn.config.ambient_context_provider = previous
    with_ambient_context(company_id: 42) do
      expect(Axn.config.ambient_context_provider.call).to eq(company_id: 42)
    end
    expect(Axn.config.ambient_context_provider).to eq(previous)
  end

  it "restores the previous provider even when the block raises" do
    Axn.config.ambient_context_provider = nil
    expect do
      with_ambient_context(company_id: 42) { raise "boom" }
    end.to raise_error("boom")
    expect(Axn.config.ambient_context_provider).to be_nil
  end

  it "restores correctly under nested/re-entrant use" do
    outer_seen = inner_seen = nil
    with_ambient_context(company_id: 1) do
      with_ambient_context(company_id: 2) { inner_seen = reader.call.cid }
      outer_seen = reader.call.cid
    end
    expect(inner_seen).to eq(2)
    expect(outer_seen).to eq(1)
    expect(Axn.config.ambient_context_provider).to be_nil
  end

  it "does not mutate Current / CurrentAttributes (feeds purely via the provider)" do
    skip "ActiveSupport::CurrentAttributes required" unless defined?(ActiveSupport::CurrentAttributes)

    current = Class.new(ActiveSupport::CurrentAttributes) { attribute :company_id }
    stub_const("WithAmbientContextSpecCurrent", current)

    with_ambient_context(company_id: 42) do
      expect(reader.call.cid).to eq(42)
      expect(current.instance.company_id).to be_nil
    end
  ensure
    current&.reset
  end
end
