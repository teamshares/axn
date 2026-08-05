# frozen_string_literal: true

RSpec.describe "_declared_fields cache" do
  it "returns the same Array object across calls for the same direction" do
    action = build_axn do
      expects :name
      exposes :greeting
    end

    expect(action._declared_fields(:inbound)).to equal(action._declared_fields(:inbound))
    expect(action._declared_fields(:outbound)).to equal(action._declared_fields(:outbound))
    expect(action._declared_fields(nil)).to equal(action._declared_fields(nil))
  end

  it "still returns the correct fields per direction" do
    action = build_axn do
      expects :name
      exposes :greeting
    end

    expect(action._declared_fields(:inbound)).to eq([:name])
    expect(action._declared_fields(:outbound)).to eq([:greeting])
    expect(action._declared_fields(nil)).to contain_exactly(:name, :greeting)
  end

  it "rebuilds (new object, same content) after redeclaration" do
    action = build_axn { expects :name }
    first = action._declared_fields(:inbound)

    action.internal_field_configs = action.internal_field_configs.dup.freeze
    second = action._declared_fields(:inbound)

    expect(second).not_to equal(first)
    expect(second).to eq(first)
  end

  it "still raises for an invalid direction" do
    action = build_axn { expects :name }

    expect { action._declared_fields(:sideways) }.to raise_error(ArgumentError, /Invalid direction/)
  end

  it "returns a frozen Array, so a caller mutating the publicly-exposed declared_fields can't poison the class cache" do
    action = build_axn { expects :name }

    expect(action._declared_fields(:inbound)).to be_frozen
  end

  it "does not let a mutation attempt on result.declared_fields corrupt what the next call sees" do
    action = build_axn do
      expects :name
      exposes :greeting
      def call = expose(greeting: "hi")
    end

    result = action.call(name: "x")
    expect { result.declared_fields << :sneaked_in }.to raise_error(FrozenError)

    expect(action._declared_fields(:outbound)).to eq([:greeting])
  end
end
