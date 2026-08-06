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

  it "does not clobber with an auto-copied nil when the source never received the input" do
    absent = build_axn do
      expects :b, optional: true
      exposes :b, optional: true
      def call = nil
    end
    a = absent
    parent = build_axn do
      exposes :b, optional: true
      define_method(:call) do
        expose(b: "PARENT-OWN")
        expose(a.call)
      end
    end

    expect(parent.call.b).to eq("PARENT-OWN")
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

  it "does not overwrite a value this action already exposed with a never-set child field" do
    partial = build_axn do
      exposes :a, :b, optional: true
      def call
        expose a: "CHILD-A"
        fail! "boom"
      end
    end
    p = partial
    parent = build_axn do
      exposes :a, :b, optional: true
      define_method(:call) do
        expose(b: "PARENT-OWN")
        expose(p.call)
      end
    end

    result = parent.call
    expect(result.a).to eq("CHILD-A")
    expect(result.b).to eq("PARENT-OWN")
  end

  it "forwards a child's explicit nil over a value this action already exposed" do
    explicit_nil = build_axn do
      exposes :b, optional: true
      def call = expose(b: nil)
    end
    e = explicit_nil
    parent = build_axn do
      exposes :b, optional: true
      define_method(:call) do
        expose(b: "PARENT-OWN")
        expose(e.call)
      end
    end

    expect(parent.call.b).to be_nil
  end

  it "does not raise on an empty intersection when the source result failed" do
    no_overlap = build_axn do
      exposes :zzz, optional: true
      def call
        expose zzz: 1
        fail! "real error"
      end
    end
    n = no_overlap
    parent = build_axn do
      exposes :event, optional: true
      define_method(:call) do
        r = n.call
        expose(r)
        fail!(r.error) unless r.ok?
      end
    end

    result = parent.call
    expect(result.outcome).to be_failure
    expect(result.error).to eq("real error")
  end
end
