# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Tools::AdapterSerialization do
  # Mirrors spec/axn/tools/adapter_roots_spec.rb's `build_source`: an anonymous module doing exactly
  # what a real adapter's entry file does. `config_namespace` is left at its default (the module
  # itself) — unique per `Module.new`, so no example needs to pick a namespace name.
  def build_adapter(default: false)
    Module.new do
      extend Axn::Configurable
      extend Axn::Tools::AdapterSerialization
      declare_reject_opaque_exposed_values!(default:)
    end
  end

  # An object with no own as_json/to_h, and #to_s owned by Object — matches
  # spec/axn/extensions/serialization_spec.rb's helper. `respond_to?` is overridden rather than left
  # to chance: another spec file's `require "globalid"` adds a generic Object#as_json process-wide.
  def opaque_object
    Object.new.tap do |o|
      def o.respond_to?(name, *args)
        return false if %i[as_json to_h].include?(name)

        super
      end
    end
  end

  def build_opaque_tool
    owner = opaque_object
    Class.new do
      include Axn
      auto_log false
      exposes :owner
      define_method(:call) { expose(owner:) }
    end
  end

  describe ".declare_reject_opaque_exposed_values!" do
    it "takes the supplied default (false)" do
      expect(build_adapter(default: false).config.reject_opaque_exposed_values).to be(false)
    end

    it "takes the supplied default (true)" do
      expect(build_adapter(default: true).config.reject_opaque_exposed_values).to be(true)
    end

    it "requires default: (a missing kwarg is an ArgumentError)" do
      expect do
        Module.new do
          extend Axn::Configurable
          extend Axn::Tools::AdapterSerialization
          declare_reject_opaque_exposed_values!
        end
      end.to raise_error(ArgumentError, /default/)
    end

    it "rejects a non-boolean literal default EAGERLY, at declaration (Codex #259, P2)" do
      # A String "false" is truthy in Ruby, so an unchecked literal default would silently flip
      # serialize_exposed's reject_opaque: to "on" for every tool -- the opposite of author intent --
      # with no raise anywhere until someone noticed the wrong behavior downstream.
      expect do
        Module.new do
          extend Axn::Configurable
          extend Axn::Tools::AdapterSerialization
          declare_reject_opaque_exposed_values!(default: "false")
        end
      end.to raise_error(ArgumentError, /must be true or false/)
    end

    it "rejects a non-boolean value" do
      adapter = build_adapter(default: false)
      expect { adapter.config.reject_opaque_exposed_values = "yes" }
        .to raise_error(ArgumentError, /must be one of/)
    end

    it "is overridable per class via configure(:ns)" do
      adapter = build_adapter(default: false)
      klass = Class.new { include Axn }
      klass.include(adapter.overrides)

      klass.configure(adapter.config_namespace) { |c| c.reject_opaque_exposed_values = true }

      expect(adapter.resolve_override_for(klass, :reject_opaque_exposed_values)).to be(true)
    end
  end

  describe ".serialize_exposed" do
    it "renders the opaque value by default (false)" do
      adapter = build_adapter(default: false)
      tool = build_opaque_tool
      result = tool.call

      expect(adapter.serialize_exposed(result)["owner"]).to match(/\A#<Object:0x[0-9a-f]+>\z/)
    end

    it "raises when the gem-wide default is true" do
      adapter = build_adapter(default: true)
      tool = build_opaque_tool
      result = tool.call

      expect { adapter.serialize_exposed(result) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`owner`/)
    end

    it "resolves a per-tool override over the gem-wide default (true beats gem-wide false)" do
      adapter = build_adapter(default: false)
      tool = build_opaque_tool
      tool.include(adapter.overrides)
      tool.configure(adapter.config_namespace) { |c| c.reject_opaque_exposed_values = true }

      expect { adapter.serialize_exposed(tool.call) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
    end

    it "resolves a per-tool override over the gem-wide default (false beats gem-wide true)" do
      adapter = build_adapter(default: true)
      tool = build_opaque_tool
      tool.include(adapter.overrides)
      tool.configure(adapter.config_namespace) { |c| c.reject_opaque_exposed_values = false }

      expect(adapter.serialize_exposed(tool.call)["owner"]).to match(/\A#<Object:0x[0-9a-f]+>\z/)
    end

    it "derives the axn class from the result, not from a class the caller might pass by mistake" do
      adapter = build_adapter(default: false)
      strict_tool = build_opaque_tool
      strict_tool.include(adapter.overrides)
      strict_tool.configure(adapter.config_namespace) { |c| c.reject_opaque_exposed_values = true }

      lenient_tool = build_opaque_tool
      # lenient_tool never configured `adapter` at all -- resolves to the gem-wide default (false).

      # serialize_exposed takes only a result, so there is no argument through which a caller could
      # accidentally resolve strict_tool's override while rendering lenient_tool's result.
      expect(adapter.serialize_exposed(lenient_tool.call)["owner"]).to match(/\A#<Object:0x[0-9a-f]+>\z/)
    end

    it "resolves against the action's REAL class, not a dispatched #class an action instance could override (Codex #259, P2)" do
      # A hijacked #class pointing at a different tool's class would resolve THIS tool's
      # reject_opaque_exposed_values against that OTHER tool's setting instead of its own.
      adapter = build_adapter(default: false)

      lenient_tool = build_opaque_tool # never configures adapter -- resolves to the gem-wide false

      strict_tool = build_opaque_tool
      strict_tool.include(adapter.overrides)
      strict_tool.configure(adapter.config_namespace) { |c| c.reject_opaque_exposed_values = true }
      strict_tool.define_method(:class) { lenient_tool }

      expect { adapter.serialize_exposed(strict_tool.call) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
    end
  end

  describe ".guard_tool_response" do
    let(:adapter) { build_adapter(default: false) }
    let(:axn_class) { Class.new { include Axn } }

    it "returns the block's value untouched on success" do
      result = adapter.guard_tool_response(axn_class, on_error: ->(_e) { :should_not_happen }) { :mapped_value }
      expect(result).to eq(:mapped_value)
    end

    it "reports a StandardError via on_exception exactly once and returns on_error.call(e)" do
      reported = []
      allow(Axn.config).to receive(:on_exception) { |e, **| reported << e }

      result = adapter.guard_tool_response(axn_class, on_error: ->(e) { { error: e.message } }) { raise "boom" }

      expect(reported.size).to eq(1)
      expect(reported.first).to be_a(RuntimeError)
      expect(result).to eq(error: "boom")
    end

    it "guards a SystemStackError the same way as a StandardError" do
      reported = []
      allow(Axn.config).to receive(:on_exception) { |e, **| reported << e }

      result = adapter.guard_tool_response(axn_class, on_error: ->(_e) { :handled }) { raise SystemStackError, "stack" }

      expect(reported.first).to be_a(SystemStackError)
      expect(result).to eq(:handled)
    end

    it "guards a ScriptError the same way as a StandardError" do
      reported = []
      allow(Axn.config).to receive(:on_exception) { |e, **| reported << e }

      result = adapter.guard_tool_response(axn_class, on_error: ->(_e) { :handled }) { raise NotImplementedError, "nope" }

      expect(reported.first).to be_a(NotImplementedError)
      expect(result).to eq(:handled)
    end

    it "re-raises instead of calling on_error when raises_in_dev? is true" do
      allow(Axn::Extensions).to receive(:raises_in_dev?).and_return(true)

      expect do
        adapter.guard_tool_response(axn_class, on_error: ->(_e) { :should_not_happen }) { raise "dev boom" }
      end.to raise_error(RuntimeError, "dev boom")
    end

    it "surfaces the ORIGINAL mapping failure in dev even when the reporter is broken, and never calls it (Codex #259, P2)" do
      # The dev-loud check must run BEFORE reporting: reporting first would mean best_effort's own
      # dev-loud reraise fires on the REPORTER's exception (since the reporter raised inside a
      # best_effort block that is itself dev-loud), masking the actual mapping bug this guard exists
      # to expose. Checking raises_in_dev? first means the reporter is never even invoked on that path.
      allow(Axn::Extensions).to receive(:raises_in_dev?).and_return(true)
      reporter_calls = 0
      allow(Axn.config).to receive(:on_exception) do |*, **|
        reporter_calls += 1
        raise "reporter broken"
      end

      expect do
        adapter.guard_tool_response(axn_class, on_error: ->(_e) { :should_not_happen }) { raise "ORIGINAL mapping bug" }
      end.to raise_error(RuntimeError, "ORIGINAL mapping bug")

      expect(reporter_calls).to eq(0)
    end

    it "still calls on_error (outside dev) when the on_exception reporter itself raises" do
      allow(Axn.config).to receive(:on_exception).and_raise(RuntimeError, "reporter broken")

      result = adapter.guard_tool_response(axn_class, on_error: ->(_e) { :handled_despite_broken_reporter }) { raise "boom" }

      expect(result).to eq(:handled_despite_broken_reporter)
    end

    it "does not double-invoke a broken reporter for one mapping failure (Codex #259, P2)" do
      # best_effort's default report_ignored: true routes a reporter's OWN failure to
      # on_ignored_exception, which -- left at its default -- routes right back to the same
      # broken on_exception. Axn::Extensions.reporting? cannot catch this: while_reporting's
      # ensure already cleared the flag by the time the raise unwinds back out to this guard's
      # rescue, so an unguarded best_effort call here would invoke the broken reporter twice.
      calls = 0
      allow(Axn.config).to receive(:on_exception) do |*, **|
        calls += 1
        raise "reporter is broken"
      end

      adapter.guard_tool_response(axn_class, on_error: ->(_e) { :handled }) { raise "boom" }

      expect(calls).to eq(1)
    end

    it "reports (rather than silently swallowing) when on_error itself raises, then re-raises it (Codex #259, P2)" do
      reported = []
      allow(Axn.config).to receive(:on_exception) { |e, **| reported << e }

      expect do
        adapter.guard_tool_response(axn_class, on_error: ->(_e) { raise "on_error is broken" }) { raise "boom" }
      end.to raise_error(RuntimeError, "on_error is broken")

      expect(reported.map(&:message)).to eq(["boom", "on_error is broken"])
    end

    it "re-raises on_error's own failure through the safe reraise path, not a bare raise (Codex #259, P2)" do
      # A bare `raise` inside the rescue would re-raise $! -- but Ruby dispatches #exception even for
      # a zero-arg raise, so a class overriding it (adapter-authored on_error code, not trusted) could
      # substitute a different exception or mask the failure outright.
      hijacking = Class.new(StandardError) do
        def exception(*) = RuntimeError.new("HIJACKED")
      end

      expect do
        adapter.guard_tool_response(axn_class, on_error: ->(_e) { raise hijacking, "on_error broke" }) { raise "boom" }
      end.to raise_error(Axn::ReraiseFailed) { |e| expect(e.cause).to be_a(hijacking) }
    end

    it "does not double-report to a working reporter when on_error itself raises" do
      reported = []
      allow(Axn.config).to receive(:on_exception) { |e, **| reported << e }

      expect do
        adapter.guard_tool_response(axn_class, on_error: ->(_e) { raise "on_error is broken" }) { raise "boom" }
      end.to raise_error(RuntimeError)

      expect(reported.size).to eq(2) # the original mapping failure, and on_error's own failure -- never more
    end

    it "does not double-report when wrapping a mapping step over an already-settled failed Result" do
      failing_tool = Class.new do
        include Axn
        auto_log false
        def call = raise "action body boom"
      end

      reported = []
      allow(Axn.config).to receive(:on_exception) { |e, **| reported << e }

      result = failing_tool.call # core's own executor already reports this exception once
      expect(result.ok?).to be false
      expect(reported.size).to eq(1)

      # Correct usage: guard_tool_response wraps only the mapping step, which here just reads the
      # already-settled result and does not raise -- so it adds no second report.
      mapped = adapter.guard_tool_response(failing_tool, on_error: ->(_e) { :should_not_happen }) do
        result.ok? ? :ok : { error: result.error }
      end

      expect(mapped).to eq(error: result.error)
      expect(reported.size).to eq(1)
    end
  end
end
