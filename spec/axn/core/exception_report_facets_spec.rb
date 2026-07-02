# frozen_string_literal: true

RSpec.describe "Exception-report facets (on_exception context)" do
  around do |example|
    original = Axn.config.instance_variable_get(:@on_exception)
    example.run
    Axn.config.instance_variable_set(:@on_exception, original)
  end

  def capture_context(&action_body)
    captured = nil
    Axn.config.instance_variable_set(:@on_exception, proc { |context:| captured = context })
    Class.new { include Axn }.tap { |k| k.class_eval(&action_body) }.call
    captured
  end

  it "attaches resolved tags and dimensions to the report context" do
    ctx = capture_context do
      tag(:company_id) { 7 }
      dimension(:plan) { "pro" }
      def call = raise("boom")
    end

    expect(ctx[:tags]).to eq(company_id: 7)
    expect(ctx[:dimensions]).to eq(plan: "pro")
  end

  it "omits facet keys when the action declares none" do
    ctx = capture_context do
      def call = raise("boom")
    end

    expect(ctx).not_to have_key(:tags)
    expect(ctx).not_to have_key(:dimensions)
  end

  it "hands the reporter its own copy — mutation can't corrupt other sinks" do
    payload_tags = nil
    sub = ActiveSupport::Notifications.subscribe("axn.call") { |*args| payload_tags = args.last[:tags] }
    Axn.config.instance_variable_set(:@on_exception, proc { |context:| context[:tags][:company_id] = "MUTATED" })

    Class.new do
      include Axn
      tag(:company_id) { 7 }
      def call = raise("boom")
    end.call

    # on_exception mutated its dup before the notification payload was built from a fresh dup of the
    # untouched memoized map, so the subscriber still sees the real value.
    expect(payload_tags).to eq(company_id: 7)
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  it "lets the framework facet win over a user-supplied set_execution_context key" do
    ctx = capture_context do
      tag(:company_id) { 7 }
      def call
        set_execution_context(tags: { company_id: "user" })
        raise "boom"
      end
    end

    expect(ctx[:tags]).to eq(company_id: 7)
  end

  it "does NOT report facets for a fail! (failure bucket never reaches on_exception)" do
    reported = false
    Axn.config.instance_variable_set(:@on_exception, proc { reported = true })

    Class.new do
      include Axn
      tag(:company_id) { 7 }
      def call = fail!("nope")
    end.call

    expect(reported).to be(false)
  end
end
