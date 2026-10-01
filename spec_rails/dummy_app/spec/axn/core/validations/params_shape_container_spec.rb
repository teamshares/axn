# frozen_string_literal: true

# `type: :params` admits an `ActionController::Parameters`, which is not a Hash, so a raw `shape:` whose `container:`
# only a Hash passes would check a Hash's members and skip a Parameters value's without a word. A declaration either
# refuses, or checks a Parameters value's members exactly as it checks the same members sent as a Hash. Needs real
# Parameters, so it lives here rather than in the non-Rails suite.
RSpec.describe "a raw shape: beside type: :params" do
  let(:sku) { Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } }, method_call: false) }

  def positions(shape)
    raw = Axn::Core::Contract::ShapeConfig.new(field: :val, validations: { type: { klass: :params }, shape: })
    {
      "field" => [proc { expects :val, type: :params, shape: }, ->(value) { { val: value } }],
      "raw member" => [proc { expects :o, type: Hash, shape: { members: [raw] } }, ->(value) { { o: { val: value } } }],
      "of: bag" => [proc { expects :val, type: Array, of: { klass: :params, shape: } }, ->(value) { { val: [value] } }],
      "map axis" => [proc { expects :val, type: Hash, of: { values: { klass: :params, shape: } } }, ->(value) { { val: { k: value } } }],
    }
  end

  it "checks a Parameters value's members wherever it declares, or refuses" do
    declared = []
    refused = []
    { "Hash" => Hash, "Object" => Object, "Kernel" => Kernel, "Enumerable" => Enumerable }.each do |container_name, container|
      positions({ container:, members: [sku] }).each do |position, (body, payload)|
        klass = begin
          build_axn(&body)
        rescue ArgumentError => e
          refused << "#{container_name} #{position}"
          expect(e.message).to match(/\A`container: #{container_name}` isn't allowed in `shape:`/)
          next
        end
        declared << "#{container_name} #{position}"
        [{ "sku" => 5 }, { "sku" => "a" }, {}].each do |members|
          as_hash = klass.call(**payload.call(members)).ok?
          as_params = klass.call(**payload.call(ActionController::Parameters.new(members))).ok?
          expect(as_params).to eq(as_hash), "#{container_name} #{position} #{members.inspect}: Hash ok=#{as_hash}, Parameters ok=#{as_params}"
        end
      end
    end

    expect(refused).to include("Hash field", "Hash raw member", "Hash of: bag", "Hash map axis")
    expect(declared).to include("Object field", "Kernel field")
  end
end
