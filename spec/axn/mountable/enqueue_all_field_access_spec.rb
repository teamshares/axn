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

  let!(:test_class) do
    cc = company_class
    Class.new do
      include Axn

      expects :company, model: cc

      def call
        "Processed company: #{company.name}"
      end

      enqueue_each :company, from: -> { cc.all }
    end
  end

  describe "main action call" do
    it "works correctly with field access" do
      result = test_class.call(company: company_class.all.first)
      expect(result).to be_ok
      expect(result.message).to eq("Action completed successfully")
    end
  end

  describe "enqueue_all call" do
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
      end

      enqueued = []
      allow(os_like_class).to receive(:call_async) { |**args| enqueued << args }

      result = os_like_class.enqueue_all
      expect(result).to eq(true)
      expect(enqueued.length).to eq(1)
    end
  end

  describe "the mounted action class" do
    it "has stripped field configurations (inherit: :async_only)" do
      # Get the mounted action class
      mounted_axn = test_class._mounted_axn_descriptors.first.mounted_axn_for(target: test_class)

      # The mounted action class should inherit from test_class but without fields
      expect(mounted_axn.superclass).to be_a(Class)
      expect(mounted_axn.superclass).to be < test_class

      # But it should have stripped field configurations (async_only mode)
      expect(mounted_axn.internal_field_configs).to be_empty
      expect(mounted_axn.external_field_configs).to be_empty

      # The original class should still have field configurations
      expect(test_class.internal_field_configs).not_to be_empty
      expect(test_class.internal_field_configs.any? { |config| config.field == :company }).to be true
    end
  end
end
