# frozen_string_literal: true

# The schema states "the id must name a record the model lookup finds" exactly where the runtime rejects an id
# that finds none. A nil-tolerant model resolves a miss to nil, so its own validators no longer reject it, but
# what hangs beneath it still can: a required descendant reads absent under a nil parent. This derives the claim
# from the runtime over tolerance x descendant x sibling x position, instead of listing the shapes that happen
# to matter, so a rejection reached some other way fails here rather than in review.
RSpec.describe "the model lookup residue against the runtime's verdict on an unknown id" do
  record_class = Struct.new(:name) do
    def self.find_by_id(id) = id == 7 ? new("widget") : nil
  end

  tolerances = {
    "required" => "",
    "optional" => ", optional: true",
    "allow_nil" => ", allow_nil: true",
    "allow_blank" => ", allow_blank: true",
    "presence-only tolerance" => ", presence: { allow_nil: true }",
    "allow_nil beside presence: true" => ", allow_nil: true, presence: true",
  }
  descendants = {
    "no descendant" => nil,
    "a required descendant" => "expects :name, on: :company",
    "a required typed descendant" => "expects :name, on: :company, type: String",
    "an optional descendant" => "expects :name, on: :company, optional: true",
    "a defaulted descendant" => "expects :name, on: :company, default: 'x'",
  }
  siblings = {
    "no id sibling" => nil,
    "a defaulted id sibling" => "expects :company_id, default: 7",
    "an optional id sibling" => "expects :company_id, optional: true",
  }

  def declare(record_class, source)
    stub_const("ResidueMatrixRecord", record_class)
    Class.new { include Axn }.tap { |action| action.class_eval(source) }
  rescue ArgumentError
    nil # refused at declaration: no call can reach it
  end

  def lookup_residue?(action)
    action.input_schema_residues.any? { |residue| residue.summary.include?("model lookup finds") }
  end

  cells = []
  %i[top nested].each do |position|
    tolerances.each do |tolerance, tolerance_source|
      descendants.each do |descendant, descendant_source|
        siblings.each do |sibling, sibling_source|
          model = "model: { klass: ResidueMatrixRecord, finder: :find_by_id }#{tolerance_source}"
          source =
            if position == :top
              [sibling_source, "expects :company, #{model}", descendant_source]
            else
              ["expects :data", sibling_source&.sub(":company_id", ":company_id, on: :data"),
               "expects :company, on: :data, #{model}", descendant_source]
            end.compact.join("\n")
          miss = position == :top ? { company_id: 99 } : { data: { company_id: 99 } }
          cells << ["#{position} | #{tolerance} | #{descendant} | #{sibling}", source, miss]
        end
      end
    end
  end

  it "states the lookup wherever the runtime rejects an unknown id, and nowhere it accepts one" do
    declared = []
    tolerant_rejecting = 0
    missing = []
    over_claimed = []

    cells.each do |label, source, miss|
      action = declare(record_class, source)
      next if action.nil?

      declared << label
      result = action.call(**miss)
      rejects = !result.ok? && result.exception.is_a?(Axn::InboundValidationError)
      residue = lookup_residue?(action)
      tolerant_rejecting += 1 if rejects && !label.include?("| required |")
      missing << "#{label}: rejected (#{result.exception.message}) but the schema states no lookup" if rejects && !residue
      over_claimed << label if residue && !rejects
    end

    expect(declared.size).to be > 100
    expect(tolerant_rejecting).to be > 10 # the descendant-stranded shapes this exists to catch are present
    expect(missing).to be_empty, "runtime rejects, schema silent:\n  #{missing.first(20).join("\n  ")}"
    expect(over_claimed).to be_empty, "schema states a lookup the runtime does not enforce:\n  #{over_claimed.first(20).join("\n  ")}"
  end
end
