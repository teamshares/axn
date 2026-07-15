# frozen_string_literal: true

require "spec_helper"

# Deep ambient nesting (PRO-2909) under real Rails: the downstream motivation is a naturally-nested
# ambient source (an MCP server_context, a REST request), which arrives with string keys /
# HashWithIndifferentAccess and may be supplied via ActiveSupport::CurrentAttributes. These exercise
# the indifferent-access path at depth that the non-Rails suite can't.
RSpec.describe "Axn deeply nested ambient_context under Rails (PRO-2909)" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  let(:klass) do
    Class.new do
      include Axn
      expects :request, on: :ambient_context, type: Hash
      expects :ip, on: :request, type: String
      exposes :the_ip, :the_request
      def call = expose(the_ip: ip, the_request: request)
    end
  end

  it "resolves a nested leaf from a HashWithIndifferentAccess with string keys" do
    ctx = ActiveSupport::HashWithIndifferentAccess.new("request" => { "ip" => "1.2.3.4", "token" => "secret" })
    result = klass.call(ambient_context: ctx)
    expect(result).to be_ok
    expect(result.the_ip).to eq("1.2.3.4")
    # The undeclared sibling is stripped even through indifferent access. Keys normalize to the
    # declared (symbol) wire keys, as the single-level filter has always done.
    expect(result.the_request).to eq(ip: "1.2.3.4")
    expect(result.the_request).not_to have_key(:token)
  end

  it "resolves from a CurrentAttributes-backed provider and filters undeclared keys" do
    current = Class.new(ActiveSupport::CurrentAttributes) { attribute :request }
    stub_const("DeepAmbientSpecCurrent", current)
    current.instance.request = { ip: "9.9.9.9", token: "secret" }

    Axn.config.ambient_context_provider = -> { Axn::Core::AmbientContext.default_source }
    result = klass.call
    expect(result).to be_ok
    expect(result.the_ip).to eq("9.9.9.9")
    expect(result.the_request).not_to have_key(:token)
  ensure
    current&.reset
  end

  it "keeps the undeclared nested key out of exception context" do
    ctx = ActiveSupport::HashWithIndifferentAccess.new("request" => { "ip" => "1.2.3.4", "token" => "secret" })
    inst = klass.send(:new, ambient_context: ctx)
    inst._run
    ambient = inst.execution_context[:ambient_context]
    expect(ambient[:request]).not_to have_key("token")
    expect(ambient[:request]).not_to have_key(:token)
  end
end
