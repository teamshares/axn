# frozen_string_literal: true

RSpec.describe Axn do
  let(:action) do
    build_axn do
      expects :foo, type: Numeric, numericality: { greater_than: 10 }
      expects :ssn, sensitive: true

      exposes :bar
      exposes :phone, sensitive: true
      exposes :the_internal_context, sensitive: true

      def call
        expose :bar, foo * 10
        expose :phone, "123-456-7890"
        expose :the_internal_context, internal_context
        fail! "intentional error" if foo == 13
      end
    end
  end

  let(:foo) { 11 }
  let(:result) { action.call(foo:, ssn: "abc") }

  context "inbound facade #inspect" do
    subject { result.the_internal_context.inspect }

    it { is_expected.to eq "#<Axn::Core::InternalContext foo: 11, ssn: [FILTERED]>" }
  end

  context "outbound facade #inspect" do
    subject { result.inspect }

    context "when OK" do
      it {
        is_expected.to eq "#<Axn::Result [OK] bar: 110, phone: [FILTERED], the_internal_context: [FILTERED]>"
      }
    end

    context "when exception" do
      let(:foo) { 9 }

      it {
        is_expected.to eq "#<Axn::Result [failed with Axn::InboundValidationError: 'Foo must be greater than 10'] bar: nil, phone: nil, the_internal_context: nil>" # rubocop:disable Layout/LineLength
      }
    end

    context "when failed" do
      let(:foo) { 13 }

      it {
        is_expected.to eq "#<Axn::Result [failed with 'intentional error'] bar: 130, phone: [FILTERED], the_internal_context: [FILTERED]>"
      }
    end
  end

  # The failure branch asks `default_message?` — axn's own predicate, defined only on `Axn::Failure` — and a
  # failed result's exception is frequently not one. Both routes below are mainstream: `fails_on` classifies a
  # caller's own exception class into the failure bucket, and `user_facing:` does the same for an inbound
  # validation error. Neither needs a hostile object to break `inspect`.
  describe "inspecting a failed result whose exception is not an Axn::Failure" do
    it "renders a fails_on-classified caller exception rather than raising" do
      boom = Class.new(StandardError)
      klass = build_axn do
        fails_on boom
        define_method(:call) { raise boom, "kaboom" }
      end
      result = klass.call

      expect(result.outcome.failure?).to be(true)
      expect(result.inspect).to eq("#<Axn::Result [failed with 'kaboom']>")
    end

    it "renders a user_facing validation failure rather than raising" do
      klass = build_axn do
        expects :n, numericality: { greater_than: 5 }, user_facing: true
        def call = nil
      end
      result = klass.call(n: 1)

      expect(result.outcome.failure?).to be(true)
      expect(result.inspect).to eq("#<Axn::Result [failed with 'N must be greater than 5']>")
    end
  end

  describe "inspecting a failed result whose exception cannot describe itself" do
    # `Result#inspect` is not on the `.call` path, so this raises nothing into an action — it poisons every
    # logger, debugger and spec-failure message that touches the result instead, which is worse to diagnose.
    let(:hostile_message) do
      Class.new(StandardError) do
        def message = raise(NotImplementedError, "message explodes")
      end
    end

    it "renders rather than raising" do
      # `build_axn`'s block runs via `class_eval`, so a bare call to the `let` above resolves against the
      # wrong `self` once inside `define_method`; capture it as a local first so the closure carries the
      # value rather than a method dispatch, and defer the raise to `#call` via `define_method` so it hits
      # axn's own exception handling instead of blowing up while the class is still being defined.
      exception_class = hostile_message
      result = build_axn { define_method(:call) { raise exception_class } }.call

      expect { result.inspect }.not_to raise_error
    end

    it "renders a message holding bytes with no UTF-8 rendering" do
      # The raw message alone never collides: the surrounding template is pure ASCII, and one
      # ASCII-compatible operand never trips `Encoding::CompatibilityError`. It takes a SECOND value with
      # real non-ASCII UTF-8 content — the outbound default below, applied on the failure branch and
      # joined into the same rendered line — to reproduce the raise the fix guards against.
      klass = build_axn do
        exposes :flag, default: -> { "café" }

        define_method(:call) { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }
      end
      result = klass.call

      expect { result.inspect }.not_to raise_error
    end
  end

  describe "inspecting a failed result whose fail! REASON cannot answer whether it is blank" do
    # A different route to the same defect, and the one no type guard could catch: the exception genuinely IS
    # an `Axn::Failure`, so the undispatched `Module#===` test in front of `default_message?` admits it, and the
    # raise comes from inside axn's own predicate — `@raw_reason.presence`, dispatching the caller's `blank?`.
    # `fail!` takes an arbitrary object, so the reason is caller code as surely as an exception's `#message` is.
    #
    # Everything that resolves through the reason is asserted, not just `inspect`: `result.error` and
    # `result.message` read it through `Result#_user_provided_error_message`, and all three raised.
    let(:unblankable) do
      Object.new.tap do |o|
        o.define_singleton_method(:empty?) { raise NotImplementedError, "empty? explodes" }
        o.define_singleton_method(:blank?) { raise NotImplementedError, "blank? explodes" }
        o.define_singleton_method(:to_s) { "the reason" }
      end
    end

    it "renders rather than raising, and still settles as a failure carrying that reason" do
      reason = unblankable
      result = build_axn { define_method(:call) { fail!(reason) } }.call

      expect(result.outcome.failure?).to be(true)
      expect { result.inspect }.not_to raise_error
      expect(result.inspect).to include("the reason")
      expect(result.error.to_s).to eq("the reason")
      expect(result.message.to_s).to eq("the reason")
    end

    # Settling an exception onto a result is a sequence, and a raise part-way through it skips the rest: the
    # reason was read while stamping the resolved presentation, one line ABOVE the `on_error` dispatch, so a
    # reason that could not answer `blank?` silently cost the callbacks rather than only a rendering.
    it "still dispatches on_error" do
      reason = unblankable
      fired = []
      klass = build_axn do
        on_error { fired << :on_error }
        define_method(:call) { fail!(reason) }
      end

      klass.call

      expect(fired).to eq([:on_error])
    end
  end
end
