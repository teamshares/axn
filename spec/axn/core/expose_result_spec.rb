# frozen_string_literal: true

RSpec.describe "expose(result) forwarding" do
  let(:child) do
    build_axn do
      expects :x, optional: true
      exposes :doubled, :echoed, optional: true
      def call
        expose doubled: (x || 0) * 2, echoed: x
      end
    end
  end

  it "forwards the intersection of declared exposures on an ok result" do
    c = child
    parent = build_axn do
      exposes :doubled, optional: true # deliberately NOT echoed
      define_method(:call) { expose(c.call(x: 3)) }
    end

    result = parent.call
    expect(result).to be_ok
    expect(result.doubled).to eq(6)
    expect(result).not_to respond_to(:echoed)
  end

  it "forwards what a failed child managed to expose, without raising" do
    failing = build_axn do
      exposes :record, optional: true
      def call
        expose record: "partial"
        fail! "boom"
      end
    end
    f = failing
    parent = build_axn do
      exposes :record, optional: true
      define_method(:call) { expose(f.call) } # no fail! — isolate forwarding
    end

    expect(parent.call.record).to eq("partial")
  end

  it "forwards nil for a declared field the child never exposed" do
    early_fail = build_axn do
      exposes :record, optional: true
      def call
        fail! "boom before expose"
      end
    end
    e = early_fail
    parent = build_axn do
      exposes :record, optional: true
      define_method(:call) { expose(e.call) }
    end

    expect(parent.call.record).to be_nil
  end

  it "raises when there is no field in common to forward" do
    c = child
    parent = build_axn do
      exposes :unrelated, optional: true
      define_method(:call) { expose(c.call(x: 1)) }
    end

    expect { parent.call! }.to raise_error(Axn::ContractViolation::NoMatchingExposures)

    r = parent.call
    expect(r).not_to be_ok
    expect(r.exception).to be_a(Axn::ContractViolation::NoMatchingExposures)
  end

  it "still exposes a Result as a value via the two-positional form" do
    c = child
    parent = build_axn do
      exposes :child_result, optional: true
      define_method(:call) { expose(:child_result, c.call(x: 1)) }
    end

    expect(parent.call.child_result).to be_a(Axn::Result)
  end

  it "still raises ArgumentError for a lone non-Result positional" do
    parent = build_axn do
      exposes :foo, optional: true
      def call = expose("not a result")
    end

    expect { parent.call! }.to raise_error(ArgumentError)
  end
end
