# frozen_string_literal: true

RSpec.describe "Axn::Mountable with enqueue_all" do
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
  # Uses and_wrap_original pattern from batch_enqueue_spec.rb
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

      # Always execute iteration synchronously and return the count (not a job ID)
      Axn::Async::EnqueueAllOrchestrator.execute_iteration(target, **static_args)
    end
  end

  # Helper to mark action as having async configured (for validation)
  def enable_async_on(action_class)
    action_class._async_adapter = :fake
  end

  describe "enqueue_all on mounted actions" do
    before { with_synchronous_enqueue_all }

    it "is available on the mounted action class via namespace" do
      target = build_axn do
        mount_axn(:sync_company, expects: [:company]) do |company:|
          "Processed #{company.name}"
        end
      end

      mounted_action = target::Axns::SyncCompany
      enable_async_on(mounted_action)

      expect(mounted_action).to respond_to(:enqueue_all)
    end

    it "works with explicit enqueues_each configuration" do
      cc = company_class
      target = build_axn do
        mount_axn(:sync_company, expects: [:company]) do |company:|
          "Processed #{company.name}"
        end
      end

      # Configure enqueues_each on the mounted action
      mounted_action = target::Axns::SyncCompany
      enable_async_on(mounted_action)
      mounted_action.enqueues_each :company, from: -> { cc.all }

      enqueued = []
      allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

      mounted_action.enqueue_all

      expect(enqueued.length).to eq(3)
      expect(enqueued.map { |e| e[:company].name }).to contain_exactly("Company A", "Company B", "Company C")
    end
  end

  describe "auto-inference from model: declarations" do
    before { with_synchronous_enqueue_all }

    it "infers enqueues_each from model: declaration" do
      cc = company_class
      stub_const("Company", cc)

      target = build_axn do
        mount_axn(:sync_company, expects: [{ company: { model: Company } }]) do |company:|
          "Processed #{company.name}"
        end
      end

      mounted_action = target::Axns::SyncCompany
      enable_async_on(mounted_action)
      # No explicit enqueues_each needed - should be inferred from model: Company

      enqueued = []
      allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

      mounted_action.enqueue_all

      expect(enqueued.length).to eq(3)
    end

    it "works with multiple model: fields" do
      cc = company_class
      uc = user_class
      stub_const("Company", cc)
      stub_const("User", uc)

      target = build_axn do
        mount_axn(:sync_user_company, expects: [{ user: { model: User } }, { company: { model: Company } }]) do |user:, company:|
          "Processed #{user.name} at #{company.name}"
        end
      end

      mounted_action = target::Axns::SyncUserCompany
      enable_async_on(mounted_action)
      # Both should be inferred

      enqueued = []
      allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

      mounted_action.enqueue_all

      # 2 users × 3 companies = 6 jobs
      expect(enqueued.length).to eq(6)
    end
  end

  describe "explicit enqueues_each configuration" do
    before { with_synchronous_enqueue_all }

    describe "with from: lambda" do
      it "uses the provided source" do
        cc = company_class
        target = build_axn do
          mount_axn(:sync_company, expects: [:company]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        mounted_action.enqueues_each :company, from: -> { cc.active }

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        mounted_action.enqueue_all

        # Only active companies (2 of 3)
        expect(enqueued.length).to eq(2)
        expect(enqueued.map { |e| e[:company].name }).to contain_exactly("Company A", "Company B")
      end
    end

    describe "with from: symbol (method name)" do
      it "calls the method on the action class" do
        cc = company_class
        target = build_axn do
          mount_axn(:sync_company, expects: [:company]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        mounted_action.define_singleton_method(:active_companies) { cc.active }
        mounted_action.enqueues_each :company, from: :active_companies

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        result = mounted_action.enqueue_all
        expect(result).to eq(2)
      end
    end

    describe "with via: extraction" do
      it "extracts the specified attribute" do
        cc = company_class
        target = build_axn do
          mount_axn(:sync_company, expects: [:company_id]) do |company_id:|
            "Processed company_id: #{company_id}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        mounted_action.enqueues_each :company_id, from: -> { cc.all }, via: :id

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        mounted_action.enqueue_all

        expect(enqueued.length).to eq(3)
        expect(enqueued).to contain_exactly(
          { company_id: 1 },
          { company_id: 2 },
          { company_id: 3 },
        )
      end
    end

    describe "with filter block" do
      it "only enqueues items where filter returns truthy" do
        cc = company_class
        target = build_axn do
          mount_axn(:sync_company, expects: [:company]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        mounted_action.enqueues_each :company, from: -> { cc.all }, &:active?

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        mounted_action.enqueue_all

        # Only active companies (2 of 3)
        expect(enqueued.length).to eq(2)
        expect(enqueued.map { |e| e[:company].name }).to contain_exactly("Company A", "Company B")
      end
    end
  end

  describe "static fields" do
    before { with_synchronous_enqueue_all }

    it "passes static fields through to each enqueued job" do
      cc = company_class
      target = build_axn do
        mount_axn(:sync_company, expects: %i[company format]) do |company:, format:|
          "Processed #{company.name} as #{format}"
        end
      end

      mounted_action = target::Axns::SyncCompany
      enable_async_on(mounted_action)
      mounted_action.enqueues_each :company, from: -> { cc.all }

      enqueued = []
      allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

      mounted_action.enqueue_all(format: :csv)

      expect(enqueued.length).to eq(3)
      expect(enqueued.all? { |e| e[:format] == :csv }).to be true
    end

    it "raises when required static field is missing" do
      cc = company_class
      target = build_axn do
        mount_axn(:sync_company, expects: %i[company format]) do |company:, format:|
          "Processed #{company.name} as #{format}"
        end
      end

      mounted_action = target::Axns::SyncCompany
      enable_async_on(mounted_action)
      mounted_action.enqueues_each :company, from: -> { cc.all }

      expect do
        mounted_action.enqueue_all
      end.to raise_error(ArgumentError, /Missing required static field.*format/)
    end
  end

  describe "multi-field cross-product" do
    before { with_synchronous_enqueue_all }

    it "creates cross-product of all fields" do
      cc = company_class
      uc = user_class
      target = build_axn do
        mount_axn(:sync_user_company, expects: %i[user company]) do |user:, company:|
          "Processed #{user.name} at #{company.name}"
        end
      end

      mounted_action = target::Axns::SyncUserCompany
      enable_async_on(mounted_action)
      mounted_action.enqueues_each :user, from: -> { uc.all }
      mounted_action.enqueues_each :company, from: -> { cc.active }

      enqueued = []
      allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

      mounted_action.enqueue_all

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

  describe "kwarg overrides" do
    before { with_synchronous_enqueue_all }

    describe "enumerable kwarg replaces configured source" do
      it "uses kwarg enumerable instead of configured source" do
        cc = company_class
        target = build_axn do
          mount_axn(:sync_company, expects: [:company]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        # Configured to iterate over all companies
        mounted_action.enqueues_each :company, from: -> { cc.all }

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        # Override with only first 2 companies
        subset = company_class._records[0..1]
        mounted_action.enqueue_all(company: subset)

        expect(enqueued.length).to eq(2)
        expect(enqueued.map { |e| e[:company] }).to eq(subset)
      end
    end

    describe "scalar kwarg overrides configured iteration" do
      it "uses scalar as static instead of iterating" do
        cc = company_class
        target = build_axn do
          mount_axn(:sync_company, expects: [:company]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        mounted_action.enqueues_each :company, from: -> { cc.all }

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        single_company = company_class._records.first
        mounted_action.enqueue_all(company: single_company)

        # Should enqueue once with the specific company (not iterate)
        expect(enqueued.length).to eq(1)
        expect(enqueued).to eq([{ company: single_company }])
      end
    end

    describe "enumerable kwarg replaces inferred source" do
      it "uses kwarg enumerable instead of inferred Model.all" do
        cc = company_class
        stub_const("Company", cc)

        target = build_axn do
          mount_axn(:sync_company, expects: [{ company: { model: Company } }]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        # No enqueues_each - should be inferred from model:

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        # Override with only active companies
        subset = company_class.active
        mounted_action.enqueue_all(company: subset)

        expect(enqueued.length).to eq(2) # Only active ones
      end
    end

    describe "scalar kwarg skips inferred iteration" do
      it "uses scalar as static instead of inferring iteration" do
        cc = company_class
        stub_const("Company", cc)

        target = build_axn do
          mount_axn(:sync_company, expects: [{ company: { model: Company } }]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        single_company = company_class._records.first
        mounted_action.enqueue_all(company: single_company)

        expect(enqueued.length).to eq(1)
        expect(enqueued).to eq([{ company: single_company }])
      end
    end
  end

  describe "error handling" do
    before { with_synchronous_enqueue_all }

    describe "async not configured" do
      it "raises NotImplementedError" do
        target = build_axn do
          # No async declaration
          mount_axn(:sync_company, expects: [:company]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        mounted_action.enqueues_each :company, from: -> { [] }

        expect do
          mounted_action.enqueue_all
        end.to raise_error(NotImplementedError, /does not have async configured/)
      end
    end

    describe "no enqueues_each with expects (no model:)" do
      it "raises MissingEnqueuesEachError with instructions" do
        target = build_axn do
          mount_axn(:sync_company, expects: [:company]) do |company:|
            # No model: declaration
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        # No enqueues_each called

        expect do
          mounted_action.enqueue_all
        end.to raise_error(Axn::Async::MissingEnqueuesEachError, /not covered by enqueues_each/)
      end
    end

    describe "no enqueues_each but has model: with find_each" do
      it "infers enqueues_each from model: declarations" do
        cc = company_class
        stub_const("Company", cc)

        target = build_axn do
          mount_axn(:sync_company, expects: [{ company: { model: Company } }]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        # No explicit enqueues_each - should be inferred

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        mounted_action.enqueue_all

        # Should have iterated over all 3 companies
        expect(enqueued.length).to eq(3)
      end
    end

    describe "multi-field: explicit config for one, inferred for another" do
      it "merges inferred and explicit configs" do
        cc = company_class
        uc = user_class
        stub_const("Company", cc)
        stub_const("User", uc)

        target = build_axn do
          mount_axn(:sync_user_company, expects: [{ user: { model: User } }, { company: { model: Company } }]) do |user:, company:|
            "Processed #{user.name} at #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncUserCompany
        enable_async_on(mounted_action)
        # Only explicit config for company with filter, user should be inferred
        mounted_action.enqueues_each :company, from: -> { cc.active }

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        mounted_action.enqueue_all

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
        stub_const("Company", cc)
        stub_const("User", uc)

        static_user = user_class._records.first

        target = build_axn do
          mount_axn(:sync_user_company, expects: [{ user: { model: User } }, { company: { model: Company } }]) do |user:, company:|
            "Processed #{user.name} at #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncUserCompany
        enable_async_on(mounted_action)
        mounted_action.enqueues_each :company, from: -> { cc.active }

        enqueued = []
        allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

        # Pass user as static arg - should not iterate over users
        mounted_action.enqueue_all(user: static_user)

        # 2 active companies × 1 static user = 2 jobs
        expect(enqueued.length).to eq(2)
        expect(enqueued.all? { |e| e[:user] == static_user }).to be true
      end
    end

    describe "no from: and no model" do
      it "raises helpful error" do
        target = build_axn do
          mount_axn(:sync_company, expects: [:company]) do |company:|
            "Processed #{company.name}"
          end
        end

        mounted_action = target::Axns::SyncCompany
        enable_async_on(mounted_action)
        mounted_action.enqueues_each :company # No from:

        expect do
          mounted_action.enqueue_all
        end.to raise_error(ArgumentError, /requires `from:` option or a `model:` declaration/)
      end
    end
  end

  describe "filter block exceptions" do
    before { with_synchronous_enqueue_all }

    it "swallows filter block errors and skips the item" do
      target = build_axn do
        mount_axn(:sync_number, expects: [:number]) do |number:|
          "Processed #{number}"
        end
      end

      mounted_action = target::Axns::SyncNumber
      enable_async_on(mounted_action)
      mounted_action.enqueues_each :number, from: -> { [1, 2, 3] } do |n|
        raise "filter exploded" if n == 2

        true
      end

      enqueued = []
      allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

      # Should not raise, should skip item 2
      mounted_action.enqueue_all

      expect(enqueued.length).to eq(2)
      expect(enqueued).to contain_exactly(
        { number: 1 },
        { number: 3 },
      )
    end

    it "logs the swallowed error via piping_error" do
      target = build_axn do
        mount_axn(:sync_number, expects: [:number]) do |number:|
          "Processed #{number}"
        end
      end

      mounted_action = target::Axns::SyncNumber
      enable_async_on(mounted_action)
      mounted_action.enqueues_each :number, from: -> { [1, 2, 3] } do |n|
        raise "filter exploded" if n == 2

        true
      end

      allow(mounted_action).to receive(:call_async)
      expect(Axn::Internal::Logging).to receive(:piping_error).with(
        "filter block for :number",
        exception: an_instance_of(RuntimeError),
      )

      mounted_action.enqueue_all
    end
  end

  describe "via extraction exceptions" do
    before { with_synchronous_enqueue_all }

    it "swallows via extraction errors and skips the item" do
      items = [
        Struct.new(:id).new(1),
        Struct.new(:name).new("no id"), # doesn't respond to :id
        Struct.new(:id).new(3),
      ]

      target = build_axn do
        mount_axn(:sync_item, expects: [:item_id]) do |item_id:|
          "Processed item_id: #{item_id}"
        end
      end

      mounted_action = target::Axns::SyncItem
      enable_async_on(mounted_action)
      mounted_action.enqueues_each :item_id, from: -> { items }, via: :id

      enqueued = []
      allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

      # Should not raise, should skip item without :id
      mounted_action.enqueue_all

      expect(enqueued.length).to eq(2)
      expect(enqueued).to contain_exactly(
        { item_id: 1 },
        { item_id: 3 },
      )
    end

    it "logs the swallowed error via piping_error" do
      items = [
        Struct.new(:id).new(1),
        Struct.new(:name).new("no id"), # doesn't respond to :id
        Struct.new(:id).new(3),
      ]

      target = build_axn do
        mount_axn(:sync_item, expects: [:item_id]) do |item_id:|
          "Processed item_id: #{item_id}"
        end
      end

      mounted_action = target::Axns::SyncItem
      enable_async_on(mounted_action)
      mounted_action.enqueues_each :item_id, from: -> { items }, via: :id

      allow(mounted_action).to receive(:call_async)
      expect(Axn::Internal::Logging).to receive(:piping_error).with(
        "via extraction (:id) for :item_id",
        exception: an_instance_of(NoMethodError),
      )

      mounted_action.enqueue_all
    end
  end

  describe "no expects at all" do
    # Note: This test doesn't use with_synchronous_enqueue_all because the no-expects case
    # goes through a different code path (direct call_async) which would trigger
    # LocalJumpError with the return statement in the stub.
    it "just calls call_async directly" do
      target = build_axn do
        mount_axn(:simple_action) do
          "Simple action executed"
        end
      end

      mounted_action = target::Axns::SimpleAction
      enable_async_on(mounted_action)

      expect(mounted_action).to receive(:call_async).with(no_args)
      mounted_action.enqueue_all
    end
  end

  describe "inheritance behavior" do
    before { with_synchronous_enqueue_all }

    it "inherits async config from target class" do
      cc = company_class
      stub_const("Company", cc)

      parent = build_axn do
        mount_axn(:sync_company, expects: [{ company: { model: Company } }]) do |company:|
          "Processed #{company.name}"
        end
      end

      child = Class.new(parent)

      # Child should inherit the mounted action
      mounted_action = child::Axns::SyncCompany
      enable_async_on(mounted_action)

      enqueued = []
      allow(mounted_action).to receive(:call_async) { |**args| enqueued << args }

      # Should work because async config is inherited
      mounted_action.enqueue_all

      expect(enqueued.length).to eq(3)
    end
  end
end
