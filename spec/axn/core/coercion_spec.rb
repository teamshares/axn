# frozen_string_literal: true

require "spec_helper"
require "bigdecimal" # for the not-yet-supported guard test below (non-Rails specs don't autoload it)

RSpec.describe "coerce: DSL" do
  describe "parsing" do
    it "expands `coerce: <Type>` sugar into a coerce flag inside the type bag" do
      action = build_axn { expects :date, coerce: Date }
      type = action.internal_field_configs.first.validations[:type]
      expect(type[:klass]).to eq(Date)
      expect(type[:coerce]).to be(true)
    end

    it "accepts the explicit `type: { klass:, coerce: true }` form" do
      action = build_axn { expects :date, type: { klass: Date, coerce: true } }
      expect(action.internal_field_configs.first.validations[:type][:coerce]).to be(true)
    end

    it "accepts a union that pairs a coercible type with String" do
      action = build_axn { expects :date, coerce: [Date, String] }
      expect(action.internal_field_configs.first.validations[:type][:klass]).to eq([Date, String])
    end

    it "accepts an explicit `coerce: false` as a no-op (type declared, coercion off)" do
      action = build_axn { expects :date, type: { klass: Date, coerce: false } }
      expect(action.internal_field_configs.first.validations[:type][:coerce]).to be(false)
    end

    it "raises when the explicit coerce flag is a non-boolean" do
      expect { build_axn { expects :date, type: { klass: Date, coerce: :typo } } }
        .to raise_error(ArgumentError, /coerce: must be true or false/)
    end

    it "raises when coerce: and type: are combined" do
      expect { build_axn { expects :date, coerce: Date, type: Date } }
        .to raise_error(ArgumentError, /coerce: and type: cannot be combined/)
    end

    it "raises when coerce: is given a boolean at the top level" do
      expect { build_axn { expects :date, coerce: true } }
        .to raise_error(ArgumentError, /coerce: must be a type.*not a boolean/m)
    end

    it "raises a not-yet-supported error for an unsupported coerce target" do
      expect { build_axn { expects :amount, coerce: BigDecimal } }
        .to raise_error(ArgumentError, /coerce: does not yet support.*BigDecimal.*supported: Date, DateTime, Time, Symbol, Integer, Float, boolean/m)
    end

    it "accepts :boolean as a coerce target" do
      action = build_axn { expects :flag, coerce: :boolean }
      type = action.internal_field_configs.first.validations[:type]
      expect(type[:klass]).to eq(:boolean)
      expect(type[:coerce]).to be(true)
    end

    it "raises when a union has no coercible member" do
      expect { build_axn { expects :name, coerce: [String] } }
        .to raise_error(ArgumentError, /coerce: needs at least one coercible type/)
    end
  end

  describe "boundary (top-level expects only)" do
    it "rejects coerce: on exposes" do
      expect { build_axn { exposes :date, coerce: Date } }
        .to raise_error(ArgumentError, /coerce: is not supported on exposes/)
    end

    it "rejects coerce: on a subfield" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :when, on: :payload, coerce: Date
        end
      end.to raise_error(ArgumentError, /coerce: is not supported on subfields/)
    end

    it "rejects coerce: on an ambient_context subfield" do
      expect { build_axn { expects :when, on: :ambient_context, coerce: Date } }
        .to raise_error(ArgumentError, /coerce: is not supported on subfields/)
    end

    it "rejects coerce: on a shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :when, coerce: Date
          end
        end
      end.to raise_error(ArgumentError, /coerce: is not supported on a shape member/)
    end
  end

  describe "runtime coercion" do
    it "coerces a wire string into the declared Ruby type" do
      action = build_axn do
        expects :on, coerce: Date
        exposes :klass, allow_blank: true
        def call = expose(klass: on.class.name)
      end
      result = action.call(on: "2026-07-08")
      expect(result).to be_ok
      expect(result.klass).to eq("Date")
    end

    it "leaves a value that is already the Ruby type untouched" do
      action = build_axn do
        expects :on, coerce: Date
        exposes :day, allow_blank: true
        def call = expose(day: on.day)
      end
      result = action.call(on: Date.new(2026, 7, 8))
      expect(result).to be_ok
      expect(result.day).to eq(8)
    end

    it "runs coercion BEFORE a user preprocess: on the same field" do
      action = build_axn do
        expects :on, coerce: Date, preprocess: ->(v) { v.is_a?(Date) ? v + 1 : v }
        exposes :day, allow_blank: true
        def call = expose(day: on.day)
      end
      result = action.call(on: "2026-07-08")
      expect(result).to be_ok
      expect(result.day).to eq(9) # preprocess saw a coerced Date and added a day
    end

    it "does not clobber a real-object default" do
      action = build_axn do
        expects :on, coerce: Date, default: -> { Date.new(2000, 1, 1) }
        exposes :day, allow_blank: true
        def call = expose(day: on.day)
      end
      result = action.call
      expect(result).to be_ok
      expect(result.day).to eq(1)
    end

    it "does not let a blank string smuggle past presence on a required coerce: Symbol field" do
      action = build_axn { expects :mode, coerce: Symbol }
      blank = action.call(mode: "   ")
      expect(blank).not_to be_ok
      expect(blank.exception.message).to match(/can't be blank/)
    end

    it "runs coercion BEFORE the field's own inclusion: validator, so a coerced value can pass or fail it" do
      action = build_axn do
        expects :mode, coerce: Symbol, inclusion: { in: %i[a b] }
        exposes :mode, allow_blank: true
        def call = expose(mode:)
      end

      included = action.call(mode: "a")
      expect(included).to be_ok
      expect(included.mode).to eq(:a)

      excluded = action.call(mode: "z")
      expect(excluded).not_to be_ok
      expect(excluded.exception.message).to match(/is not included in the list/)
      expect(excluded.exception.message).not_to match(/could not be coerced/)
    end

    describe "coerce: :boolean" do
      let(:action) do
        build_axn do
          expects :flag, coerce: :boolean
          exposes :flag, allow_blank: true
          def call = expose(flag:)
        end
      end

      it "coerces a wire string into a real boolean" do
        expect(action.call(flag: "true").flag).to be(true)
        expect(action.call(flag: "0").flag).to be(false)
        expect(action.call(flag: "on").flag).to be(true)
      end

      it "coerces the integers 1 and 0" do
        expect(action.call(flag: 1).flag).to be(true)
        expect(action.call(flag: 0).flag).to be(false)
      end

      it "leaves an already-boolean value untouched" do
        expect(action.call(flag: true).flag).to be(true)
        expect(action.call(flag: false).flag).to be(false)
      end

      it "reports an uncoerceable string or integer as could-not-be-coerced" do
        bad_string = action.call(flag: "maybe")
        expect(bad_string).not_to be_ok
        expect(bad_string.exception.message).to match(/could not be coerced to a boolean/)

        bad_int = action.call(flag: 2)
        expect(bad_int).not_to be_ok
        expect(bad_int.exception.message).to match(/could not be coerced to a boolean/)
      end
    end
  end

  describe "schema" do
    it "reflects a coerce: field identically to a plain type: field" do
      coerced = build_axn { expects :on, coerce: Date }
      plain   = build_axn { expects :on, type: Date }
      expect(coerced.input_schema).to eq(plain.input_schema)
    end

    it "reflects a coerce: :boolean field identically to a plain type: :boolean field" do
      coerced = build_axn { expects :flag, coerce: :boolean }
      plain   = build_axn { expects :flag, type: :boolean }
      expect(coerced.input_schema).to eq(plain.input_schema)
    end
  end

  describe "coercion-failure message" do
    it "reports an uncoerceable string distinctly from a wrong-type value" do
      action = build_axn { expects :on, coerce: Date }

      uncoerceable = action.call(on: "nope")
      expect(uncoerceable).not_to be_ok
      expect(uncoerceable.exception.message).to match(/could not be coerced to a Date/)

      wrong_type = action.call(on: 123)
      expect(wrong_type).not_to be_ok
      expect(wrong_type.exception.message).to match(/is not a Date/)
      expect(wrong_type.exception.message).not_to match(/could not be coerced/)
    end

    it "does not emit the coercion message when a String branch validates the value" do
      action = build_axn { expects :on, coerce: [Date, String] }
      expect(action.call(on: "nope")).to be_ok
    end

    it "names every union member in a union coercion-failure message" do
      action = build_axn { expects :on, coerce: [Date, Integer] }
      result = action.call(on: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/could not be coerced to one of Date, Integer/)
    end

    it "honors an explicit message: override" do
      action = build_axn { expects :on, type: { klass: Date, coerce: true, message: "bad date" } }
      result = action.call(on: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/bad date/)
      expect(result.exception.message).not_to match(/could not be coerced/)
    end
  end

  # PRO-2884: the coerce_input_types config turns coercion on for every coercible field without
  # annotating each — the operational "this action is transport-facing" assertion, vs the per-field
  # `coerce:` contract tool. Global default false; per-class-overridable via the PRO-2856 machinery.
  describe "coerce_input_types config" do
    let(:coercing_axn) do
      build_axn do
        expects :on, type: Date
        exposes :klass, allow_blank: true
        def call = expose(klass: on.class.name)
      end
    end

    context "globally" do
      after { Axn.config.coerce_input_types = false }

      it "coerces a plain type: field when on" do
        Axn.config.coerce_input_types = true
        result = coercing_axn.call(on: "2026-07-08")
        expect(result).to be_ok
        expect(result.klass).to eq("Date")
      end

      it "leaves a plain type: field strict when off (default)" do
        result = coercing_axn.call(on: "2026-07-08")
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/is not a Date/)
      end
    end

    context "per-class override" do
      it "coerces the opted-in action but leaves a sibling strict" do
        opted_in = build_axn do
          configure { |c| c.coerce_input_types = true }
          expects :on, type: Date
          exposes :klass, allow_blank: true
          def call = expose(klass: on.class.name)
        end
        sibling = build_axn { expects :on, type: Date }

        expect(opted_in.call(on: "2026-07-08").klass).to eq("Date")
        expect(sibling.call(on: "2026-07-08")).not_to be_ok
      end

      it "flows to a subclass" do
        base = build_axn { configure { |c| c.coerce_input_types = true } }
        child = Class.new(base) do
          expects :on, type: Date
          exposes :klass, allow_blank: true
          def call = expose(klass: on.class.name)
        end
        expect(child.call(on: "2026-07-08").klass).to eq("Date")
      end
    end

    context "field-level intent wins over the flag" do
      it "opts a field out via explicit coerce: false" do
        action = build_axn do
          configure { |c| c.coerce_input_types = true }
          expects :on, type: { klass: Date, coerce: false }
        end
        result = action.call(on: "2026-07-08")
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/is not a Date/)
      end

      it "still honors an explicit coerce: with the flag on" do
        action = build_axn do
          configure { |c| c.coerce_input_types = true }
          expects :on, coerce: Date
          exposes :klass, allow_blank: true
          def call = expose(klass: on.class.name)
        end
        expect(action.call(on: "2026-07-08").klass).to eq("Date")
      end
    end

    it "coerces a plain type: :boolean field when on" do
      action = build_axn do
        configure { |c| c.coerce_input_types = true }
        expects :flag, type: :boolean
        exposes :flag, allow_blank: true
        def call = expose(flag:)
      end
      expect(action.call(flag: "true").flag).to be(true)
      expect(action.call(flag: 0).flag).to be(false)
    end

    it "leaves a non-coercible type untouched with the flag on" do
      action = build_axn do
        configure { |c| c.coerce_input_types = true }
        expects :name, type: String
        exposes :klass, allow_blank: true
        def call = expose(klass: name.class.name)
      end
      expect(action.call(name: "hi").klass).to eq("String")
    end

    it "emits the coercion-failure message for a flag-coerced field" do
      action = build_axn do
        configure { |c| c.coerce_input_types = true }
        expects :on, type: Date
      end

      uncoerceable = action.call(on: "nope")
      expect(uncoerceable.exception.message).to match(/could not be coerced to a Date/)

      wrong_type = action.call(on: 123)
      expect(wrong_type.exception.message).to match(/is not a Date/)
      expect(wrong_type.exception.message).not_to match(/could not be coerced/)
    end

    it "does not reach subfields (current scope; a future ticket extends the flag there)" do
      action = build_axn do
        configure { |c| c.coerce_input_types = true }
        expects :payload, type: Hash
        expects :starts_on, on: :payload, type: Date
      end
      # The subfield's own `type: Date` still rejects the wire string — proof the flag left it uncoerced.
      expect(action.call(payload: { starts_on: "2026-07-08" })).not_to be_ok
    end

    it "leaves input_schema identical whether the flag is on or off" do
      off = build_axn { expects :on, type: Date }
      on = build_axn do
        configure { |c| c.coerce_input_types = true }
        expects :on, type: Date
      end
      expect(on.input_schema).to eq(off.input_schema)
    end
  end
end
