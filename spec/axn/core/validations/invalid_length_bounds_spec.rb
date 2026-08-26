# frozen_string_literal: true

require "axn/testing/spec_helpers"

# ActiveModel's `LengthValidator#check_validity!` accepts exactly a non-negative Integer, `Float::INFINITY`, a
# Symbol, or a Proc for `:is`/`:minimum`/`:maximum` — anything else raises `ArgumentError` from INSIDE
# `EachValidator#initialize`. axn only reaches that code the first time the validator class is compiled
# (`ValidatorClassCache`, on the first `.call`), so a malformed bound used to declare cleanly and fail every
# call with that opaque error instead of one naming the field at the point it was written.
#
# `length: { in: 3..2 }` is the same defect spelled as a Range: `LengthValidator#initialize` expands `in:`/
# `within:` by overwriting `:minimum`/`:maximum` with `range.min`/`range.max`, and a backwards (or otherwise
# empty) Range resolves both to `nil` — not itself Numeric, so `check_validity!` rejects it exactly as it
# rejects any other non-admissible bound.
RSpec.describe "a length: bound ActiveModel cannot use" do
  let(:pattern) { /length: on .* has a bound ActiveModel cannot use/ }

  describe "the ticket's own repro: a backwards range" do
    it "is refused on a top-level expects" do
      expect { build_axn { expects :v, type: Array, length: { in: 3..2 } } }.to raise_error(ArgumentError, pattern)
    end

    it "names the offending key and its resolved (nil) value" do
      expect { build_axn { expects :v, type: Array, length: { in: 3..2 } } }
        .to raise_error(ArgumentError, /minimum: nil/)
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
    }.each do |label, spelling|
      it "refuses #{label}" do
        expect { build_axn { expects :v, type: Array, length: spelling } }.to raise_error(ArgumentError, pattern)
      end
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
