# frozen_string_literal: true

RSpec.describe Axn::Tools::AdapterRoots do
  def build_source
    Module.new do
      extend Axn::Configurable
      extend Axn::Tools::AdapterRoots
    end
  end

  it "defaults tool_roots to an empty array" do
    expect(build_source.config.tool_roots).to eq([])
  end

  it "accepts a narrow list of string roots" do
    source = build_source
    source.config.tool_roots = %w[agent_tools actions/tools]
    expect(source.config.tool_roots).to eq(%w[agent_tools actions/tools])
  end

  it "rejects a non-array value" do
    expect { build_source.config.tool_roots = "agent_tools" }
      .to raise_error(ArgumentError, /must be an Array of Strings/)
  end

  it "rejects a non-string entry" do
    expect { build_source.config.tool_roots = [:agent_tools] }
      .to raise_error(ArgumentError, /must be an Array of Strings/)
  end

  it "rejects a broad entry (bare actions dir)" do
    expect { build_source.config.tool_roots = %w[actions] }
      .to raise_error(ArgumentError, /too broad/)
  end

  it "rejects a `..` traversal entry" do
    expect { build_source.config.tool_roots = %w[../secrets] }
      .to raise_error(ArgumentError, /too broad/)
  end

  describe ".tool_roots_default" do
    def build_source_with_default(default)
      Module.new do
        extend Axn::Configurable
        extend Axn::Tools::AdapterRoots
        tool_roots_default(default)
      end
    end

    it "sets the adapter's own default, replacing core's empty one" do
      expect(build_source_with_default(%w[agent_tools]).config.tool_roots).to eq(%w[agent_tools])
    end

    it "validates the default EAGERLY, at declaration, not at the first read" do
      expect { build_source_with_default(%w[app]) }
        .to raise_error(ArgumentError, /too broad/)
    end

    it "still lets an explicit assignment win over the adapter's default" do
      source = build_source_with_default(%w[agent_tools])
      source.config.tool_roots = %w[custom_tools]
      expect(source.config.tool_roots).to eq(%w[custom_tools])
    end

    it "still validates an explicit assignment with the same broad-path guard" do
      source = build_source_with_default(%w[agent_tools])
      expect { source.config.tool_roots = %w[actions] }
        .to raise_error(ArgumentError, /too broad/)
    end

    it "returns to the ADAPTER's default on reset, not core's []" do
      source = build_source_with_default(%w[agent_tools])
      source.config.tool_roots = %w[custom_tools]
      source.config.reset!(:tool_roots)
      expect(source.config.tool_roots).to eq(%w[agent_tools])
    end

    it "does not share one mutable default array across adapters, even when they pass the same object" do
      shared_default = %w[agent_tools]
      first = build_source_with_default(shared_default)
      second = build_source_with_default(shared_default)

      first.config.tool_roots << "mutated"

      expect(second.config.tool_roots).to eq(%w[agent_tools])
      expect(shared_default).to eq(%w[agent_tools])
    end

    it "detaches the stored default from the caller's own array (Codex #259, P1)" do
      caller_owned = %w[agent_tools]
      source = build_source_with_default(caller_owned)

      caller_owned << "actions" # a broad root, never validated against THIS array

      expect(source.config.tool_roots).to eq(%w[agent_tools])
    end

    it "detaches each element too, so mutating a caller-held string can't corrupt an already-declared default" do
      root = +"agent_tools"
      caller_owned = [root]
      source = build_source_with_default(caller_owned)

      root.replace("actions") # mutate the caller's own String object in place

      expect(source.config.tool_roots).to eq(%w[agent_tools])
    end

    it "detaches via a BOUND native String#-@, not dispatched, so a subclass can't fake detachment (Codex #259, P2)" do
      # A String subclass overriding -@ (and, adversarially, dup/freeze too) to return `self` would
      # make a dispatched `-entry` a no-op detachment: `entry.is_a?(String)` in validate! admits any
      # subclass, so this is reachable without any hostile bypass of the declared contract.
      evil_class = Class.new(String) do
        def -@ = self
        def dup = self
        def freeze = self
      end
      original = evil_class.new("agent_tools")
      source = build_source_with_default([original])

      original.replace("actions")

      expect(source.config.tool_roots).to eq(%w[agent_tools])
    end

    it "still lets an explicit assignment win after the default was detached" do
      source = build_source_with_default(%w[agent_tools])
      source.config.tool_roots = %w[custom_tools]
      expect(source.config.tool_roots).to eq(%w[custom_tools])
    end

    it "takes effect even when config.tool_roots was already read (and cached) beforehand (Codex #259, P2)" do
      # Config#_read caches a default into @values on first read. If something reads
      # config.tool_roots before tool_roots_default runs, replacing the Setting struct alone leaves
      # the STALE cached [] answering every subsequent read -- only reset!/an explicit assignment
      # would clear it. tool_roots_default must force the fresh default in directly.
      source = Module.new do
        extend Axn::Configurable
        extend Axn::Tools::AdapterRoots
      end

      source.config.tool_roots # cache the stale [] default before the adapter declares its own
      source.tool_roots_default(%w[agent_tools])

      expect(source.config.tool_roots).to eq(%w[agent_tools])
    end
  end
end
