# frozen_string_literal: true

require "spec_helper"

# `include Axn` must not silently shadow a `description`/`input_schema`/`output_schema` class method
# the including class already inherits from its own (non-Axn) base class. Ruby places extended modules
# above the superclass chain in the singleton method-resolution order, so axn's generic versions would
# otherwise win over an adapter base class's same-named-but-differently-scoped methods (PRO-2875).
RSpec.describe "Axn include does not shadow a pre-existing base-class class method" do
  # Stand-in for an adapter base class (e.g. ::MCP::Tool) that already owns these generic names.
  # The `raw_*` readers read the base's own storage directly, so a test can prove a value actually
  # reached the base rather than being silently diverted into axn's shadowing accessor.
  let(:base_class) do
    Class.new do
      class << self
        def description(value = :__unset__)
          value == :__unset__ ? @description : (@description = value)
        end

        def input_schema(value = :__unset__)
          value == :__unset__ ? @input_schema : (@input_schema = value)
        end

        def output_schema(value = :__unset__)
          value == :__unset__ ? @output_schema : (@output_schema = value)
        end

        def raw_description = @description
        def raw_input_schema = @input_schema
        def raw_output_schema = @output_schema
      end
    end
  end

  let(:tool_class) do
    Class.new(base_class) { include Axn }
  end

  it "leaves the base class's description reachable" do
    tool_class.description("LLM-facing text")
    expect(tool_class.description).to eq("LLM-facing text")
    expect(tool_class.raw_description).to eq("LLM-facing text")
  end

  it "leaves the base class's input_schema reachable" do
    tool_class.input_schema({ type: "object" })
    expect(tool_class.input_schema).to eq({ type: "object" })
    expect(tool_class.raw_input_schema).to eq({ type: "object" })
  end

  it "leaves the base class's output_schema reachable" do
    tool_class.output_schema({ type: "object" })
    expect(tool_class.output_schema).to eq({ type: "object" })
    expect(tool_class.raw_output_schema).to eq({ type: "object" })
  end

  it "still provides axn's other Naming DSL (axn_name/resolved_axn_name)" do
    tool_class.axn_name "custom"
    expect(tool_class.resolved_axn_name).to eq("custom")
  end

  it "leaves a debug breadcrumb for each name it defers on (discoverable, not silent)" do
    messages = []
    allow(Axn.config.logger).to receive(:debug) { |*args, &block| messages << (block ? block.call : args.first) }
    tool_class # trigger include Axn
    expect(messages).to include(
      a_string_matching(/skipping axn's class-level `description`/),
      a_string_matching(/skipping axn's reflected `input_schema`/),
      a_string_matching(/skipping axn's reflected `output_schema`/),
    )
  end

  it "still runs as an Axn (expects/exposes/call are intact)" do
    tool_class.class_eval do
      expects :x, type: Integer
      exposes :doubled, type: Integer
      def call = expose(doubled: x * 2)
    end
    expect(tool_class.call(x: 3).doubled).to eq(6)
  end

  it "defers to a same-class description defined before include Axn" do
    klass = Class.new do
      class << self
        def description(value = :__unset__)
          value == :__unset__ ? @description : (@description = value)
        end

        def raw_description = @description
      end
      include Axn
    end
    klass.description("mine")
    expect(klass.description).to eq("mine")
    expect(klass.raw_description).to eq("mine")
  end

  describe "a plain Axn (no external base) is unaffected" do
    let(:plain) do
      Class.new do
        include Axn
        expects :token, type: String, description: "secret"
        exposes :status, type: String
      end
    end

    it "still provides axn's class-level description DSL" do
      plain.description "does a thing"
      expect(plain.description).to eq("does a thing")
    end

    it "still provides axn's reflected input_schema" do
      expect(plain.input_schema[:properties][:token]).to include(type: "string", description: "secret")
    end

    it "still provides axn's reflected output_schema" do
      expect(plain.output_schema[:properties][:status]).to include(type: "string")
    end
  end
end
