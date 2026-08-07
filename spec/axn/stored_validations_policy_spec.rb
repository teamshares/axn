# frozen_string_literal: true

require "axn/testing/spec_helpers"

# An `on:` inside a validator's option bag is refused at declaration (`_reject_validator_context_scope!`), and
# the nil/empty predicates and schema reflection therefore carry no branch for one. That is sound only while
# every stored `validations` bag comes from a guarded seam — `_parse_field_validations` for a field, subfield,
# exposure, block-form member or Factory declaration, and `_symbol_keyed_member_validations` for a raw or
# object-backed shape member.
#
# So the constructors are pinned by count per file. A NEW one is the single way that claim can break, and it
# is what this spec exists to catch: route the new bag through a seam, or restore the tolerance the predicates
# used to carry.
#
# A bag can also be RE-DERIVED from an existing config rather than constructed: `Data#with` builds a new
# config carrying a different bag without going through either seam. That dimension is pinned too, so both
# ways a stored bag comes to exist are covered.
#
# What a bypass costs, so the next reader knows what the pin protects. It is not schema drift:
#
#   * `_type_rejects_nil?` reading an inert type entry as authoritative hands `allow_nil: true` to EVERY other
#     validator on the field, so a nil passes with nothing left to reject it.
#   * `_reconcile_emptiness_axis!` defers `allow_empty: false` to a floor that never runs, so the flag is
#     silently unenforced.
#
# Those are both runtime holes. Failing here, at the commit that would cause one, is the point.
#
# Assigning configs directly (`internal_field_configs=`, a public writer several call sites already document as
# bypassing the declaration walk) sidesteps both pins by design, and costs nothing: the two consequences above
# live on the DECLARATION path, so a config that never went through it never reaches them. An assigned bag
# carrying an `:on` leaves runtime behaviour untouched and moves only the emitted schema, in the stricter
# direction — the same static-maximal treatment a closed `if:` gate already gets.
#
# Both pins are text scans, so they catch the spellings they are written against and not the idea. A
# derivation assembled at runtime (`config.with(**overrides)`) leaves no literal keyword to match and is
# invisible here. So a green run is not proof that the claim above holds — it is only the absence of the
# reachable ways to break it. Treat a change in this area as needing the argument made again, not as
# cleared by this file passing.
RSpec.describe "constructors of a stored validations bag" do
  # rubocop:disable Lint/ConstantDefinitionInBlock
  EXPECTED_CONSTRUCTORS = {
    # `_build_shape_member` (from a config `_parse_field_validations` produced) and `_parse_field_configs`.
    "lib/axn/core/contract.rb" => 2,
    # The declaration walk, from `_symbol_keyed_member_validations`.
    "lib/axn/core/contract/shape_declaration.rb" => 1,
    # The synthetic ambient root, whose bag is a literal `{}` and can carry nothing.
    "lib/axn/core/ambient_context.rb" => 1,
  }.freeze

  # Both spellings of construction are counted: these configs are `Data.define`d, so `Klass[...]` builds one
  # exactly as `.new` does, and a pin that saw only `.new` would leave the other spelling a silent hole.
  # `Axn::Internal::FieldConfig` is the field-NAME convention helper, a different thing that happens to share
  # the base name, so it is excluded by lookbehind rather than counted.
  CONSTRUCTOR_PATTERN = /(?<!Internal::)(?:Field|Shape)Config(?:\.new\b|\[)/

  # Deriving one config from another carries a bag too, and `Data#with` reaches neither seam: it runs the
  # class's own `initialize`, which validates `sensitive:`/`user_facing:` and nothing about validator entries.
  # The constructor scan cannot see such a site, because the class name is absent from it — the receiver is a
  # variable (`config.with(...)`) — so the bag-REPLACING form is pinned by its own keyword instead.
  #
  # The one pinned site is sound by construction rather than by inspection: `effective_validations` only
  # `reject`s entries, so it returns a subset of a bag a seam already cleared, and a subset cannot introduce a
  # key. That is the property a new site needs: every retained entry must be an unmodified entry from an
  # already-cleared bag. Dropping entries preserves it; rewriting a retained entry's VALUE does not, even
  # though it adds no key — that needs a seam.
  EXPECTED_BAG_DERIVATIONS = {
    "lib/axn/internal/reflection/schema.rb" => 1,
  }.freeze

  DERIVATION_PATTERN = /\.with\((?:[^()]|\([^()]*\))*\bvalidations:/
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def self.lib_root = File.expand_path("../../lib", __dir__)

  def scan_for(pattern)
    Dir.glob("#{self.class.lib_root}/**/*.rb").each_with_object({}) do |path, counts|
      hits = File.read(path).scan(pattern).size
      next if hits.zero?

      counts["lib#{path.delete_prefix(self.class.lib_root)}"] = hits
    end
  end

  it "constructs a stored bag in exactly the pinned places" do
    expect(scan_for(CONSTRUCTOR_PATTERN)).to eq(EXPECTED_CONSTRUCTORS)
  end

  it "re-derives a stored bag in exactly the pinned places" do
    expect(scan_for(DERIVATION_PATTERN)).to eq(EXPECTED_BAG_DERIVATIONS)
  end

  it "reads every one of them out of a guarded seam" do
    # A behavioural companion to the count above: each seam refuses a context-scoped entry, so a bag arriving
    # from one cannot carry an `:on` however it was declared.
    member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: String, on: :create } })

    expect do
      Class.new do
        include Axn
        expects :v, type: { klass: String, on: :create }
        def call = nil
      end
    end.to raise_error(ArgumentError, /`on:` inside type:/)

    expect do
      Class.new do
        include Axn
        expects :h, type: Hash, shape: { members: [member], container: Hash }
        def call = nil
      end
    end.to raise_error(ArgumentError, /`on:` inside type:/)
  end
end
