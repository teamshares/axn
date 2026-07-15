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

  it "runs an ambient subfield whose only constraint is allow_blank: (no other validator)" do
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, allow_blank: true
      exposes :cid, allow_nil: true
      def call = expose(cid: company)
    end
    result = klass.call(ambient_context: { company: 42 })
    expect(result).to be_ok
    expect(result.cid).to eq(42)
    expect(klass.call).to be_ok # absent ambient value is tolerated
  end

  it "still allows a plain (non-dotted) on: :ambient_context subfield" do
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, type: Integer
    end
    expect(klass).to be_a(Class)
  end

  it "does NOT reject a non-ambient nested subfield chain, and resolves it at runtime" do
    klass = Class.new do
      include Axn
      expects :addr, type: Hash
      expects :zip, on: :addr, type: String
      def call = nil
    end

    ok = klass.call(addr: { zip: "12345" })
    expect(ok).to be_ok

    bad = klass.call(addr: { zip: 5 })
    expect(bad).not_to be_ok
  end

  it "still allows a dotted subfield name on a NON-ambient parent, and resolves it via deep extraction" do
    klass = Class.new do
      include Axn
      expects :foo, type: Hash
      expects "bar.baz", on: :foo, type: String
    end

    # If resolution were broken (always nil, as it would be for the ambient case), this would fail
    # type validation -- so a successful call here proves the nested value was actually read.
    ok = klass.call(foo: { bar: { baz: "v" } })
    expect(ok).to be_ok

    bad = klass.call(foo: { bar: { baz: 5 } })
    expect(bad).not_to be_ok
  end
end

