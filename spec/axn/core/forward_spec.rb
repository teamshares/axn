# frozen_string_literal: true

RSpec.describe "forward!" do
  let(:child) do
    build_axn do
      expects :x, optional: true
      exposes :event, :extra, optional: true
      def call = expose(event: "E-#{x}", extra: "X")
    end
  end

  it "invokes a class form with the parent's resolved inputs and absorbs its exposures" do
    c = child
    parent = build_axn do
      expects :x, optional: true
      exposes :event, optional: true # deliberately NOT extra
      define_method(:call) { forward! c }
    end

    result = parent.call(x: 7)
    expect(result).to be_ok
    expect(result.event).to eq("E-7")
    expect(result).not_to respond_to(:extra)
  end

  it "passes only the parent's declared inputs, not undeclared caller fields" do
    nosy = build_axn do
      expects :sneaky, optional: true
      exposes :saw, optional: true
      def call = expose(saw: sneaky)
    end
    n = nosy
    parent = build_axn do
      expects :x, optional: true # deliberately does NOT declare :sneaky
      exposes :saw, optional: true
      define_method(:call) { forward! n }
    end

    # A step chain would pass :sneaky through as undeclared passthrough; forward! deliberately does not.
    result = parent.call(x: 1, sneaky: "LEAKED")
    expect(result).to be_ok
    expect(result.saw).to be_nil
  end

  it "returns the child result and keeps executing on success" do
    c = child
    parent = build_axn do
      expects :x, optional: true
      exposes :event, :after, optional: true
      define_method(:call) do
        returned = forward! c
        expose(after: returned.event.upcase)
      end
    end

    result = parent.call(x: 1)
    expect(result.event).to eq("E-1")
    expect(result.after).to eq("E-1")
  end

  it "forwards a caller-built result unchanged" do
    c = child
    parent = build_axn do
      exposes :event, optional: true
      define_method(:call) { forward! c.call(x: 99) }
    end

    expect(parent.call.event).to eq("E-99")
  end

  it "surfaces a failed child's exposures AND settles as that failure" do
    failing = build_axn do
      exposes :event, optional: true
      def call
        expose event: "PARTIAL"
        fail! "child failed"
      end
    end
    f = failing
    parent = build_axn do
      exposes :event, optional: true
      define_method(:call) { forward! f }
    end

    result = parent.call
    expect(result.outcome).to be_failure
    expect(result.error).to eq("child failed")
    expect(result.event).to eq("PARTIAL")
  end

  it "surfaces exposures and re-raises on a child that raised" do
    boom = build_axn do
      exposes :event, optional: true
      def call
        expose event: "BEFORE-BOOM"
        raise "kaboom"
      end
    end
    b = boom
    parent = build_axn do
      exposes :event, optional: true
      define_method(:call) { forward! b }
    end

    result = parent.call
    expect(result.outcome).to be_exception
    expect(result.event).to eq("BEFORE-BOOM")
    expect { parent.call! }.to raise_error(RuntimeError, "kaboom")
  end

  it "produces the same error string as the call! it replaces" do
    inner = build_axn do
      error "inner exploded"
      def call = fail!("child failed")
    end
    i = inner

    via_bang = build_axn do
      exposes :event, optional: true
      define_method(:call) { i.call! }
    end
    via_forward = build_axn do
      exposes :event, optional: true
      define_method(:call) { forward! i.call }
    end

    expect(via_forward.call.error).to eq(via_bang.call.error)
    expect(via_forward.call.error).to eq("inner exploded: child failed")
  end

  it "matches call!'s error when a child with a declared error base raises" do
    inner = build_axn do
      error "inner exploded"
      def call = raise("kaboom")
    end
    i = inner

    via_bang = build_axn { define_method(:call) { i.call! } }
    via_forward = build_axn { define_method(:call) { forward! i } }

    expect(via_forward.call.error).to eq(via_bang.call.error)
    expect(via_forward.call.error).to eq("inner exploded")
  end

  it "matches call!'s aggregated error when both the child and the parent declare a base" do
    inner = build_axn do
      error "inner exploded"
      def call = raise("kaboom")
    end
    i = inner

    via_bang = build_axn do
      error "Outer failed"
      define_method(:call) { i.call! }
    end
    via_forward = build_axn do
      error "Outer failed"
      define_method(:call) { forward! i }
    end

    expect(via_forward.call.error).to eq(via_bang.call.error)
    expect(via_forward.call.error).to eq("Outer failed: inner exploded")
  end

  it "matches call!'s error and exception identity for a fails_on-classified child" do
    not_found = Class.new(StandardError)
    inner = build_axn do
      fails_on not_found
      define_method(:call) { raise(not_found, "no such record") }
    end
    i = inner

    via_bang = build_axn do
      error "Outer failed"
      error "Record not found", if: not_found
      define_method(:call) { i.call! }
    end
    via_forward = build_axn do
      error "Outer failed"
      error "Record not found", if: not_found
      define_method(:call) { forward! i }
    end

    expect(via_forward.call.error).to eq(via_bang.call.error)
    expect(via_forward.call.error).to eq("Outer failed: Record not found")

    # The exception identity is what keeps the parent's own `if: not_found` handler matching.
    expect(via_forward.call.exception).to be_a(not_found)
    expect(via_forward.call.exception.class).to eq(via_bang.call.exception.class)
  end

  it "does not overwrite a value the parent already exposed with a never-set child field" do
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
        forward! p
      end
    end

    result = parent.call
    expect(result.a).to eq("CHILD-A")
    expect(result.b).to eq("PARENT-OWN")
  end

  it "cannot launder a contract violation into a successful result" do
    stringy = build_axn do
      exposes :n, optional: true
      def call = expose(n: "not-an-int")
    end
    s = stringy
    parent = build_axn do
      exposes :n, type: Integer, optional: true
      define_method(:call) { forward! s }
    end

    result = parent.call
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(Axn::OutboundValidationError)
    expect(result.exception.message).to eq("N is not a Integer")
  end

  it "forwards cleanly from a side-effect-only child with no declared exposures" do
    side_effecting = build_axn { def call = nil }
    child_action = side_effecting
    parent = build_axn do
      exposes :event, optional: true
      define_method(:call) { forward! child_action }
    end

    expect(parent.call).to be_ok
  end

  it "forwards cleanly when the child exposes a field the parent does not declare" do
    c = child
    parent = build_axn do
      expects :x, optional: true # deliberately declares NO exposures at all
      define_method(:call) { forward! c }
    end

    expect(parent.call(x: 3)).to be_ok
  end

  it "does not clobber with an auto-copied nil when the child never received the input" do
    # A child declaring a field as both expects and exposes gets it auto-copied onto its result. When
    # the caller supplied nothing, there is no value to copy, so the field must not reach the parent.
    absent = build_axn do
      expects :a, optional: true
      expects :b, optional: true
      exposes :a, optional: true
      exposes :b, optional: true
      def call = expose(a: "CHILD-A")
    end
    c = absent
    parent = build_axn do
      exposes :a, :b, optional: true
      define_method(:call) do
        expose(b: "PARENT-OWN")
        forward! c
      end
    end

    result = parent.call
    expect(result.a).to eq("CHILD-A")
    expect(result.b).to eq("PARENT-OWN")
  end

  it "forwards an auto-copied nil the caller explicitly supplied" do
    # Presence, not value: the caller supplying `b: nil` means something different from supplying
    # nothing, and only the former should overwrite what the absorbing action already holds.
    explicit = build_axn do
      expects :b, allow_nil: true, optional: true
      exposes :b, allow_nil: true, optional: true
      def call = nil
    end
    e = explicit
    parent = build_axn do
      exposes :b, allow_nil: true, optional: true
      define_method(:call) do
        expose(b: "PARENT-OWN")
        forward! e.call(b: nil)
      end
    end

    expect(parent.call.b).to be_nil
  end

  it "still forwards an auto-copied value the child actually received" do
    present = build_axn do
      expects :b, optional: true
      exposes :b, optional: true
      def call = nil
    end
    c = present
    parent = build_axn do
      expects :b, optional: true
      exposes :b, optional: true
      define_method(:call) { forward! c }
    end

    expect(parent.call(b: "FROM-CALLER").b).to eq("FROM-CALLER")
  end

  it "raises ArgumentError for a class that does not include Axn" do
    parent = build_axn do
      exposes :event, optional: true
      def call = forward!(String)
    end

    expect { parent.call! }.to raise_error(ArgumentError, /must include Axn/)
  end

  it "raises ArgumentError for something that is neither a class nor a result" do
    parent = build_axn do
      exposes :event, optional: true
      def call = forward!("not a result")
    end

    expect { parent.call! }.to raise_error(ArgumentError, /Axn class or an Axn::Result/)
  end
end
