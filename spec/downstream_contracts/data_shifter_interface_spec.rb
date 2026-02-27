# frozen_string_literal: true

# =============================================================================
# DataShifter Interface Contract Spec
# =============================================================================
#
# This spec documents and tests the axn interface used by the data_shifter gem.
# Changes that break these specs require corresponding updates to data_shifter.
#
# data_shifter relies on:
# - Core: include Axn, expects with type/default
# - Hooks: around, before, on_success, on_error
# - Invocation: .call(**kwargs) returns Axn::Result
# - Result API: Result.ok, Result.error, result.ok?, result.exception
# - Failure handling: fail! raises Axn::Failure captured in result.exception
# =============================================================================

require "spec_helper"

RSpec.describe "DataShifter interface contract" do
  describe "Core action with expects" do
    let(:shift_action) do
      Class.new do
        include Axn

        expects :dry_run, type: :boolean, default: true

        def call
          @executed_with_dry_run = dry_run
        end
      end
    end

    it "includes Axn module" do
      expect(shift_action.ancestors).to include(Axn::Core)
    end

    it "supports expects with type: :boolean and default:" do
      result = shift_action.call
      expect(result).to be_ok
    end

    it "uses default value when argument not provided" do
      executed_dry_run = nil
      action = Class.new do
        include Axn
        expects :dry_run, type: :boolean, default: true

        define_method(:call) do
          executed_dry_run = dry_run
        end
      end

      action.call
      expect(executed_dry_run).to be true
    end

    it "allows overriding default value" do
      executed_dry_run = nil
      action = Class.new do
        include Axn
        expects :dry_run, type: :boolean, default: true

        define_method(:call) do
          executed_dry_run = dry_run
        end
      end

      action.call(dry_run: false)
      expect(executed_dry_run).to be false
    end
  end

  describe "Lifecycle hooks" do
    it "executes around hook wrapping call" do
      execution_order = []

      action = Class.new do
        include Axn

        around :wrap_execution

        define_method(:wrap_execution) do |chain|
          execution_order << :around_before
          chain.call
          execution_order << :around_after
        end

        define_method(:call) do
          execution_order << :call
        end
      end

      action.call
      expect(execution_order).to eq(%i[around_before call around_after])
    end

    it "executes before hook before call" do
      execution_order = []

      action = Class.new do
        include Axn

        before :setup

        define_method(:setup) do
          execution_order << :before
        end

        define_method(:call) do
          execution_order << :call
        end
      end

      action.call
      expect(execution_order).to eq(%i[before call])
    end

    it "executes on_success hook after successful call" do
      execution_order = []

      action = Class.new do
        include Axn

        on_success :print_summary

        define_method(:print_summary) do
          execution_order << :on_success
        end

        define_method(:call) do
          execution_order << :call
        end
      end

      action.call
      expect(execution_order).to eq(%i[call on_success])
    end

    it "executes on_error hook after failed call" do
      execution_order = []

      action = Class.new do
        include Axn

        on_error :print_summary

        define_method(:print_summary) do
          execution_order << :on_error
        end

        define_method(:call) do
          execution_order << :call
          fail! "something broke"
        end
      end

      action.call
      expect(execution_order).to eq(%i[call on_error])
    end

    it "does not execute on_success when call fails" do
      on_success_called = false

      action = Class.new do
        include Axn

        on_success :success_hook

        define_method(:success_hook) do
          on_success_called = true
        end

        define_method(:call) do
          fail! "error"
        end
      end

      action.call
      expect(on_success_called).to be false
    end

    it "does not execute on_error when call succeeds" do
      on_error_called = false

      action = Class.new do
        include Axn

        on_error :error_hook

        define_method(:error_hook) do
          on_error_called = true
        end

        define_method(:call) do
          # success
        end
      end

      action.call
      expect(on_error_called).to be false
    end
  end

  describe "Invocation returns Axn::Result" do
    it ".call returns Axn::Result" do
      action = Class.new do
        include Axn

        def call; end
      end

      result = action.call
      expect(result).to be_a(Axn::Result)
    end

    it ".call with kwargs returns Axn::Result" do
      action = Class.new do
        include Axn
        expects :dry_run, type: :boolean, default: true

        def call; end
      end

      result = action.call(dry_run: true)
      expect(result).to be_a(Axn::Result)

      result = action.call(dry_run: false)
      expect(result).to be_a(Axn::Result)
    end
  end

  describe "Result API" do
    describe "Axn::Result.ok" do
      it "creates a successful result with optional message" do
        result = Axn::Result.ok("done")
        expect(result).to be_ok
        expect(result.success).to eq("done")
      end

      it "creates a successful result without message" do
        result = Axn::Result.ok
        expect(result).to be_ok
      end

      it "accepts exposures as keyword arguments" do
        result = Axn::Result.ok("done", value: 42)
        expect(result).to be_ok
        expect(result.value).to eq(42)
      end
    end

    describe "Axn::Result.error" do
      it "creates a failed result with message" do
        result = Axn::Result.error("something broke")
        expect(result).not_to be_ok
        expect(result.error).to eq("something broke")
      end

      it "sets exception on error result" do
        result = Axn::Result.error("something broke")
        expect(result.exception).to be_a(Axn::Failure)
      end
    end

    describe "result.ok?" do
      it "returns true for successful execution" do
        action = Class.new do
          include Axn

          def call; end
        end

        result = action.call
        expect(result.ok?).to be true
      end

      it "returns false for failed execution" do
        action = Class.new do
          include Axn

          def call
            fail! "error"
          end
        end

        result = action.call
        expect(result.ok?).to be false
      end
    end

    describe "result.exception" do
      it "is nil for successful execution" do
        action = Class.new do
          include Axn

          def call; end
        end

        result = action.call
        expect(result.exception).to be_nil
      end

      it "contains Axn::Failure for fail! calls" do
        action = Class.new do
          include Axn

          def call
            fail! "something broke"
          end
        end

        result = action.call
        expect(result.exception).to be_a(Axn::Failure)
        expect(result.exception.message).to eq("something broke")
      end

      it "contains the original exception for raised errors" do
        action = Class.new do
          include Axn

          def call
            raise ArgumentError, "bad argument"
          end
        end

        result = action.call
        expect(result.exception).to be_a(ArgumentError)
        expect(result.exception.message).to eq("bad argument")
      end

      it "can be re-raised by caller (run!-style behavior)" do
        action = Class.new do
          include Axn

          def call
            fail! "something broke"
          end
        end

        result = action.call

        expect { raise result.exception }.to raise_error(Axn::Failure, "something broke")
      end
    end
  end

  describe "Failure handling" do
    it "fail! raises Axn::Failure which is captured" do
      action = Class.new do
        include Axn

        def call
          fail! "processing failed"
        end
      end

      result = action.call
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::Failure)
    end

    it "Axn::Failure message is accessible" do
      action = Class.new do
        include Axn

        def call
          fail! "custom error message"
        end
      end

      result = action.call
      expect(result.exception.message).to eq("custom error message")
    end
  end

  describe "Hook execution order with around/before/on_success/on_error" do
    it "executes hooks in correct order: around(before) -> before -> call -> around(after) -> on_success" do
      execution_order = []

      action = Class.new do
        include Axn

        around :wrap
        before :setup
        on_success :finish

        define_method(:wrap) do |chain|
          execution_order << :around_before
          chain.call
          execution_order << :around_after
        end

        define_method(:setup) do
          execution_order << :before
        end

        define_method(:finish) do
          execution_order << :on_success
        end

        define_method(:call) do
          execution_order << :call
        end
      end

      action.call
      expect(execution_order).to eq(%i[around_before before call around_after on_success])
    end

    it "on_error is called when call fails (around post-yield skipped on exception)" do
      execution_order = []

      action = Class.new do
        include Axn

        around :wrap
        on_error :handle_error

        define_method(:wrap) do |chain|
          execution_order << :around_before
          chain.call
          execution_order << :around_after
        end

        define_method(:handle_error) do
          execution_order << :on_error
        end

        define_method(:call) do
          execution_order << :call
          fail! "error"
        end
      end

      action.call
      expect(execution_order).to eq(%i[around_before call on_error])
    end
  end
end
