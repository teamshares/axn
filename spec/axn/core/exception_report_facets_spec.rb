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
    captured_tags = nil
    payload_tags = nil
    sub = ActiveSupport::Notifications.subscribe("axn.call") { |*args| payload_tags = args.last[:tags] }
    Axn.config.instance_variable_set(:@on_exception, proc { |context:|
      context[:tags][:company_id] = "MUTATED"
      captured_tags = context[:tags]
    })

    Class.new do
      include Axn
      tag(:company_id) { 7 }
      def call = raise("boom")
    end.call

    # The reporter really received a live, mutable copy...
    expect(captured_tags).to eq(company_id: "MUTATED")
    # ...but its mutation didn't reach the independent notification-payload sink.
    expect(payload_tags).to eq(company_id: 7)
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  it "hands the reporter its own copy of dimensions too" do
    captured = nil
    payload_dims = nil
    sub = ActiveSupport::Notifications.subscribe("axn.call") { |*args| payload_dims = args.last[:dimensions] }
    Axn.config.instance_variable_set(:@on_exception, proc { |context:|
      context[:dimensions][:plan] = "MUTATED"
      captured = context[:dimensions]
    })

    Class.new do
      include Axn
      dimension(:plan) { "pro" }
      def call = raise("boom")
    end.call

    expect(captured).to eq(plan: "MUTATED")
    expect(payload_dims).to eq(plan: "pro")
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  it "does not poison the shared facet memo with pre-timing values (span/payload still see elapsed_time)" do
    payload_tags = nil
    sub = ActiveSupport::Notifications.subscribe("axn.call") { |*args| payload_tags = args.last[:tags] }
    Axn.config.instance_variable_set(:@on_exception, proc {})

    Class.new do
      include Axn
      tag(:ms) { result.elapsed_time }
      def call = raise("boom")
    end.call

    # The report resolves before with_timing's ensure runs, so it can't know elapsed_time — but that
    # must not memoize a nil facet that the post-timing notification payload then inherits.
    expect(payload_tags[:ms]).not_to be_nil
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