RSpec.describe "Axn deeply nested ambient_context (PRO-2909)" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  describe "form 1: a dotted `on:` path rooted at ambient_context" do
    let(:klass) do
      Class.new do
        include Axn
        expects :session, on: "ambient_context.request", type: String
        exposes :sess
        def call = expose(sess: session)
      end
    end

    it "declares without error and resolves from an explicit kwarg" do
      result = klass.call(ambient_context: { request: { session: "abc" } })
      expect(result).to be_ok
      expect(result.sess).to eq("abc")
    end

    it "resolves from the configured provider" do
      with_ambient_context(request: { session: "xyz" }) do
        result = klass.call
        expect(result).to be_ok
        expect(result.sess).to eq("xyz")
      end
    end
  end

  describe "form 2: a dotted subfield NAME on an ambient_context parent" do
    it "declares without error and validates the nested value (no reader)" do
      klass = Class.new do
        include Axn
        expects "request.ip", on: :ambient_context, type: String
        def call = nil
      end
      expect(klass.call(ambient_context: { request: { ip: "1.2.3.4" } })).to be_ok
      expect(klass.call(ambient_context: { request: { ip: 5 } })).not_to be_ok
    end

    it "resolves the aliased nested value via its reader" do
      klass = Class.new do
        include Axn
        expects "request.ip", on: :ambient_context, type: String, as: :ip
        exposes :the_ip
        def call = expose(the_ip: ip)
      end
      result = klass.call(ambient_context: { request: { ip: "1.2.3.4" } })
      expect(result).to be_ok
      expect(result.the_ip).to eq("1.2.3.4")
    end
  end

  describe "form 3: a subfield nested UNDER an ambient_context subfield" do
    let(:klass) do
      Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash
        expects :ip, on: :request, type: String
        exposes :the_ip, :the_request
        def call = expose(the_ip: ip, the_request: request)
      end
    end

    it "declares without error and resolves the nested leaf (explicit + provider)" do
      result = klass.call(ambient_context: { request: { ip: "1.2.3.4" } })
      expect(result).to be_ok
      expect(result.the_ip).to eq("1.2.3.4")

      with_ambient_context(request: { ip: "5.6.7.8" }) do
        expect(klass.call.the_ip).to eq("5.6.7.8")
      end
    end

    it "resolves two levels deep" do
      klass2 = Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash
        expects :headers, on: :request, type: Hash
        expects :auth, on: :headers, type: String
        exposes :the_auth
        def call = expose(the_auth: auth)
      end
      result = klass2.call(ambient_context: { request: { headers: { auth: "Bearer x" } } })
      expect(result).to be_ok
      expect(result.the_auth).to eq("Bearer x")
    end
  end

  describe "leak prevention: only declared leaves survive, never a whole sub-hash" do
    let(:klass) do
      Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash
        expects :ip, on: :request, type: String
        exposes :the_request
        def call = expose(the_request: request)
      end
    end

    it "strips an undeclared sibling key at depth from the resolved value" do
      result = klass.call(ambient_context: { request: { ip: "1.2.3.4", token: "secret" } })
      expect(result).to be_ok
      expect(result.the_request).to eq(ip: "1.2.3.4")
      expect(result.the_request).not_to have_key(:token)
    end

    it "keeps the undeclared sibling out of execution_context" do
      inst = klass.send(:new, ambient_context: { request: { ip: "1.2.3.4", token: "secret" } })
      inst._run
      ambient = inst.execution_context[:ambient_context]
      expect(ambient[:request]).to eq(ip: "1.2.3.4")
      expect(ambient[:request]).not_to have_key(:token)
    end

    it "strips an undeclared top-level ambient key too" do
      result = klass.call(ambient_context: { request: { ip: "1.2.3.4" }, other: "leak" })
      expect(result).to be_ok
      inst = klass.send(:new, ambient_context: { request: { ip: "1.2.3.4" }, other: "leak" })
      inst._run
      expect(inst.execution_context[:ambient_context]).not_to have_key(:other)
    end
  end

  describe "a model ambient subfield that also has descendants" do
    let(:company_klass) do
      Class.new do
        def self.find(id) = new(id)
        def initialize(id) = (@id = id)
        attr_reader :id

        def name = "Acme"
      end
    end

    let(:klass) do
      kls = company_klass
      Class.new do
        include Axn
        expects :company, on: :ambient_context, model: { klass: kls, finder: :find }
        expects :name, on: :company, type: String, method_call: true
        exposes :cname
        def call = expose(cname: name)
      end
    end

    it "resolves the model from an id-only ambient supply (id not stripped by the child branch)" do
      result = klass.call(ambient_context: { company_id: 7 })
      expect(result).to be_ok
      expect(result.cname).to eq("Acme")
    end
  end

  describe "an undeclared (implicit) intermediate supplied as a non-hash does not leak" do
    let(:klass) do
      Class.new do
        include Axn
        # `request` is never declared — only `session` beneath it is, so `request` is an implicit
        # path segment with no validator of its own.
        expects :session, on: "ambient_context.request", type: String, allow_nil: true
        def call = nil
      end
    end

    it "keeps the raw non-hash intermediate out of execution_context" do
      inst = klass.send(:new, ambient_context: { request: "secret" })
      inst._run
      expect(inst.execution_context).not_to have_key(:ambient_context)
    end
  end

  describe "shape blocks are rejected on ambient subfields (nest via subfields instead)" do
    it "rejects a shape block on the ambient parent" do
      expect do
        Class.new do
          include Axn
          expects :request, on: :ambient_context, type: Hash do
            field :ip, type: String
          end
        end
      end.to raise_error(ArgumentError, /shape.*not supported on an `on: :ambient_context`|subfields instead/)
    end

    it "rejects a shape block on a nested ambient subfield" do
      expect do
        Class.new do
          include Axn
          expects :request, on: :ambient_context, type: Hash
          expects :headers, on: :request, type: Hash do
            field :auth, type: String
          end
        end
      end.to raise_error(ArgumentError, /shape.*not supported on an `on: :ambient_context`|subfields instead/)
    end

    it "still allows the equivalent nested structure declared as subfields" do
      klass = Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash
        expects :ip, on: :request, type: String
        exposes :the_ip
        def call = expose(the_ip: ip)
      end
      expect(klass.call(ambient_context: { request: { ip: "1.2.3.4" } }).the_ip).to eq("1.2.3.4")
    end
  end

  describe "contradiction checks run for the ambient subtree (parity with non-ambient)" do
    it "rejects a nested ambient contract whose parent type can never answer a required child" do
      expect do
        Class.new do
          include Axn
          expects :request, on: :ambient_context, type: String
          expects :ip, on: :request, type: String
        end
      end.to raise_error(ArgumentError, /can never resolve|cannot answer/)
    end

    it "rejects a nil-tolerant ambient parent with an unrescued required nested child" do
      expect do
        Class.new do
          include Axn
          expects :request, on: :ambient_context, type: Hash, allow_nil: true
          expects :ip, on: :request, type: String
        end
      end.to raise_error(ArgumentError, /nil-tolerant|never be exercised/)
    end

    it "still allows a valid nested ambient contract (Hash parent, required child)" do
      klass = Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash
        expects :ip, on: :request, type: String
      end
      expect(klass).to be_a(Class)
    end
  end

  describe "malformed intermediate: a non-hash parent value is not masked" do
    let(:klass) do
      Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash
        expects :ip, on: :request, type: String
        def call = nil
      end
    end

    it "surfaces the parent type error rather than reconstructing it to {}" do
      result = klass.call(ambient_context: { request: "notahash" })
      expect(result).not_to be_ok
    end
  end

  describe "sensitive: composes down the declared path" do
    it "filters a sensitive nested leaf in execution_context" do
      klass = Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash
        expects :ip, on: :request, type: String, sensitive: true
        def call = nil
      end
      inst = klass.send(:new, ambient_context: { request: { ip: "1.2.3.4" } })
      inst._run
      expect(inst.execution_context[:ambient_context][:request][:ip]).to eq("[FILTERED]")
    end

    it "filters a sensitive ancestor (the whole reconstructed sub-hash) in execution_context" do
      klass = Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash, sensitive: true
        expects :ip, on: :request, type: String
        def call = nil
      end
      inst = klass.send(:new, ambient_context: { request: { ip: "1.2.3.4" } })
      inst._run
      expect(inst.execution_context[:ambient_context][:request]).to eq("[FILTERED]")
    end

    it "filters a nested model: subfield's generated <field>_id at depth" do
      company_klass = Class.new do
        def self.find(_id) = new
        def id = 42
      end
      klass = Class.new do
        include Axn
        expects :request, on: :ambient_context, type: Hash
        expects :company, on: :request, model: { klass: company_klass, finder: :find }, sensitive: true
        def call = nil
      end
      inst = klass.send(:new, ambient_context: { request: { company_id: 42 } })
      inst._run
      expect(inst.execution_context[:ambient_context][:request][:company_id]).to eq("[FILTERED]")
    end
  end

  describe "retained guards still fire on a nested ambient subfield" do
    it "rejects default: on a subfield nested under ambient_context" do
      expect do
        Class.new do
          include Axn
          expects :request, on: :ambient_context, type: Hash
          expects :ip, on: :request, default: "0.0.0.0"
        end
      end.to raise_error(ArgumentError, /default/)
    end

    it "rejects preprocess: on a subfield nested under ambient_context" do
      expect do
        Class.new do
          include Axn
          expects :request, on: :ambient_context, type: Hash
          expects :ip, on: :request, preprocess: ->(v) { v }
        end
      end.to raise_error(ArgumentError, /preprocess/)
    end

    it "rejects coerce: on a subfield nested under ambient_context" do
      expect do
        Class.new do
          include Axn
          expects :request, on: :ambient_context, type: Hash
          expects :ip, on: :request, type: Integer, coerce: true
        end
      end.to raise_error(ArgumentError, /coerce/)
    end

    it "rejects default: on a dotted `on:` path rooted at ambient_context" do
      expect do
        Class.new do
          include Axn
          expects :session, on: "ambient_context.request", default: "x"
        end
      end.to raise_error(ArgumentError, /default/)
    end
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

  it "reconstructs a nested declared leaf and drops undeclared siblings at every depth" do
    klass = Class.new do
      include Axn
      expects :request, on: :ambient_context, type: Hash
      expects :ip, on: :request, type: String
    end
    inst = klass.send(:new)
    filtered = inst.send(:_filter_to_declared, { request: { ip: "1.2.3.4", token: "secret" }, other: "leak" })
    expect(filtered).to eq(request: { ip: "1.2.3.4" })
  end

  it "omits an intermediate whose source branch is absent" do
    klass = Class.new do
      include Axn
      expects :request, on: :ambient_context, type: Hash
      expects :ip, on: :request, type: String
    end
    inst = klass.send(:new)
    expect(inst.send(:_filter_to_declared, { unrelated: 1 })).to eq({})
  end

  it "copies a non-hash DECLARED intermediate value raw so its own validation can catch it" do
    klass = Class.new do
      include Axn
      expects :request, on: :ambient_context, type: Hash
      expects :ip, on: :request, type: String
    end
    inst = klass.send(:new)
    expect(inst.send(:_filter_to_declared, { request: "notahash" })).to eq(request: "notahash")
  end

  it "omits a non-hash IMPLICIT intermediate (undeclared segment — nothing to validate, would only leak)" do
    klass = Class.new do
      include Axn
      expects :session, on: "ambient_context.request", type: String, allow_nil: true
    end
    inst = klass.send(:new)
    expect(inst.send(:_filter_to_declared, { request: "secret" })).to eq({})
  end

  it "preserves a model parent's <field>_id even when it has declared descendants" do
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, model: { klass: Struct.new(:id), finder: :find }
      expects :name, on: :company, type: String, method_call: true
    end
    inst = klass.send(:new)
    expect(inst.send(:_filter_to_declared, { company_id: 7 })).to eq(company_id: 7)
  end

  it "reconstructs a dotted-`on:` nested leaf" do
    klass = Class.new do
      include Axn
      expects :session, on: "ambient_context.request", type: String
    end
    inst = klass.send(:new)
    filtered = inst.send(:_filter_to_declared, { request: { session: "abc", extra: "x" } })
    expect(filtered).to eq(request: { session: "abc" })
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

  # A sensitive `model:` ambient subfield resolves from `<field>_id`, and `_filter_to_declared`
  # preserves that id key in the resolved ambient hash (see the `#_filter_to_declared` spec above).
  # `_static_sensitive_fields`/`_resolve_sensitive_fields` are keyed on the declared field NAME
  # (`:company`), so the ParameterFilter redacted `company` but let the raw `company_id` id leak
  # into execution_context/on_exception — a P1 leak for a supposedly-sensitive record reference.
  it "redacts the generated <field>_id alias for a sensitive model: ambient subfield (P1 leak)" do
    company_klass = Class.new do
      def self.find(_id) = new
      def id = 42
    end
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, model: { klass: company_klass, finder: :find }, sensitive: true
      def call = nil
    end
    inst = klass.send(:new, ambient_context: { company_id: 42 })
    inst._run
    expect(inst.execution_context[:ambient_context][:company_id]).to eq("[FILTERED]")
  end
end
