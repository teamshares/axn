# frozen_string_literal: true

# TODO: was used for manual testing -- clean up or remove when done

# NOTE: requires upstream interactor branch for support -- see TODO in Gemfile

RSpec.describe "One-off confirmation: inheritance and contracts" do
  let(:base) do
    build_axn do
      expects :foo, type: Numeric, numericality: { greater_than: 10 }
      exposes :bar, type: Numeric

      def call
        expose bar: base_thing
      end

      def base_thing = foo * 10
    end
  end

  let(:version_a) do
    Class.new(base) do
      expects :baz, default: 123
    end
  end

  let(:version_b) do
    Class.new(base) do
      expects :baz
      exposes :quz

      def call
        expose bar: baz
        expose quz: 999
      end
    end
  end

  it "does not modify other classes' configs when inheriting" do
    config_ids = [base, version_a, version_b].map(&:internal_field_configs).map(&:object_id)
    expect(config_ids.uniq.size).to eq(3)
    expect(base.call(foo: 11).bar).to eq(110)

    a = version_a.call(foo: 11)
    expect(a).to be_ok
    expect(a.bar).to eq(110)

    b = version_b.call(foo: 11, baz: 10)
    expect(b).to be_ok
    expect(b.bar).to eq(10)
    expect(b.quz).to eq(999)

    expect(version_b.call(baz: 10)).not_to be_ok
  end
end
