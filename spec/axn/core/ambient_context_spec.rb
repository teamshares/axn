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

  it "rejects a user-declared ambient_context exposure" do
    expect do
      Class.new do
        include Axn
        exposes :ambient_context
      end
    end.to raise_error(Axn::ContractViolation::ReservedAttributeError)
  end
end

RSpec.describe "Axn ambient_context resolution" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  let(:klass) do
    Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      exposes :ctx, allow_blank: true
      def call = expose(ctx: ambient_context)
    end
  end

  it "filters the hash to declared ambient keys (explicit path)" do
    result = klass.call(ambient_context: { company_id: 7, secret: "leak" })
    expect(result.ctx).to eq(company_id: 7)
  end

  it "falls back to the configured provider, then filters to declared keys" do
    Axn.config.ambient_context_provider = -> { { company_id: 99, other: "x" } }
    result = klass.call
    expect(result.ctx).to eq(company_id: 99)
  end

  it "explicit REPLACES the provider (no silent merge)" do
    Axn.config.ambient_context_provider = -> { { company_id: 99 } }
    result = klass.call(ambient_context: { company_id: 1 })
    expect(result.ctx).to eq(company_id: 1)
  end

  it "fails inbound validation for a required ambient subfield when empty" do
    result = klass.call
    expect(result).not_to be_ok
  end

  it "explicit ambient_context: nil overrides the provider (does not fall back to it)" do
    Axn.config.ambient_context_provider = -> { { company_id: 99 } }
    result = klass.call(ambient_context: nil)
    expect(result).not_to be_ok
  end
end

RSpec.describe "Axn::Core::AmbientContext.default_source" do
  it "merges attributes across registered CurrentAttributes descendants" do
    skip "ActiveSupport::CurrentAttributes required" unless defined?(ActiveSupport::CurrentAttributes)

    # ActiveSupport::CurrentAttributes keys its per-class instance storage off the class's `name`,
    # so an anonymous class silently breaks `.instance`/`.reset` — stub_const both gives it a name
    # and guarantees the constant doesn't leak into other specs.
    current = Class.new(ActiveSupport::CurrentAttributes) { attribute :company_id }
    stub_const("AmbientContextSpecCurrent", current)
    current.instance.company_id = 5
    merged = Axn::Core::AmbientContext.default_source
    expect(merged[:company_id]).to eq(5)
  ensure
    current&.reset
  end
end

RSpec.describe "Axn ambient_context subfield restrictions" do
  it "rejects preprocess: on an ambient_context subfield" do
    expect do
      Class.new do
        include Axn
        expects :company, on: :ambient_context, preprocess: ->(v) { v }
      end
    end.to raise_error(ArgumentError, /preprocess/)
  end

  it "rejects default: on an ambient_context subfield" do
    expect do
      Class.new do
        include Axn
        expects :company, on: :ambient_context, default: 5
      end
    end.to raise_error(ArgumentError, /default/)
  end

  it "still allows sensitive: on an ambient_context subfield" do
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, type: Integer, sensitive: -> { true }
    end
    expect(klass).to be_a(Class)
  end

  it "rejects a dotted `on:` path rooted at ambient_context (deep ambient nesting is deferred)" do
    expect do
      Class.new do
        include Axn
        expects :ip, on: "ambient_context.request", type: String
      end
    end.to raise_error(ArgumentError, /dotted `on:` path rooted at :ambient_context/)
  end

  it "still allows a plain (non-dotted) on: :ambient_context subfield" do
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, type: Integer
    end
    expect(klass).to be_a(Class)
  end
end

RSpec.describe "Axn::Core::AmbientContext#_filter_to_declared" do
  it "preserves the <field>_id key when filtering a model ambient subfield" do
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, model: { klass: Struct.new(:id), finder: :find }
    end
    inst = klass.send(:new, ambient_context: { company_id: 7 })
    filtered = inst.send(:_filter_to_declared, { company_id: 7 })
    expect(filtered).to eq(company_id: 7)
  end

  it "still preserves the record key when a model ambient subfield is supplied by record" do
    record_klass = Struct.new(:id)
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, model: { klass: record_klass, finder: :find }
    end
    rec = record_klass.new(7)
    inst = klass.send(:new, ambient_context: { company: rec })
    filtered = inst.send(:_filter_to_declared, { company: rec })
    expect(filtered).to eq(company: rec)
  end

  it "does not add an _id key for a non-model ambient subfield" do
    klass = Class.new do
      include Axn
      expects :tenant, on: :ambient_context, type: String
    end
    inst = klass.send(:new, ambient_context: { tenant: "acme", tenant_id: "x" })
    filtered = inst.send(:_filter_to_declared, { tenant: "acme", tenant_id: "x" })
    expect(filtered).to eq(tenant: "acme") # tenant_id NOT copied (non-model)
  end
end

RSpec.describe "Axn ambient_context provider short-circuit (Bug Z1)" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  it "does not invoke the provider when no ambient subfields are declared" do
    Axn.config.ambient_context_provider = -> { raise "boom" }
    klass = Class.new do
      include Axn
      expects :x, type: String
      def call = nil
    end

    result = nil
    expect { result = klass.call(x: "y") }.not_to raise_error
    expect(result).to be_ok
  end

  it "does not raise from the provider when building execution_context for an action with no ambient subfields" do
    Axn.config.ambient_context_provider = -> { raise "boom" }
    klass = Class.new do
      include Axn
      expects :x, type: String
      def call = nil
    end

    instance = klass.send(:new, x: "y")
    instance._run
    expect { instance.execution_context }.not_to raise_error
  end

  it "still calls the provider when an ambient subfield IS declared (a raising provider surfaces as a failure)" do
    Axn.config.ambient_context_provider = -> { raise "boom" }
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      def call = nil
    end

    result = klass.call
    expect(result).not_to be_ok
  end
