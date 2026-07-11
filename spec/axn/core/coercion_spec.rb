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
        .to raise_error(ArgumentError, /coerce: does not yet support.*BigDecimal.*supported: Date, DateTime, Time, Symbol, Integer, Float/m)
      expect { build_axn { expects :flag, coerce: :boolean } }
        .to raise_error(ArgumentError, /coerce: does not yet support.*boolean/m)
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
end
