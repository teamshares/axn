# frozen_string_literal: true

require "axn/testing/spec_helpers"

# `if:`/`unless:`/`allow_nil:`/`allow_blank:` inside a `model:` bag reach only `ModelValidator`, never presence or
# the lookup. On `expects` a bag gate skips the record checks while a required field still looks up and fails
# "not found"; on `exposes` it skips only the record-type check while presence is still enforced. The tolerance
# keys admit nothing the field does not already admit, except that `allow_blank: false` makes an `optional:` one
# required again. All four are refused by key presence at every position, in both directions.
RSpec.describe "a gate or tolerance key inside a model: bag" do
  before do
    stub_const("Company", Struct.new(:id) { def self.find(id) = id.to_s == "1" ? new(1) : nil })
  end

  define_method(:expected_message) do |direction, key|
    head = "`#{key}:` isn't allowed inside `model:` on #{direction} :company — "
    if %i[if unless].include?(key)
      fix = "put the condition on the declaration: `#{direction} :company, model: …, #{key}: …`"
      if direction == :expects
        "#{head}#{fix}. Inside the bag a gate reaches only the record checks (the record type, the record/id match, " \
          "the not-found report), never the lookup, which runs whenever the field is read, including by a required " \
          "field's presence check."
      else
        "#{head}#{fix} (or `optional: true` if only the requirement should go). Inside the bag a gate reaches only " \
          "the record-type check, while presence is still enforced, so a nil exposure fails whatever the condition says."
      end
    else
      subject = direction == :expects ? "field" : "exposure"
      "#{head}declare the tolerance on the declaration: `#{direction} :company, model: …, optional: true`. " \
        "`allow_nil:` and `allow_blank: true` inside the bag admit nothing the #{subject} does not already admit, " \
        "and `allow_blank: false` makes an `optional:` #{subject} required again."
    end
  end

  positions = {
    "top-level expects" => [:expects, ->(bag, **decl) { expects :company, model: bag, **decl }],
    "on: subfield expects" => [:expects, lambda { |bag, **decl|
      expects :payload, type: Hash
      expects :company, on: :payload, model: bag, **decl
    }],
    "dotted on: subfield expects" => [:expects, lambda { |bag, **decl|
      expects :payload, type: Hash
      expects :company, on: "payload.inner", model: bag, **decl
    }],
    "exposes" => [:exposes, ->(bag, **decl) { exposes :company, model: bag, **decl }],
  }.freeze

  define_method(:declare) do |position, bag, **decl|
    body = positions.fetch(position).last
    build_axn { instance_exec(bag, **decl, &body) }
  end

  refused = {
    if: [-> { true }, :flag?, nil, ""],
    unless: [-> { false }, :flag?, nil],
    allow_nil: [true, false, nil],
    allow_blank: [true, false, nil],
  }.freeze

  positions.each do |position, (direction, _body)|
    describe "on a #{position}" do
      refused.each do |key, values|
        values.each do |value|
          it "refuses #{key}: #{value.is_a?(Proc) ? 'a Proc' : value.inspect}" do
            expect { declare(position, { klass: Company, key => value }) }
              .to raise_error(ArgumentError, expected_message(direction, key))
          end
        end
      end

      it "declares with every other bag key" do
        bag = { klass: Company, finder: :find, not_found_on: [StandardError], message: "no such company" }
        bag[:id_type] = Integer if direction == :expects
        expect { declare(position, bag) }.not_to raise_error
      end

      it "declares with a declaration-level if:/unless:/optional:/allow_nil:/allow_blank:" do
        [{ if: -> { true } }, { unless: -> { false } }, { optional: true }, { allow_nil: true }, { allow_blank: true }].each do |decl|
          expect { declare(position, { klass: Company, finder: :find }, **decl) }.not_to raise_error
        end
      end
    end
  end

  { expects: :expects, exposes: :exposes }.each_key do |direction|
    it "refuses through Axn::Factory.build on #{direction}" do
      expect { Axn::Factory.build(direction => { company: { model: { klass: Company, if: -> { false } } } }) { nil } }
        .to raise_error(ArgumentError, expected_message(direction, :if))
    end
  end

  it "refuses a String-keyed spelling" do
    expect { build_axn { expects :company, model: { klass: Company, "allow_blank" => false } } }
      .to raise_error(ArgumentError, expected_message(:expects, :allow_blank))
    expect { build_axn { exposes :company, model: { klass: Company, "if" => nil } } }
      .to raise_error(ArgumentError, expected_message(:exposes, :if))
  end

  it "names every offending key in one refusal, gist first, then each fix, then why" do
    expect { build_axn { expects :company, model: { klass: Company, allow_nil: true, if: -> { true }, unless: :x? } } }
      .to raise_error(ArgumentError) { |error|
        expect(error.message).to start_with(
          "`if:` / `unless:` / `allow_nil:` aren't allowed inside `model:` on expects :company — put the condition on " \
          "the declaration: `expects :company, model: …, if: …`; declare the tolerance there too: " \
          "`expects :company, model: …, optional: true`. Inside the bag a gate reaches only the record checks",
        ).and end_with("makes an `optional:` field required again.")
      }
    expect { build_axn { exposes :company, model: { klass: Company, allow_blank: true, unless: :x? } } }
      .to raise_error(ArgumentError) { |error|
        expect(error.message).to start_with(
          "`unless:` / `allow_blank:` aren't allowed inside `model:` on exposes :company — put the condition on the " \
          "declaration: `exposes :company, model: …, unless: …`; declare the tolerance there too: " \
          "`exposes :company, model: …, optional: true`. Inside the bag a gate reaches only the record-type check",
        ).and end_with("makes an `optional:` exposure required again.")
      }
  end

  it "advertises only the keys a model: bag accepts on an unknown key" do
    expect { build_axn { exposes :company, model: { klass: Company, bogus: 1 } } }
      .to raise_error(ArgumentError, "model: does not support bogus: (supported: klass:, finder:, not_found_on:, id_type:, message:)")
  end

  # This refusal comes first; the bag's `on:`/`except_on:`/`strict:` refusals still own a bag without these keys.
  it "reports ahead of the bag's strict:/on:/except_on: refusals, which still fire alone" do
    %i[expects exposes].each do |direction|
      expect { build_axn { public_send(direction, :company, model: { klass: Company, if: -> { true }, strict: true }) } }
        .to raise_error(ArgumentError, expected_message(direction, :if))
      expect { build_axn { public_send(direction, :company, model: { klass: Company, strict: true }) } }
        .to raise_error(ArgumentError, /`strict:` inside model:/)
      expect { build_axn { public_send(direction, :company, model: { klass: Company, on: :create }) } }
        .to raise_error(ArgumentError, /`on:` inside model:/)
      expect { build_axn { public_send(direction, :company, model: { klass: Company, except_on: :create }) } }
        .to raise_error(ArgumentError, /`except_on:` inside model:/)
    end
  end

  describe "the declaration-level spellings the refusal points at" do
    it "skips the lookup and the record checks on expects with a closed declaration if:" do
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

    it "admits an omitted id on expects with a declaration optional:" do
      action = build_axn do
        expects :company, model: { klass: Company, finder: :find }, optional: true
        def call; end
      end

      expect(action.call).to be_ok
    end

    it "waives the record-type check and presence on exposes with a closed declaration if:" do
      action = build_axn do
        expects :value, optional: true, allow_nil: true
        exposes :company, model: { klass: Company }, if: -> { false }
        def call = expose(company: value)
      end

      expect(action.call(value: "not a record")).to be_ok
      expect(action.call(value: nil)).to be_ok
    end

    it "admits a nil exposure with a declaration optional:, and still checks a present one" do
      action = build_axn do
        expects :value, optional: true, allow_nil: true
        exposes :company, model: { klass: Company }, optional: true
        def call = expose(company: value)
      end

      expect(action.call(value: nil)).to be_ok
      expect(action.call(value: "not a record")).not_to be_ok
    end
  end
end
