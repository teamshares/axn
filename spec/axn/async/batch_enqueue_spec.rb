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
    allow(Axn::Async::EnqueueAllOrchestrator).to receive(:enqueue_for).and_wrap_original do |_method, target, **static_args|
      # Validate async configured
      unless target._async_adapter.present? && target._async_adapter != false
        raise NotImplementedError,
              "#{target.name || 'Anonymous class'} does not have async configured."
      end

      # Handle no-expects case
      return target.call_async(**static_args) if target.internal_field_configs.empty?

      # Use the real resolve_configs method to get configs and resolved static args
      configs, resolved_static = Axn::Async::EnqueueAllOrchestrator.send(:resolve_configs, target, static_args:)

      # Validate static args
      Axn::Async::EnqueueAllOrchestrator.send(:validate_static_args!, target, configs, resolved_static) if configs.any?

      # Execute iteration synchronously
      Axn::Async::EnqueueAllOrchestrator.execute_iteration(target, **static_args)
    end
  end

  # Helper to mark action as having async configured (for validation)
  def enable_async_on(action_class)
    action_class._async_adapter = :fake
  end

  describe "enqueue_all is defined on all Axn classes" do
    it "is available even without enqueues_each" do
      action_class = build_axn do
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

          enqueues_each :company, from: -> { cc.all }
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

          enqueues_each :company
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

          enqueues_each :company, from: :active_companies
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

        enqueues_each :company_id, from: -> { cc.all }, via: :id
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

        enqueues_each :company, from: -> { cc.all }, &:active?
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

        enqueues_each :user, from: -> { uc.all }
        enqueues_each :company, from: -> { cc.active }
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

        enqueues_each :company, from: -> { cc.all }
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
          enqueues_each :company, from: -> { [] }
        end

        expect do
          action_class.enqueue_all
        end.to raise_error(NotImplementedError, /does not have async configured/)
      end
    end

    describe "no enqueues_each with expects (no model:)" do
      it "raises MissingEnqueuesEachError with instructions" do
        action_class = build_axn do
          expects :company # No model: declaration
          # No enqueues_each called
        end.tap { |klass| enable_async_on(klass) }

        expect do
          action_class.enqueue_all
        end.to raise_error(Axn::Async::MissingEnqueuesEachError, /not covered by enqueues_each/)
      end
    end

    describe "no enqueues_each but has model: with find_each" do
      it "infers enqueues_each from model: declarations" do
        cc = company_class
        action_class = build_axn do
          expects :company, model: cc # model: with find_each
          # No explicit enqueues_each - should be inferred
        end.tap { |klass| enable_async_on(klass) }

        with_synchronous_enqueue_all

        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        action_class.enqueue_all

        # Should have iterated over all 3 companies
        expect(enqueued.length).to eq(3)
      end
    end

    describe "multi-field: explicit config for one, inferred for another" do
      it "merges inferred and explicit configs" do
        cc = company_class
        uc = user_class
        action_class = build_axn do
          expects :company, model: cc
          expects :user, model: uc

          # Only explicit config for company with filter, user should be inferred
          enqueues_each :company, from: -> { cc.active }
        end.tap { |klass| enable_async_on(klass) }

        with_synchronous_enqueue_all

        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        action_class.enqueue_all

        # 2 active companies × 2 users = 4 jobs
        expect(enqueued.length).to eq(4)
        expect(enqueued.map { |e| e[:company].name }.uniq).to contain_exactly("Company A", "Company B")
        expect(enqueued.map { |e| e[:user].name }.uniq).to contain_exactly("User X", "User Y")
      end
    end

    describe "multi-field: explicit config for one, static arg for another" do
      it "uses static arg instead of inferring" do
        cc = company_class
        uc = user_class
        static_user = user_class._records.first

        action_class = build_axn do
          expects :company, model: cc
          expects :user, model: uc

          enqueues_each :company, from: -> { cc.active }
        end.tap { |klass| enable_async_on(klass) }

        with_synchronous_enqueue_all

        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        # Pass user as static arg - should not iterate over users
        action_class.enqueue_all(user: static_user)

        # 2 active companies × 1 static user = 2 jobs
        expect(enqueued.length).to eq(2)
        expect(enqueued.all? { |e| e[:user] == static_user }).to be true
      end
    end

    describe "no expects at all" do
      it "just calls call_async directly" do
        action_class = build_axn do
        end.tap { |klass| enable_async_on(klass) }

        expect(action_class).to receive(:call_async).with(no_args)
        action_class.enqueue_all
      end
    end

    describe "no from: and no model" do
      it "raises helpful error" do
        action_class = build_axn do
          expects :company # No model:

          enqueues_each :company # No from:
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
          enqueues_each :company, from: -> { cc }
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
          enqueues_each :number, from: -> { items }
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

  describe "unified kwarg iteration" do
    describe "scalar vs enumerable detection" do
      before { with_synchronous_enqueue_all }

      describe "boolean field with scalar" do
        let(:action_class) do
          build_axn do
            expects :enabled, type: :boolean
          end.tap { |klass| enable_async_on(klass) }
        end

        it "treats scalar boolean as static (enqueues once)" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          action_class.enqueue_all(enabled: true)

          expect(enqueued).to eq([{ enabled: true }])
        end
      end

      describe "boolean field with array" do
        let(:action_class) do
          build_axn do
            expects :enabled, type: :boolean
          end.tap { |klass| enable_async_on(klass) }
        end

        it "treats array as iterable (enqueues for each value)" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          action_class.enqueue_all(enabled: [true, false])

          expect(enqueued).to contain_exactly(
            { enabled: true },
            { enabled: false },
          )
        end
      end

      describe "multiple fields with mixed scalars and enumerables" do
        let(:action_class) do
          build_axn do
            expects :format
            expects :mode
            expects :priority
          end.tap { |klass| enable_async_on(klass) }
        end

        it "creates cross-product for enumerables, static for scalars" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          action_class.enqueue_all(
            format: %i[csv json], # iterate
            mode: :full,           # static
            priority: [1, 2],      # iterate
          )

          # 2 formats × 1 mode × 2 priorities = 4 jobs
          expect(enqueued.length).to eq(4)
          expect(enqueued).to contain_exactly(
            { format: :csv, mode: :full, priority: 1 },
            { format: :csv, mode: :full, priority: 2 },
            { format: :json, mode: :full, priority: 1 },
            { format: :json, mode: :full, priority: 2 },
          )
        end
      end
    end

    describe "field expects enumerable type" do
      before { with_synchronous_enqueue_all }

      describe "Array type" do
        let(:action_class) do
          build_axn do
            expects :tags, type: Array
          end.tap { |klass| enable_async_on(klass) }
        end

        it "treats array as static value (not iterated)" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          action_class.enqueue_all(tags: %w[a b c])

          # Should enqueue once with the entire array as the value
          expect(enqueued).to eq([{ tags: %w[a b c] }])
        end
      end

      describe "Set type" do
        let(:action_class) do
          build_axn do
            expects :ids, type: Set
          end.tap { |klass| enable_async_on(klass) }
        end

        it "treats set as static value (not iterated)" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          id_set = Set.new([1, 2, 3])
          action_class.enqueue_all(ids: id_set)

          expect(enqueued).to eq([{ ids: id_set }])
        end
      end
    end

    describe "string and hash are not iterated" do
      before { with_synchronous_enqueue_all }

      describe "string value" do
        let(:action_class) do
          build_axn do
            expects :name
          end.tap { |klass| enable_async_on(klass) }
        end

        it "treats string as static (even though it responds to :each)" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          action_class.enqueue_all(name: "test")

          expect(enqueued).to eq([{ name: "test" }])
        end
      end

      describe "hash value" do
        let(:action_class) do
          build_axn do
            expects :options
          end.tap { |klass| enable_async_on(klass) }
        end

        it "treats hash as static (even though it responds to :each)" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          action_class.enqueue_all(options: { foo: :bar })

          expect(enqueued).to eq([{ options: { foo: :bar } }])
        end
      end
    end

    describe "kwarg overrides explicit enqueues_each config" do
      before { with_synchronous_enqueue_all }

      describe "enumerable kwarg replaces configured source" do
        let(:action_class) do
          cc = company_class
          build_axn do
            expects :company, type: cc
            # Configured to iterate over all companies
            enqueues_each :company, from: -> { cc.all }
          end.tap { |klass| enable_async_on(klass) }
        end

        it "uses kwarg enumerable instead of configured source" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          # Override with only first 2 companies
          subset = company_class._records[0..1]
          action_class.enqueue_all(company: subset)

          expect(enqueued.length).to eq(2)
          expect(enqueued.map { |e| e[:company] }).to eq(subset)
        end
      end

      describe "scalar kwarg overrides configured iteration" do
        let(:action_class) do
          cc = company_class
          build_axn do
            expects :company, type: cc
            enqueues_each :company, from: -> { cc.all }
          end.tap { |klass| enable_async_on(klass) }
        end

        it "uses scalar as static instead of iterating" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          single_company = company_class._records.first
          action_class.enqueue_all(company: single_company)

          # Should enqueue once with the specific company (not iterate)
          expect(enqueued).to eq([{ company: single_company }])
        end
      end
    end

    describe "kwarg overrides inferred config" do
      before { with_synchronous_enqueue_all }

      describe "enumerable kwarg replaces inferred source" do
        let(:action_class) do
          cc = company_class
          build_axn do
            expects :company, model: cc
            # No enqueues_each - should be inferred from model:
          end.tap { |klass| enable_async_on(klass) }
        end

        it "uses kwarg enumerable instead of inferred Model.all" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          # Override with only active companies
          subset = company_class.active
          action_class.enqueue_all(company: subset)

          expect(enqueued.length).to eq(2) # Only active ones
        end
      end

      describe "scalar kwarg skips inferred iteration" do
        let(:action_class) do
          cc = company_class
          build_axn do
            expects :company, model: cc
          end.tap { |klass| enable_async_on(klass) }
        end

        it "uses scalar as static instead of inferring iteration" do
          enqueued = []
          allow(action_class).to receive(:call_async) { |**args| enqueued << args }

          single_company = company_class._records.first
          action_class.enqueue_all(company: single_company)

          expect(enqueued).to eq([{ company: single_company }])
        end
      end
    end

    describe "range iteration" do
      before { with_synchronous_enqueue_all }

      let(:action_class) do
        build_axn do
          expects :page_number
        end.tap { |klass| enable_async_on(klass) }
      end

      it "iterates over a range" do
        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        action_class.enqueue_all(page_number: 1..3)

        expect(enqueued).to contain_exactly(
          { page_number: 1 },
          { page_number: 2 },
          { page_number: 3 },
        )
      end
    end
  end

  describe "error handling" do
    before { with_synchronous_enqueue_all }

    describe "filter block exceptions" do
      let(:action_class) do
        build_axn do
          expects :number

          enqueues_each :number, from: -> { [1, 2, 3] } do |n|
            raise "filter exploded" if n == 2

            true
          end
        end.tap { |klass| enable_async_on(klass) }
      end

      it "swallows filter block errors and skips the item" do
        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        # Should not raise, should skip item 2
        action_class.enqueue_all

        expect(enqueued).to contain_exactly(
          { number: 1 },
          { number: 3 },
        )
      end

      it "logs the swallowed error via piping_error" do
        allow(action_class).to receive(:call_async)
        expect(Axn::Internal::PipingError).to receive(:swallow).with(
          "filter block for :number",
          exception: an_instance_of(RuntimeError),
        )

        action_class.enqueue_all
      end
    end

    describe "via extraction exceptions" do
      let(:action_class) do
        items = [
          Struct.new(:id).new(1),
          Struct.new(:name).new("no id"), # doesn't respond to :id
          Struct.new(:id).new(3),
        ]

        build_axn do
          expects :item_id

          enqueues_each :item_id, from: -> { items }, via: :id
        end.tap { |klass| enable_async_on(klass) }
      end

      it "swallows via extraction errors and skips the item" do
        enqueued = []
        allow(action_class).to receive(:call_async) { |**args| enqueued << args }

        # Should not raise, should skip item without :id
        action_class.enqueue_all

        expect(enqueued).to contain_exactly(
          { item_id: 1 },
          { item_id: 3 },
        )
      end

      it "logs the swallowed error via piping_error" do
        allow(action_class).to receive(:call_async)
        expect(Axn::Internal::PipingError).to receive(:swallow).with(
          "via extraction (:id) for :item_id",
          exception: an_instance_of(NoMethodError),
        )

        action_class.enqueue_all
      end
    end

    describe "progress tracking via on_progress callback" do
      it "tracks stage and field during iteration" do
        progress_calls = []
        on_progress = ->(stage:, **rest) { progress_calls << { stage:, **rest } }

        cc = company_class
        action_class = build_axn do
          expects :company, type: cc
          enqueues_each :company, from: -> { cc.all }
        end.tap { |klass| enable_async_on(klass) }

        allow(action_class).to receive(:call_async)

        Axn::Async::EnqueueAllOrchestrator.execute_iteration(action_class, on_progress:)

        # Should have recorded resolving_source, then iterating for each item, then enqueueing
        expect(progress_calls.first).to include(stage: :resolving_source, field: :company)
        expect(progress_calls).to include(a_hash_including(stage: :iterating, field: :company))
        expect(progress_calls.last).to include(stage: :enqueueing)
      end
    end
  end
end
