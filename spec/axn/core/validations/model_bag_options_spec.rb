# frozen_string_literal: true

require "axn/testing/spec_helpers"

# `if:`/`unless:`/`allow_nil:`/`allow_blank:` inside an inbound `model:` bag reach only `ModelValidator`, never the
# lookup, which runs whenever the field is read. A bag gate skips the record checks while a required field still
# looks up and fails "not found"; the tolerance keys change nothing, except `allow_blank: false`, which makes an
# `optional:` field required again. All four are refused by key presence at every `expects` position.
RSpec.describe "a gate or tolerance key inside an inbound model: bag" do
  before do
    stub_const("Company", Struct.new(:id) { def self.find(id) = id.to_s == "1" ? new(1) : nil })
  end

  gate_message = Regexp.new(
    "\\A`(if|unless):` #{Regexp.escape('inside model: on :company only gates the record checks (the record type, the ' \
                                       'record/id match, the not-found report), never the lookup, which runs whenever ' \
                                       'the field is read — the presence check on a required field included. Put the ' \
                                       'condition on the declaration: `expects :company, model: …, ')}(if|unless): …`\\.\\z",
  )
  tolerance_message = Regexp.new(
    "\\A`allow_(nil|blank):` #{Regexp.escape('inside model: on :company does not make the field optional: `allow_nil:` and ' \
                                             '`allow_blank: true` there change nothing, and `allow_blank: false` makes an ' \
                                             '`optional:` field required again. Declare the tolerance on the field: ' \
                                             '`expects :company, model: …, optional: true`.')}\\z",
  )

  positions = {
    "top-level" => ->(bag, **decl) { expects :company, model: bag, **decl },
    "on: subfield" => lambda { |bag, **decl|
      expects :payload, type: Hash
      expects :company, on: :payload, model: bag, **decl
    },
    "dotted on: subfield" => lambda { |bag, **decl|
      expects :payload, type: Hash
      expects :company, on: "payload.inner", model: bag, **decl
    },
  }.freeze

  define_method(:declare) do |position, bag, **decl|
    body = positions.fetch(position)
    build_axn { instance_exec(bag, **decl, &body) }
  end

  refused = {
    if: [-> { true }, :flag?, nil, ""],
    unless: [-> { false }, :flag?, nil],
    allow_nil: [true, false, nil],
    allow_blank: [true, false, nil],
  }.freeze

  positions.each_key do |position|
    describe "at a #{position}" do
      refused.each do |key, values|
        values.each do |value|
          it "refuses #{key}: #{value.is_a?(Proc) ? 'a Proc' : value.inspect}" do
            message = %i[if unless].include?(key) ? gate_message : tolerance_message
            expect { declare(position, { klass: Company, key => value }) }.to raise_error(ArgumentError, message)
          end
        end
      end

      it "declares with every other bag key" do
        bag = { klass: Company, finder: :find, not_found_on: [StandardError], id_type: Integer, message: "no such company" }
        expect { declare(position, bag) }.not_to raise_error
      end

      it "declares with a declaration-level if:/unless:/optional:/allow_nil:/allow_blank:" do
        [{ if: -> { true } }, { unless: -> { false } }, { optional: true }, { allow_nil: true }, { allow_blank: true }].each do |decl|
          expect { declare(position, { klass: Company, finder: :find }, **decl) }.not_to raise_error
        end
      end
    end
  end

  it "refuses through Axn::Factory.build" do
    expect { Axn::Factory.build(expects: { company: { model: { klass: Company, if: -> { false } } } }) { nil } }
      .to raise_error(ArgumentError, gate_message)
  end

  it "refuses a String-keyed spelling" do
    expect { build_axn { expects :company, model: { klass: Company, "allow_blank" => false } } }
      .to raise_error(ArgumentError, tolerance_message)
  end

  it "names a gate and a tolerance key together in one refusal" do
    expect { build_axn { expects :company, model: { klass: Company, allow_nil: true, if: -> { true } } } }
      .to raise_error(ArgumentError, /\A`if:` inside model: .* `allow_nil:` inside model: /)
  end

  # This refusal comes first; the bag's `on:`/`except_on:`/`strict:` refusals still own a bag without these keys.
  it "reports ahead of the bag's strict:/on:/except_on: refusals, which still fire alone" do
    expect { build_axn { expects :company, model: { klass: Company, if: -> { true }, strict: true } } }
      .to raise_error(ArgumentError, gate_message)
    expect { build_axn { expects :company, model: { klass: Company, strict: true } } }
      .to raise_error(ArgumentError, /`strict:` inside model:/)
    expect { build_axn { expects :company, model: { klass: Company, on: :create } } }
      .to raise_error(ArgumentError, /`on:` inside model:/)
    expect { build_axn { expects :company, model: { klass: Company, except_on: :create } } }
      .to raise_error(ArgumentError, /`except_on:` inside model:/)
  end

  describe "the declaration-level spellings the refusal points at" do
    it "skips the lookup and the record checks with a closed declaration if:" do
      calls = 0
      stub_const("Company", Struct.new(:id) { define_singleton_method(:find) { |_id| (calls += 1) && nil } })
      action = build_axn do
        expects :company, model: { klass: Company, finder: :find }, if: -> { false }
        def call; end
      end

      expect(action.call(company_id: 999)).to be_ok
      expect(action.call(company: "not a record")).to be_ok
      expect(calls).to eq(0)
    end

    it "admits an omitted id with a declaration optional:" do
      action = build_axn do
        expects :company, model: { klass: Company, finder: :find }, optional: true
        def call; end
      end

      expect(action.call).to be_ok
    end
  end

  # An exposure has no lookup: a bag gate there skips only the record-type check while presence still applies.
  it "leaves an exposes model: bag alone" do
    action = build_axn do
      exposes :company, model: { klass: Company, if: -> { false } }
      def call = expose(company: "not a record")
    end

    expect(action.call).to be_ok
  end
end