end

RSpec.describe "Axn ambient_context exception-context hardening (Bug DD)" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  it "does not re-raise from a failing provider when building execution_context after the failure" do
    Axn.config.ambient_context_provider = -> { raise "provider boom" }
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      def call = nil
    end

    instance = klass.send(:new)
    instance._run
    expect(instance.result).not_to be_ok

    ctx = nil
    expect { ctx = instance.execution_context }.not_to raise_error
    expect(ctx).not_to have_key(:ambient_context)
  end
end

RSpec.describe "Axn ambient_context provider memoization (Bug EE)" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  it "does not re-raise from execution_context when a dynamic sensitive: predicate on another " \
     "ambient subfield re-reads ambient_context during logging-filter construction" do
    Axn.config.ambient_context_provider = -> { raise "provider boom" }
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      expects :secret_id, on: :ambient_context, type: Integer,
                          sensitive: -> { respond_to?(:secret_id) && !secret_id.nil? }
      def call = nil
    end

    result = klass.call
    expect(result).not_to be_ok

    instance = klass.send(:new)
    instance._run
    expect { instance.execution_context }.not_to raise_error
  end

  it "still surfaces the provider failure as the action's exception on first resolution" do
    Axn.config.ambient_context_provider = -> { raise "provider boom" }
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      def call = nil
    end

    result = klass.call
    expect(result).not_to be_ok
    expect(result.exception).to be_a(StandardError)
  end

  it "invokes the provider at most once even when ambient_context is read multiple times after failure" do
    call_count = 0
    Axn.config.ambient_context_provider = lambda {
      call_count += 1
      raise "provider boom"
    }
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      def call = nil
    end

    instance = klass.send(:new)
    instance._run
    3.times { instance.execution_context }

    # A direct (unguarded) read re-raises the memoized error rather than re-running the provider
    # (Bug JJ: memoizing {} would mask the real failure from validation/reporting, so the error
    # itself is memoized and re-raised on every subsequent read instead).
    expect { instance.send(:ambient_context) }.to raise_error(RuntimeError, "provider boom")

    expect(call_count).to eq(1)
  end
end

RSpec.describe "Axn ambient_context provider failure surfaces the real error, not a masked {} (Bug JJ)" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  # Auto-logging is on by default (Axn.config.log_level), so `with_logging`'s before-hook runs
  # BEFORE `with_contract`'s inbound validation. Building that before-log's filter resolves the
  # dynamic `sensitive:` predicate below, which reads `secret_id` — the FIRST read of
  # ambient_context — inside `CallLogger`, which swallows logging errors. Prior to the fix, that
  # swallowed failure memoized `{}`, so inbound validation (the next read) saw an empty ambient
  # context and raised a bogus "can't be blank" InboundValidationError instead of the provider's
  # real error.
  let(:klass) do
    Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      expects :secret_id, on: :ambient_context, type: Integer, allow_nil: true,
                          sensitive: -> { respond_to?(:secret_id) && !secret_id.nil? }
      def call = nil
    end
  end

  it "surfaces the provider's real exception, not a masked missing-subfield validation error" do
    Axn.config.ambient_context_provider = -> { raise "provider boom" }

    result = klass.call

    expect(result).not_to be_ok
    expect(result.exception).to be_a(RuntimeError)
    expect(result.exception.message).to match(/provider boom/)
    expect(result.exception).not_to be_a(Axn::InboundValidationError)
  end

  it "does not raise while building execution_context, degrading inputs/ambient to {}" do
    Axn.config.ambient_context_provider = -> { raise "provider boom" }

    result = klass.call
    expect(result).not_to be_ok

    instance = result.__action__
    ctx = nil
    expect { ctx = instance.execution_context }.not_to raise_error
    expect(ctx).to be_a(Hash)
    expect(ctx[:inputs]).to eq({})
    expect(ctx).not_to have_key(:ambient_context)
  end
end

RSpec.describe "Axn ambient_context observability" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  let(:klass) do
    Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      expects :secret_id, on: :ambient_context, type: Integer, sensitive: true
      def call = nil
    end
  end

  it "puts sensitive-filtered ambient_context into execution_context, not raw values" do
    instance = klass.send(:new, ambient_context: { company_id: 3, secret_id: 9 })
    instance._run
    ctx = instance.execution_context
    expect(ctx[:ambient_context][:company_id]).to eq(3)
    expect(ctx[:ambient_context][:secret_id]).to eq("[FILTERED]")
  end

  it "keeps ambient_context out of inputs" do
    instance = klass.send(:new, ambient_context: { company_id: 3, secret_id: 9 })
    instance._run
    expect(instance.inputs).not_to have_key(:ambient_context)
  end

  it "filters a dynamically-sensitive ambient subfield in execution_context" do
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      expects :secret_id, on: :ambient_context, type: Integer, sensitive: -> { true }
      def call = nil
    end
    instance = klass.send(:new, ambient_context: { company_id: 3, secret_id: 9 })
    instance._run
    ctx = instance.execution_context
    expect(ctx[:ambient_context][:company_id]).to eq(3)
    expect(ctx[:ambient_context][:secret_id]).to eq("[FILTERED]")
  end
end
