# frozen_string_literal: true

# The two property-name rules live with reflection because they are judged on what reflection EMITS. Their
# BEHAVIOR is covered where it is exercised — `spec/axn/core/validations/property_name_collision_spec.rb` owns
# every assertion about what the rules accept and reject, and duplicating any of it here would add a second
# place to maintain them from for no added protection.
#
# What this file pins is the SURFACE: which methods the module offers, and that the rules' implementation
# (the walk, the message builders, the provenance resolution) is not among them. The module is internal per
# AGENTS.md's namespace policy — `Core::Contract` is its only caller — so a method becoming public here is a
# widening to make on purpose, not by accident.
RSpec.describe Axn::Reflection::PropertyNames do
  # Exactly the entry points its callers use: the three projection triggers reach the validated-* pair and
  # `validate_outbound!`, and the name renderers are shared by every layer that writes a declared name into a
  # message — the contract's declaration errors, a validation error naming a shape member, the stranded-path
  # diagnostic, and the call logger. Compared as a whole set rather than one `respond_to?` per name, so an
  # ADDITION fails this too.
  # `validate_inbound!`/`validate_outbound!` validate a class's projections WITHOUT going through
  # `input_schema`/`output_schema`, which an adapter base class may own (see Core::SchemaReflection).
  # `emitted_property_budget` hands out the emitted-property allowance rather than applying it here, because
  # bounding a declared shape graph and copying it are one walk over the caller's members (see
  # `Contract#_validate_and_snapshot_shape!`).
  let(:entry_points) do
    %i[
      emitted_property_budget
      inspect_field_name
      reject_unrenderable_field_names!
      renderable_label
      validate_inbound!
      validate_outbound!
      validated_input
      validated_output
    ]
  end

  it "offers exactly its entry points" do
    expect(described_class.singleton_methods(false).sort).to eq(entry_points.sort)
  end

  it "keeps the walk, the message builders, and provenance resolution internal" do
    internals = %i[
      validate_and_build
      attributions
      inbound_property_sources
      outbound_property_sources
      reject_colliding_emitted_properties!
      reject_oversized_schema!
      each_emitted_node
      raise_colliding_properties!
      raise_unrenderable_emitted_name!
      property_source
      property_sources_for
      shape_member_sources
      field_name_spelling
      describe_config
      count_shape_members!
    ]

    expect(internals.reject { |name| described_class.singleton_class.private_method_defined?(name) }).to be_empty
  end

  it "is not published on the extension surface" do
    expect(Axn::Extensions).not_to respond_to(:property_names)
  end
end
