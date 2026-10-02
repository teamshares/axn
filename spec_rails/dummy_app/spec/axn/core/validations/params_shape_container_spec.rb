# frozen_string_literal: true

# `type: :params` admits a Hash and an `ActionController::Parameters`, which is not one. `ShapeValidator` checks the
# members of a value that `is_a?` the container and skips every other one, so the runtime's own reading decides each
# container: one both values are skips neither and declares; one either of them is not skips it without a word, and is
# refused. Needs real Parameters, so it lives here rather than in the non-Rails suite.
RSpec.describe "a raw shape: beside type: :params" do
  let(:sku) { Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } }, method_call: false) }

  # Every relation a container can have to the two: both are it (`Object`/`Kernel`/`BasicObject`, a module both
  # include), only a Hash is (`Hash`, `Enumerable`), only a Parameters value is (`ActionController::Parameters`), and
  # neither is (`Comparable`, `Data`, a custom class).
  let(:containers) do
    {
      "Hash" => Hash, "Object" => Object, "Kernel" => Kernel, "BasicObject" => BasicObject,
      "ActiveSupport::DeepMergeable" => ActiveSupport::DeepMergeable, "Enumerable" => Enumerable, "Comparable" => Comparable,
      "ActionController::Parameters" => ActionController::Parameters, "Data" => Data, "a custom class" => Class.new
    }
  end

  def positions(shape)
    raw = Axn::Core::Contract::ShapeConfig.new(field: :val, validations: { type: { klass: :params }, shape: })
    {
      "field" => [proc { expects :val, type: :params, shape: }, ->(value) { { val: value } }],
      "raw member" => [proc { expects :o, type: Hash, shape: { members: [raw] } }, ->(value) { { o: { val: value } } }],
      "of: bag" => [proc { expects :val, type: Array, of: { klass: :params, shape: } }, ->(value) { { val: [value] } }],
      "map axis" => [proc { expects :val, type: Hash, of: { values: { klass: :params, shape: } } }, ->(value) { { val: { k: value } } }],
    }
  end

  # Declared, the members are checked on a Parameters value exactly as on the same members sent as a Hash.
  def outcome(name, body, payload)
    klass = build_axn(&body)
    [{ "sku" => 5 }, { "sku" => "a" }, {}].each do |members|
      as_hash = klass.call(**payload.call(members)).ok?
      as_params = klass.call(**payload.call(ActionController::Parameters.new(members))).ok?
      expect(as_params).to eq(as_hash), "#{name} #{members.inspect}: Hash ok=#{as_hash}, Parameters ok=#{as_params}"
    end
    :declared
  rescue ArgumentError => e
    expect(e.message).to match(/\A`container: .*` isn't allowed in `shape:`/)
    :refused
  end

  it "declares exactly where both a Hash and a Parameters value are the container" do
    verdicts = containers.to_h do |name, container|
      skipped = [{ "sku" => 5 }, ActionController::Parameters.new("sku" => 5)].reject { |value| value.is_a?(container) }
      outcomes = positions({ container:, members: [sku] }).map { |position, (body, payload)| outcome("#{name} #{position}", body, payload) }
      expect(outcomes.uniq.size).to eq(1), "#{name}: #{outcomes.inspect} across positions"
      [name, [outcomes.first, skipped.empty? ? :declared : :refused]]
    end

    verdicts.each { |name, (verdict, runtime)| expect(verdict).to eq(runtime), "#{name}: #{verdict}, the runtime reading is #{runtime}" }
    expect(verdicts.values.map(&:first)).to include(:declared, :refused)
  end
end
