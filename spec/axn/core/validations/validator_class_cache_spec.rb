# frozen_string_literal: true

RSpec.describe "validator class cache" do
  it "reuses the same compiled validator class across two calls with the same config" do
    action = build_axn { expects :name, type: String }
    config = action.internal_field_configs.first

    first = action._cached_validator_class_for(config:, effective_validations: config.validations, coerce: false)
    second = action._cached_validator_class_for(config:, effective_validations: config.validations, coerce: false)

    expect(first).to be(second)
  end

  it "builds a distinct class per coerce state for the same config" do
    action = build_axn { expects :name, type: String }
    config = action.internal_field_configs.first

    off = action._cached_validator_class_for(config:, effective_validations: config.validations, coerce: false)
    on = action._cached_validator_class_for(config:, effective_validations: config.validations.merge(type: { klass: String, coerce: true }),
                                            coerce: true)

    expect(off).not_to be(on)
  end

  it "does not reuse a class across two distinct FieldConfigs for the same field name" do
    first_class = build_axn { expects :name, type: String }
    second_class = build_axn { expects :name, type: Integer }
    first_config = first_class.internal_field_configs.first
    second_config = second_class.internal_field_configs.first

    first_built = first_class._cached_validator_class_for(config: first_config, effective_validations: first_config.validations, coerce: false)
    second_built = second_class._cached_validator_class_for(config: second_config, effective_validations: second_config.validations, coerce: false)

    expect(first_built).not_to be(second_built)
  end

  it "invalidates when the class redeclares the field" do
    action = build_axn { expects :name, type: String }
    original_config = action.internal_field_configs.first
    original_class = action._cached_validator_class_for(config: original_config, effective_validations: original_config.validations, coerce: false)

    # Simulate Mountable/a downstream gem replacing the array wholesale (identity-keyed caching relies
    # on replacement — see contract.rb's comment on `self.internal_field_configs =`).
    action.internal_field_configs = [original_config].freeze
    rebuilt_class = action._cached_validator_class_for(config: original_config, effective_validations: original_config.validations, coerce: false)

    expect(rebuilt_class).not_to be(original_class)
  end

  it "gives a subclass its own cache rather than inheriting the parent's" do
    parent = build_axn { expects :name, type: String }
    child = Class.new(parent)
    parent_config = parent.internal_field_configs.first
    child_config = child.internal_field_configs.first

    parent_built = parent._cached_validator_class_for(config: parent_config, effective_validations: parent_config.validations, coerce: false)
    child_built = child._cached_validator_class_for(config: child_config, effective_validations: child_config.validations, coerce: false)

    expect(parent_built).not_to be(child_built)
  end
end
