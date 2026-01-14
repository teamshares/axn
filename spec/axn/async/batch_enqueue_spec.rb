# frozen_string_literal: true

RSpec.describe "Axn::Async::BatchEnqueue" do
  # Mock model class for testing
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

        def active
          all.select(&:active?)
        end
      end

      attr_reader :id, :name, :active

      def initialize(id:, name:, active: true)
        @id = id
        @name = name
        @active = active
      end

      def active? = @active
    end
  end

  let!(:user_class) do
    Class.new do
      class << self
        attr_accessor :_records

        def all
          _records || []
        end

        def find_each(&block)
          all.each(&block)
        end

        def active
          all.select(&:active?)
        end
      end

      attr_reader :id, :name, :active

      def initialize(id:, name:, active: true)
        @id = id
        @name = name
        @active = active
      end

      def active? = @active
    end
  end

  before do
    company_class._records = [
      company_class.new(id: 1, name: "Company A"),
      company_class.new(id: 2, name: "Company B"),
      company_class.new(id: 3, name: "Company C", active: false),
    ]

    user_class._records = [
      user_class.new(id: 10, name: "User X"),
      user_class.new(id: 20, name: "User Y"),
    ]
  end

  # Helper to stub enqueue_for to execute synchronously (bypass call_async flow)
  # This avoids issues with anonymous classes not having a name to constantize
  def with_synchronous_enqueue_all
    allow(Axn::Async::EnqueueAllTrigger).to receive(:enqueue_for).and_wrap_original do |_method, target, **static_args|
      # Validate async configured
      unless target._async_adapter.present? && target._async_adapter != false
        raise NotImplementedError,
              "#{target.name || "Anonymous class"} does not have async configured."
      end

      # Handle no-expects case
      return target.call_async(**static_args) if target.internal_field_configs.empty?

      # Use the real _resolve_configs method to get configs (including inference)
      configs = Axn::Async::EnqueueAllTrigger.send(:_resolve_configs, target)

      # Validate static args
      Axn::Async::EnqueueAllTrigger.send(:_validate_static_args!, target, configs, static_args)

      # Execute iteration synchronously
      Axn::Async::EnqueueAllTrigger.execute_iteration(target, **static_args)
    end
  end

  # Helper to mark action as having async configured (for validation)
  def enable_async_on(action_class)
    action_class._async_adapter = :fake
  end

  describe "enqueue_all is defined on all Axn classes" do
    it "is available even without enqueue_each" do
      action_class = build_axn do
        def call; end
      end

      expect(action_class).to respond_to(:enqueue_all)
    end
  end

  describe "single field iteration" do
    describe "with explicit from:" do
      let(:action_class) do
        cc = company_class
        build_axn do
          expects :company, type: cc

          define_method(:call) { "processed #{company.name}" }

          enqueue_each :company, from: -> { cc.all }
        end.tap { |klass| enable_async_on(klass) }
      end

      before { with_synchronous_enqueue_all }

      it "enqueues each item via call_async" do
        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        action_class.enqueue_all

        expect(enqueued).to contain_exactly(
          { company: company_class._records[0] },
          { company: company_class._records[1] },
          { company: company_class._records[2] },
        )
      end
    end

    describe "with model inference (from: omitted)" do
      let(:action_class) do
        cc = company_class
        stub_const("Company", cc)

        build_axn do
          expects :company, model: Company

          define_method(:call) { "processed #{company.name}" }

          enqueue_each :company
        end.tap { |klass| enable_async_on(klass) }
      end

      before { with_synchronous_enqueue_all }

      it "infers source from model class" do
        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        action_class.enqueue_all

        expect(enqueued.length).to eq(3)
      end
    end

    describe "with method name source" do
      let(:action_class) do
        cc = company_class
        build_axn do
          expects :company, type: cc

          define_method(:call) { "processed #{company.name}" }

          enqueue_each :company, from: :active_companies
        end.tap do |klass|
          klass.define_singleton_method(:active_companies) { cc.active }
          enable_async_on(klass)
        end
      end

      before { with_synchronous_enqueue_all }

      it "calls the method to get source" do
        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        action_class.enqueue_all

        # Only active companies (2 of 3)
        expect(enqueued.length).to eq(2)
      end
    end
  end

  describe "via: extraction" do
    let(:action_class) do
      cc = company_class
      build_axn do
        expects :company_id

        define_method(:call) { "processed company_id: #{company_id}" }

        enqueue_each :company_id, from: -> { cc.all }, via: :id
      end.tap { |klass| enable_async_on(klass) }
    end

    before { with_synchronous_enqueue_all }

    it "extracts the specified attribute" do
      enqueued = []
      allow(action_class).to receive(:call_async) { |**args| enqueued << args }

      action_class.enqueue_all

      expect(enqueued).to contain_exactly(
        { company_id: 1 },
        { company_id: 2 },
        { company_id: 3 },
      )
    end
  end

  describe "filter block" do
    let(:action_class) do
      cc = company_class
      build_axn do
        expects :company, type: cc

        define_method(:call) { "processed #{company.name}" }

        enqueue_each :company, from: -> { cc.all }, &:active?
      end.tap { |klass| enable_async_on(klass) }
    end

    before { with_synchronous_enqueue_all }

    it "only enqueues items where filter returns truthy" do
      enqueued = []
      allow(action_class).to receive(:call_async) { |**args| enqueued << args }

      action_class.enqueue_all

      # Only active companies (2 of 3)
      expect(enqueued.length).to eq(2)
      expect(enqueued.map { |e| e[:company].name }).to contain_exactly("Company A", "Company B")
    end
  end

  describe "multi-field cross-product" do
    let(:action_class) do
      cc = company_class
      uc = user_class
      build_axn do
        expects :company, type: cc
        expects :user, type: uc

        define_method(:call) { "processed #{user.name} at #{company.name}" }

        enqueue_each :user, from: -> { uc.all }
        enqueue_each :company, from: -> { cc.active }
      end.tap { |klass| enable_async_on(klass) }
    end

    before { with_synchronous_enqueue_all }

    it "creates cross-product of all fields" do
      enqueued = []
      allow(action_class).to receive(:call_async) { |**args| enqueued << args }

      action_class.enqueue_all

      # 2 users × 2 active companies = 4 jobs
      expect(enqueued.length).to eq(4)
      expect(enqueued).to include(
        { user: user_class._records[0], company: company_class._records[0] },
        { user: user_class._records[0], company: company_class._records[1] },
        { user: user_class._records[1], company: company_class._records[0] },
        { user: user_class._records[1], company: company_class._records[1] },
      )
    end
  end

  describe "static fields" do
    let(:action_class) do
      cc = company_class
      build_axn do
        expects :company, type: cc
        expects :format

        define_method(:call) { "processed #{company.name} as #{format}" }

        enqueue_each :company, from: -> { cc.all }
      end.tap { |klass| enable_async_on(klass) }
    end

    before { with_synchronous_enqueue_all }

    it "passes static fields through to each enqueued job" do
      enqueued = []
      allow(action_class).to receive(:call_async) { |**args| enqueued << args }

      action_class.enqueue_all(format: :csv)

      expect(enqueued.length).to eq(3)
      expect(enqueued.all? { |e| e[:format] == :csv }).to be true
    end

    it "raises when required static field is missing" do
      expect do
        action_class.enqueue_all
      end.to raise_error(ArgumentError, /Missing required static field.*format/)
    end
  end

  describe "error handling" do
    describe "async not configured" do
      it "raises NotImplementedError" do
        action_class = build_axn do
          expects :company
          def call; end
          enqueue_each :company, from: -> { [] }
        end

        expect do
          action_class.enqueue_all
        end.to raise_error(NotImplementedError, /does not have async configured/)
      end
    end

    describe "no enqueue_each with expects (no model:)" do
      it "raises MissingEnqueueEachError with instructions" do
        action_class = build_axn do
          expects :company  # No model: declaration
          def call; end
          # No enqueue_each called
        end.tap { |klass| enable_async_on(klass) }

        expect do
          action_class.enqueue_all
        end.to raise_error(Axn::Async::MissingEnqueueEachError, /no enqueue_each configured/)
      end
    end

    describe "no enqueue_each but has model: with find_each" do
      it "infers enqueue_each from model: declarations" do
        cc = company_class
        action_class = build_axn do
          expects :company, model: cc  # model: with find_each
          def call; end
          # No explicit enqueue_each - should be inferred
        end.tap { |klass| enable_async_on(klass) }

        with_synchronous_enqueue_all

        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        action_class.enqueue_all

        # Should have iterated over all 3 companies
        expect(enqueued.length).to eq(3)
      end
    end

    describe "no expects at all" do
      it "just calls call_async directly" do
        action_class = build_axn do
          def call; end
        end.tap { |klass| enable_async_on(klass) }

        expect(action_class).to receive(:call_async).with(no_args)
        action_class.enqueue_all
      end
    end

    describe "no from: and no model" do
      it "raises helpful error" do
        action_class = build_axn do
          expects :company # No model:

          def call; end

          enqueue_each :company # No from:
        end.tap { |klass| enable_async_on(klass) }

        with_synchronous_enqueue_all

        expect do
          action_class.enqueue_all
        end.to raise_error(ArgumentError, /requires `from:` option or a `model:` declaration/)
      end
    end
  end

  describe "iteration method selection" do
    describe "with find_each available (ActiveRecord-like)" do
      it "uses find_each when available" do
        cc = company_class
        action_class = build_axn do
          expects :company, type: cc
          def call; end
          enqueue_each :company, from: -> { cc }
        end.tap { |klass| enable_async_on(klass) }

        with_synchronous_enqueue_all
        allow(action_class).to receive(:call_async)

        expect(company_class).to receive(:find_each).and_call_original

        action_class.enqueue_all
      end
    end

    describe "without find_each (array-like)" do
      let(:action_class) do
        items = [1, 2, 3]
        build_axn do
          expects :number
          def call; end
          enqueue_each :number, from: -> { items }
        end.tap { |klass| enable_async_on(klass) }
      end

      before { with_synchronous_enqueue_all }

      it "falls back to each" do
        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        action_class.enqueue_all

        expect(enqueued).to eq([{ number: 1 }, { number: 2 }, { number: 3 }])
      end
    end
  end
end
