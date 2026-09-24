# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "bigdecimal"

# ActiveModel's `LengthValidator#check_validity!` accepts exactly a non-negative Integer, `Float::INFINITY`
# (either sign), a Symbol, or a Proc for `:is`/`:minimum`/`:maximum` — anything else raises `ArgumentError`
# from INSIDE `EachValidator#initialize`. Its own `initialize` also requires `in:`/`within:` to be a Range at
# all. axn only reaches that code the first time the validator class is compiled (`ValidatorClassCache`, on
# the first `.call`), so a malformed option used to declare cleanly and fail every call with that opaque error
# instead of one naming the field at the point it was written. The declaration now builds the validator
# itself, so the verdict is ActiveModel's own and the message quotes it.
#
# `length: { in: 3..2 }` is the sharpest case: `LengthValidator#initialize` expands `in:`/`within:` into
# `:minimum`/`:maximum`, and a backwards (or otherwise empty) Range resolves its `:minimum` to `nil` there,
# which `check_validity!` rejects exactly as it rejects any other non-admissible bound.
RSpec.describe "a length: option ActiveModel cannot use" do
  let(:pattern) { /length: on .* has an option ActiveModel cannot use/ }

  describe "the ticket's own repro: a backwards range" do
    it "is refused on a top-level expects" do
      expect { build_axn { expects :v, type: Array, length: { in: 3..2 } } }.to raise_error(ArgumentError, pattern)
    end

    it "quotes ActiveModel's own error, which names the offending key" do
      expect { build_axn { expects :v, type: Array, length: { in: 3..2 } } }
        .to raise_error(ArgumentError, /:minimum must be a non-negative Integer, Infinity, Symbol, or Proc/)
    end

    it "is refused via the within: alias too" do
      expect { build_axn { expects :v, type: Array, length: { within: 3..2 } } }.to raise_error(ArgumentError, pattern)
    end

    it "is refused as the bare shorthand spelling" do
      expect { build_axn { expects :v, type: Array, length: (3..2) } }.to raise_error(ArgumentError, pattern)
    end

    it "is refused on an exposes" do
      expect { build_axn { exposes :v, type: Array, length: { in: 3..2 } } }.to raise_error(ArgumentError, pattern)
    end

    it "is refused on an on: subfield" do
      expect do
        build_axn do
          expects :parent, type: Hash
          expects :v, on: :parent, type: Array, length: { in: 3..2 }
        end
      end.to raise_error(ArgumentError, pattern)
    end

    it "is refused on a block-form shape member" do
      expect do
        build_axn { expects(:h, type: Hash) { field :v, type: Array, length: { in: 3..2 } } }
      end.to raise_error(ArgumentError, pattern)
    end

    it "is refused inside an of: bag, which admits length: as a value validator (PRO-3193)" do
      expect do
        build_axn { expects :v, type: Array, of: { klass: String, length: { in: 3..2 } } }
      end.to raise_error(ArgumentError, pattern)
    end

    it "is refused through Axn::Factory.build" do
      expect do
        Axn::Factory.build(expects: { v: { type: Array, length: { in: 3..2 } } }) { nil }
      end.to raise_error(ArgumentError, pattern)
    end
  end

  describe "other bound shapes ActiveModel's own check would reject" do
    {
      "a negative minimum:" => { minimum: -1 },
      "a negative maximum:" => { maximum: -1 },
      "a negative is:" => { is: -1 },
      "a non-Integer, non-Symbol, non-Proc minimum:" => { minimum: "3" },
      "a fractional maximum:" => { maximum: 2.5 },
      "an empty (exclusive) range" => { in: 2...2 },
      # AM's own admissibility test is `is_a?(Proc)`, not `respond_to?(:call)` — a hand-rolled callable
      # is refused there exactly as any other non-Proc, non-Symbol value is.
      "a callable that is not literally a Proc" => { minimum: Class.new { def call(_record) = 5 }.new },
      # A finite BigDecimal is not admissible either — AM wants a non-negative INTEGER, not any whole-valued
      # Numeric; only BigDecimal's own infinity is admitted.
      "a finite BigDecimal" => { minimum: BigDecimal("5") },
    }.each do |label, spelling|
      it "refuses #{label}" do
        expect { build_axn { expects :v, type: Array, length: spelling } }.to raise_error(ArgumentError, pattern)
      end
    end
  end

  # A falsy `in:`/`within:` with no other size key leaves the entry specifying no check at all — AM's own
  # `if range = (options.delete(:in) || options.delete(:within))` treats a falsy alias as not given, the same
  # skip-when-falsy idiom every other AM option follows, so nothing sets `:minimum`/`:maximum` and
  # `check_validity!` raises its OTHER error, "Range unspecified."
  describe "an entry that ends up specifying no check at all" do
    {
      "in: nil, nothing else" => { in: nil },
      "within: false, nothing else" => { within: false },
      "an empty bag" => {},
    }.each do |label, spelling|
      it "refuses #{label}" do
        expect { build_axn { expects :v, type: Array, length: spelling } }
          .to raise_error(ArgumentError, /length: on .* has an option ActiveModel cannot use .*Range unspecified/)
      end
    end

    it "does NOT refuse a falsy in: alongside a real minimum:, which AM treats as inert rather than missing" do
      expect { build_axn { expects :v, type: Array, presence: false, length: { in: nil, minimum: 3 } } }
        .not_to raise_error
    end
  end

  # A Range whose exclusive end has no `#-` (a String range) makes AM's own expansion raise `NoMethodError`
  # mid-computation; reported as the same clean ArgumentError as every other refusal here.
  it "refuses a Range whose exclusive end cannot be decremented, rather than crashing on it" do
    expect { build_axn { expects :v, type: String, length: { in: "a"..."c" } } }.to raise_error(ArgumentError, pattern)
  end

  # A non-Range `in:`/`within:` declared cleanly and crashed on the first call with ActiveModel's own
  # `":in and :within must be a Range"` — the very failure mode this guard exists to move to declaration.
  describe "a non-Range in:/within:" do
    {
      "an Integer" => { in: 3 },
      "a String" => { within: "1..3" },
      "an Array" => { in: [1, 3] },
    }.each do |label, spelling|
      it "refuses #{label}" do
        expect { build_axn { expects :v, type: Array, length: spelling } }.to raise_error(ArgumentError, pattern)
      end

      it "quotes ActiveModel's own reason for #{label}" do
        expect { build_axn { expects :v, type: Array, length: spelling } }
          .to raise_error(ArgumentError, /:in and :within must be a Range/)
      end
    end
  end

  # AM's own `initialize` only sets `:minimum`/`:maximum` for the end the Range HAS (`if range.begin` /
  # `if range.end`), so a beginless/endless range is a legal, common spelling (an open floor or an open
  # ceiling), where an unconditional `Range#min`/`Range#max` would raise `RangeError`.
  describe "a beginless or endless range, which ActiveModel declares cleanly (regression: must not crash)" do
    {
      "beginless (open floor)" => (..5),
      "endless (open ceiling)" => (5..),
    }.each do |label, range|
      it "declares cleanly for #{label}" do
        expect { build_axn { expects :v, type: Array, presence: false, length: { in: range } } }.not_to raise_error
      end

      it "enforces the bound it does have, for #{label}" do
        action = build_axn { expects :v, type: Array, presence: false, length: { in: range } }

        expect(action.call(v: [1, 2, 3, 4, 5])).to be_ok
        # A beginless range enforces no floor; an endless range enforces no ceiling — either way the OTHER
        # bound is real, so an array of 6 fails only the beginless (ceiling: 5) case.
        expect(action.call(v: [1, 2, 3, 4, 5, 6]).ok?).to eq(label.include?("endless"))
      end
    end
  end

  # `:in` wins over `:within` when both are present (`options.delete(:in) || options.delete(:within)`,
  # evaluated in that order) — the reverse precedence would silently swap which bound actually governs.
  describe "in:/within: precedence, matching ActiveModel's own options.delete(:in) || options.delete(:within)" do
    it "lets a valid in: win over an invalid within:, and declares cleanly" do
      expect { build_axn { expects :v, type: Array, presence: false, length: { in: 2..5, within: "garbage" } } }
        .not_to raise_error
    end

    it "reports within:'s own defect when in: is absent" do
      expect { build_axn { expects :v, type: Array, length: { within: "garbage" } } }
        .to raise_error(ArgumentError, /:in and :within must be a Range/)
    end
  end

  describe "bound shapes ActiveModel's own check accepts, which stay legal" do
    # `presence: false` throughout: this describes bound-TYPE validity in isolation, distinct from the
    # unrelated satisfiability guard (`_reject_unsatisfiable_size_interval!`) that a required field's implicit
    # floor of 1 would otherwise trip for `maximum: 0`.
    {
      "a plain Integer minimum:/maximum: pair" => { minimum: 1, maximum: 5 },
      "0, which names size 0 as the only admissible size" => { maximum: 0 },
      "Float::INFINITY, AM's spelling for no ceiling" => { maximum: Float::INFINITY },
      # `BigDecimal("Infinity") == Float::INFINITY` is `true`, and AM's own `check_validity!` tests exactly
      # that equality, not `bound.is_a?(Float)`.
      "BigDecimal(\"Infinity\"), which equals Float::INFINITY" => { maximum: BigDecimal("Infinity") },
      "BigDecimal(\"-Infinity\"), which equals -Float::INFINITY" => { minimum: BigDecimal("-Infinity") },
      "a Symbol, resolved per call" => { minimum: :min_length },
      "a Proc, resolved per call" => { maximum: ->(_record) { 5 } },
      "a well-formed in: range" => { in: 2..5 },
      "a well-formed within: range" => { within: 2..5 },
      "an exclusive well-formed range" => { in: 2...5 },
    }.each do |label, spelling|
      it "declares cleanly for #{label}" do
        expect { build_axn { expects :v, type: Array, presence: false, length: spelling } }.not_to raise_error
      end
    end

    it "declares cleanly for the bare shorthand spelling" do
      expect { build_axn { expects :v, type: Array, presence: false, length: 2..5 } }.not_to raise_error
    end

    it "declares cleanly with no length: at all" do
      expect { build_axn { expects :v, type: Array } }.not_to raise_error
    end

    it "declares cleanly for a disabled (falsy) length: entry" do
      expect { build_axn { expects :v, type: Array, length: false } }.not_to raise_error
    end
  end

  # The message: bag key rides alongside a legal bound and is untouched by this guard — a different key, a
  # different guard (`_reject_unsupported_validator_keys!` only refuses a BARE top-level message:).
  it "leaves a length: bag's own message: alone" do
    action = build_axn { expects :v, type: String, length: { minimum: 3, message: "too short" } }

    expect(action.call(v: "a").exception.message).to include("too short")
  end
end
