# frozen_string_literal: true

RSpec.describe "Axn::Async::BatchEnqueue field access" do
  # This spec verifies that enqueue_each properly iterates and enqueues jobs

  let!(:company_class) do
    Class.new do
      class << self
        attr_accessor :_records

        def all
          _records || []
        end

        def find_each(&block)
          all.each(&block)
        end
      end

      attr_reader :name

      def initialize(name:)
        @name = name
      end
    end
  end

  before do
    company_class._records = [
      company_class.new(name: "Test Company"),
    ]
  end

  # Helper to mark action as having async configured
  def enable_async_on(action_class)
    action_class._async_adapter = :fake
  end

  # Helper to stub enqueue_for to execute synchronously
  def with_synchronous_enqueue_all
    allow(Axn::Async::EnqueueAllTrigger).to receive(:enqueue_for).and_wrap_original do |_method, target, **static_args|
      # Validate async configured
      raise NotImplementedError, "Async not configured" unless target._async_adapter.present? && target._async_adapter != false

      # Handle no-expects case
      return target.call_async(**static_args) if target.internal_field_configs.empty?

      # Use real _resolve_configs (includes inference) - now returns [configs, resolved_static]
      configs, resolved_static = Axn::Async::EnqueueAllTrigger.send(:_resolve_configs, target, static_args:)

      Axn::Async::EnqueueAllTrigger.send(:_validate_static_args!, target, configs, resolved_static) if configs.any?
      Axn::Async::EnqueueAllTrigger.execute_iteration(target, **static_args)
    end
  end

  let!(:test_class) do
    cc = company_class
    Class.new do
      include Axn

      expects :company, model: cc

      def call
        "Processed company: #{company.name}"
      end

      enqueue_each :company, from: -> { cc.all }
    end.tap { |klass| klass._async_adapter = :fake }
  end

  describe "main action call" do
    it "works correctly with field access" do
      result = test_class.call(company: company_class.all.first)
      expect(result).to be_ok
      expect(result.message).to eq("Action completed successfully")
    end
  end

  describe "enqueue_all call" do
    before { with_synchronous_enqueue_all }

    it "enqueues jobs for each company" do
      enqueued = []
      allow(test_class).to receive(:call_async) { |**args| enqueued << args }

      result = test_class.enqueue_all
      expect(result).to eq(true)
      expect(enqueued.length).to eq(1)
      expect(enqueued.first[:company].name).to eq("Test Company")
    end

    it "demonstrates the pattern from the OS app" do
      # This reproduces the exact scenario from the OS app:
      # - A class with expects :company, model: true
      # - An enqueue_each that iterates over companies
      cc = company_class

      os_like_class = Class.new do
        include Axn

        expects :company, model: cc

        def call
          "Processed company: #{company.name}"
        end

        enqueue_each :company, from: -> { cc.all }
      end.tap { |klass| klass._async_adapter = :fake }

      enqueued = []
      allow(os_like_class).to receive(:call_async) { |**args| enqueued << args }

      result = os_like_class.enqueue_all
      expect(result).to eq(true)
      expect(enqueued.length).to eq(1)
    end
  end

  describe "the shared EnqueueAllTrigger class" do
    it "has its own fixed field configurations (does not inherit parent expects)" do
      # The shared trigger has only target_class_name and static_args
      trigger = Axn::Async::EnqueueAllTrigger
      trigger_fields = trigger.internal_field_configs.map(&:field)

      expect(trigger_fields).to contain_exactly(:target_class_name, :static_args)
      expect(trigger_fields).not_to include(:company)

      # The original class should still have field configurations
      expect(test_class.internal_field_configs).not_to be_empty
      expect(test_class.internal_field_configs.any? { |config| config.field == :company }).to be true
    end
  end
end
