# frozen_string_literal: true

RSpec.describe "step exposure merging" do
  it "does not let a later step's never-set optional exposure erase an earlier step's value" do
    first = build_axn do
      exposes :shared, optional: true
      def call = expose(shared: "FROM-FIRST")
    end
    second = build_axn do
      exposes :shared, :other, optional: true
      def call = expose(other: "FROM-SECOND")
    end
    f = first
    s = second

    parent = build_axn do
      exposes :shared, :other, optional: true
      step "first", f
      step "second", s
    end

    result = parent.call
    expect(result).to be_ok
    expect(result.other).to eq("FROM-SECOND")
    expect(result.shared).to eq("FROM-FIRST")
  end

  it "still lets a later step overwrite a value it actually sets" do
    first = build_axn do
      exposes :shared, optional: true
      def call = expose(shared: "FROM-FIRST")
    end
    second = build_axn do
      exposes :shared, optional: true
      def call = expose(shared: "FROM-SECOND")
    end
    f = first
    s = second

    parent = build_axn do
      exposes :shared, optional: true
      step "first", f
      step "second", s
    end

    expect(parent.call.shared).to eq("FROM-SECOND")
  end

  it "still chains an undeclared step output through to a later step" do
    producer = build_axn do
      exposes :intermediate, optional: true
      def call = expose(intermediate: "PASSED")
    end
    consumer = build_axn do
      expects :intermediate, optional: true
      exposes :final, optional: true
      def call = expose(final: intermediate)
    end
    p = producer
    c = consumer

    parent = build_axn do
      exposes :final, optional: true # deliberately does NOT declare :intermediate
      step "produce", p
      step "consume", c
    end

    expect(parent.call.final).to eq("PASSED")
  end

  it "absorbs a step-chain parent's own result without tripping over its undeclared keys" do
    producer = build_axn do
      exposes :intermediate, optional: true
      def call = expose(intermediate: "PASSED")
    end
    p = producer

    finisher = build_axn do
      expects :intermediate, optional: true
      exposes :final, optional: true
      def call = expose(final: intermediate)
    end
    fin = finisher

    inner_parent = build_axn do
      exposes :final, optional: true
      step "produce", p
      step "finish", fin
    end
    ip = inner_parent

    outer = build_axn do
      exposes :final, optional: true
      define_method(:call) { expose(ip.call) }
    end

    expect { outer.call! }.not_to raise_error
    expect(outer.call.final).to eq("PASSED")
  end

  it "still merges nothing from a failing step" do
    failing = build_axn do
      exposes :partial, optional: true
      def call
        expose partial: "SHOULD-NOT-PROPAGATE"
        fail! "step blew up"
      end
    end
    f = failing

    parent = build_axn do
      exposes :partial, optional: true
      step "failing", f
    end

    result = parent.call
    expect(result).not_to be_ok
    expect(result.error).to eq("failing: step blew up")
    expect(result.partial).to be_nil
  end
end
