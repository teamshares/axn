# frozen_string_literal: true

require_relative "../../support/shared_examples/registry_behavior"

RSpec.describe Axn::Mountable::MountingStrategies do
  it_behaves_like "a registry" do
    let(:expected_built_in_keys) { %i[axn method step] }
    let(:expected_find_key) { :step }
    let(:expected_item_type) { "Mounting Type" }
    let(:expected_not_found_error_class) { Axn::Mountable::MountingTypeNotFound }
    let(:expected_duplicate_error_class) { Axn::Mountable::DuplicateMountingTypeError }
  end

  # By identity: every strategy extends Base, so `Base === strategy` and an `include` matcher would match.
  it "leaves the shared Base helper out of the listing" do
    expect(described_class.built_in.values.any? { |v| v.equal?(Axn::Mountable::MountingStrategies::Base) }).to be(false)
  end
end
