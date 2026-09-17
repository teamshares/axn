# frozen_string_literal: true

RSpec.describe Axn::Validators::ValidateValidator do
  let(:allow_blank) { false }
  let(:allow_nil) { false }
  let(:validator) { ->(value) { "must be pretty big" unless value > 10 } }
  let(:action) do
    build_axn.tap do |klass|
      klass.expects :foo, validate: validator, allow_blank:, allow_nil:
    end
  end

  describe "custom validations" do
    context "when valid" do
      subject { action.call(foo: 20) }

      it { is_expected.to be_ok }
    end

    context "when invalid" do
      subject { action.call(foo: 10) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo must be pretty big")
      end
    end

    context "when validator raises" do
      let(:validator) { ->(_value) { raise "oops" } }

      subject { action.call(foo: 20) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo failed validation: oops")
      end
    end

    context "and allow_blank" do
      let(:allow_blank) { true }

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).to be_ok
      end
    end

    context "and allow_nil" do
      let(:allow_nil) { true }

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).not_to be_ok
      end
    end
  end

  describe "custom validations hash format" do
    let(:message) { nil }
    let(:action) do
      build_axn.tap do |klass|
        klass.expects :foo, validate: { with: validator, message: }, allow_blank:, allow_nil:
      end
    end

    context "when valid" do
      subject { action.call(foo: 20) }

      it { is_expected.to be_ok }
    end

    context "when invalid" do
      subject { action.call(foo: 5) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo must be pretty big")
      end
    end

    context "with custom message" do
      let(:validator) { ->(value) { "custom error" unless value > 10 } }

      it "uses custom message" do
        result = action.call(foo: 5)
        expect(result).not_to be_ok
        expect(result.exception.message).to eq("Foo custom error")
      end
    end

    context "and allow_blank" do
      let(:allow_blank) { true }

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).to be_ok
      end
    end
  end

  describe "misuse: a Hash without :with (e.g. ActiveModel validator keys)" do
    it "raises at declaration (not at call time) with an actionable message" do
      expect do
        build_axn { expects :color, validate: { inclusion: { in: %w[red green blue] } } }
      end.to raise_error(ArgumentError) do |e|
        expect(e.message).to include("validate:")
        expect(e.message).to include("with:")
        expect(e.message).to include("inclusion") # names the keys actually given
      end
    end

    it "still accepts the valid Hash form (with: present)" do
      expect do
        build_axn { expects :foo, validate: { with: ->(v) { "too small" unless v > 1 } } }
      end.not_to raise_error
    end

    it "still accepts the bare-callable form" do
      expect do
        build_axn { expects :foo, validate: ->(v) { "too small" unless v > 1 } }
      end.not_to raise_error
    end
  end

  describe "runs against the action (PRO-3380)" do
    it "self is the action instance" do
      seen = []
      action = build_axn do
        expects :foo, validate: lambda { |_value|
          seen << self
          nil
        }
      end

      action.call(foo: 1)
      expect(seen.first).to be_a(action)
    end

    it "reaches a sibling top-level field" do
      action = build_axn do
        expects :min, type: Integer
        expects :max, type: Integer, validate: ->(value) { "must be >= min" if value < min }
      end

      expect(action.call(min: 5, max: 9)).to be_ok
      result = action.call(min: 5, max: 1)
      expect(result).not_to be_ok
      expect(result.exception.message).to eq("Max must be >= min")
    end

    it "reaches a private action method" do
      action = build_axn do
        expects :n, type: Integer, validate: ->(value) { "must be allowed" unless allowed?(value) }

        private

        def allowed?(value) = value.even?
      end

      expect(action.call(n: 2)).to be_ok
      expect(action.call(n: 3)).not_to be_ok
    end

    it "reaches a sibling field through a subfield (on:)" do
      action = build_axn do
        expects :cap, type: Integer
        expects :payload, type: Hash
        expects :qty, on: :payload, type: Integer, validate: ->(value) { "over cap" if value > cap }
      end

      expect(action.call(cap: 3, payload: { qty: 2 })).to be_ok
      result = action.call(cap: 3, payload: { qty: 9 })
      expect(result).not_to be_ok
      expect(result.exception.message).to eq("Qty over cap")
    end

    it "reaches a sibling top-level field from an of: bag's contents" do
      action = build_axn do
        expects :limit, type: Integer
        expects :items, type: Array, of: { klass: Integer, validate: ->(value) { "over limit" if value > limit } }
      end

      expect(action.call(limit: 5, items: [1, 2])).to be_ok
      result = action.call(limit: 5, items: [1, 99])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1: over limit/)
    end

    it "reaches a sibling top-level field from a shape member" do
      action = build_axn do
        expects :prefix, type: String
        expects :order, type: Hash do
          field :sku, validate: ->(value) { "must start with prefix" unless value.to_s.start_with?(prefix) }
        end
      end

      expect(action.call(prefix: "TS-", order: { sku: "TS-1" })).to be_ok
      result = action.call(prefix: "TS-", order: { sku: "XX-1" })
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/must start with prefix/)
    end

    it "an outbound validate: reaches a sibling exposure via result, not a bare reader" do
      action = build_axn do
        exposes :a, type: Integer
        exposes :b, type: Integer, validate: ->(value) { "must be > a" unless value > result.a }

        def call = expose(a: 5, b: 1)
      end

      result = action.call
      expect(result).not_to be_ok
      expect(result.exception.message).to eq("B must be > a")
    end

    it "a lambda calling a class method (the pre-fix workaround) now fails loudly" do
      action = build_axn do
        def self.helper(value) = value.to_s

        expects :n, validate: ->(value) { "x" if helper(value).nil? }
      end

      result = action.call(n: 1)
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/undefined method [`']helper'/)
    end

    it "fail! inside a validate: lambda is absorbed into the field message" do
      action = build_axn do
        expects :n, validate: ->(_v) { fail! "boom" }
      end

      result = action.call(n: 1)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to eq("N failed validation: boom")
    end

    describe "Symbol form" do
      it "resolves a private action method, receiving the value" do
        action = build_axn do
          expects :limit, type: Integer
          expects :n, type: Integer, validate: :n_under_limit

          private

          def n_under_limit(value)
            "must be under limit" if value >= limit
          end
        end

        expect(action.call(limit: 10, n: 2)).to be_ok
        result = action.call(limit: 10, n: 11)
        expect(result).not_to be_ok
        expect(result.exception.message).to eq("N must be under limit")
      end

      it "fails the field when the named method does not exist" do
        action = build_axn do
          expects :n, validate: :does_not_exist
        end

        result = action.call(n: 1)
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/undefined method [`']does_not_exist'/)
      end
    end

    describe "controls that must keep behaving as before" do
      it "a #call-only object is still called directly, not instance_exec'd" do
        checker = Class.new do
          def call(value) = "obj saw #{value}"
        end.new

        action = build_axn { expects :n, validate: checker }

        result = action.call(n: 1)
        expect(result).not_to be_ok
        expect(result.exception.message).to eq("N obj saw 1")
      end

      it "a Method object keeps its own receiver" do
        checker = Class.new do
          def self.check(value) = "method saw #{value}"
        end
        method_obj = checker.method(:check)

        action = build_axn { expects :n, validate: method_obj }

        result = action.call(n: 1)
        expect(result).not_to be_ok
        expect(result.exception.message).to eq("N method saw 1")
      end

      it "a zero-arity lambda still raises an ArgumentError, absorbed into the field message" do
        action = build_axn { expects :n, validate: -> {} }

        result = action.call(n: 1)
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/failed validation: wrong number of arguments/)
      end
    end
  end

  describe "declaration-time callability guard (PRO-3380)" do
    it "refuses a non-callable, non-Symbol value" do
      expect do
        build_axn { expects :n, validate: 123 }
      end.to raise_error(ArgumentError, /validate:/)
    end

    it "refuses an empty Array" do
      expect do
        build_axn { expects :n, validate: [] }
      end.to raise_error(ArgumentError, /validate:/)
    end

    it "refuses a non-callable inside the Hash form's with:" do
      expect do
        build_axn { expects :n, validate: { with: 123 } }
      end.to raise_error(ArgumentError, /validate:/)
    end

    it "does not let a hostile respond_to? raise in place of the verdict" do
      hostile = Object.new
      def hostile.respond_to?(*) = raise "boom"
      def hostile.respond_to_missing?(*) = raise "boom"

      expect do
        build_axn { expects :n, validate: hostile }
      end.to raise_error(ArgumentError, /validate:/)
    end

    it "still accepts a Symbol" do
      expect do
        build_axn do
          expects :n, validate: :some_method

          private

          def some_method(_value) = nil
        end
      end.not_to raise_error
    end
  end

  describe "Axn::Extensions.best_effort integration" do
    let(:validator) { ->(_v) { raise ArgumentError, "fail message" } }

    before do
      allow(Axn::Extensions).to receive(:best_effort).and_call_original
    end

    it "calls Axn::Extensions.best_effort when custom validation raises" do
      result = action.call(foo: 1)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect_best_effort_called(message_substring: "applying custom validation")
    end

    # The fallback message names the real error, so failing the field stays accurate — and a validator
    # that blows the stack takes the same path as one raising ArgumentError.
    context "when the validator raises a non-StandardError" do
      let(:validator) { ->(_v) { raise SystemStackError } }

      it "still fails the field rather than settling as an exception outcome" do
        result = action.call(foo: 1)

        expect(result.exception).to be_a(Axn::InboundValidationError)
        expect(result.exception.message).to include("failed validation: SystemStackError")
      end
    end
  end
end
