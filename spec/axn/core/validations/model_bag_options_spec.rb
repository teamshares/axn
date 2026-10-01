# frozen_string_literal: true

require "axn/testing/spec_helpers"

# `if:`/`unless:`/`allow_nil:`/`allow_blank:` inside a `model:` bag reach only `ModelValidator`, never presence or
# the lookup, so what the whole declaration accepts depends on its other options. All four are refused by key
# presence at every position, in both directions, and the message says only what the key reaches.
RSpec.describe "a gate or tolerance key inside a model: bag" do
  before do
    stub_const("Company", Struct.new(:id) { def self.find(id) = id.to_s == "1" ? new(1) : nil })
  end

  define_method(:expected_message) do |direction, key, field = ":company"|
    head = "`#{key}:` isn't allowed inside `model:` on #{direction} #{field} — "
    if %i[if unless].include?(key)
      reach = if direction == :expects
                "the record check (the record's type, the record/id match, the not-found report), never the lookup or presence"
              else
                "the record-type check, never presence"
              end
      "#{head}put the condition on the declaration: `#{direction} :company, model: …, #{key}: …`. Inside the bag a gate " \
        "reaches only #{reach}; on the declaration it gates presence too."
    else
      check = direction == :expects ? "the record check" : "the record-type check"
      "#{head}set the tolerance on the declaration: `optional:`, `allow_nil:` or `allow_blank:`. Inside the bag a " \
        "tolerance reaches only whether #{check} runs on a nil or blank value, never presence."
    end
  end

  positions = {
    "top-level expects" => [:expects, ->(bag, **decl) { expects :company, model: bag, **decl }, ":company"],
    "on: subfield expects" => [:expects, lambda { |bag, **decl|
      expects :payload, type: Hash
      expects :company, on: :payload, model: bag, **decl
    }, "payload.company"],
    "dotted on: subfield expects" => [:expects, lambda { |bag, **decl|
      expects :payload, type: Hash
      expects :company, on: "payload.inner", model: bag, **decl
    }, "payload.inner.company"],
    "exposes" => [:exposes, ->(bag, **decl) { exposes :company, model: bag, **decl }, ":company"],
  }.freeze

  define_method(:declare) do |position, bag, **decl|
    body = positions.fetch(position)[1]
    build_axn { instance_exec(bag, **decl, &body) }
  end

  refused = {
    if: [-> { true }, :flag?, nil, ""],
    unless: [-> { false }, :flag?, nil],
    allow_nil: [true, false, nil],
    allow_blank: [true, false, nil],
  }.freeze

  positions.each do |position, (direction, _body, field)|
    describe "on a #{position}" do
      refused.each do |key, values|
        values.each do |value|
          it "refuses #{key}: #{value.is_a?(Proc) ? 'a Proc' : value.inspect}" do
            expect { declare(position, { klass: Company, key => value }) }
              .to raise_error(ArgumentError, expected_message(direction, key, field))
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

  it "names every offending key in one refusal, gist first, then each fix, then what the keys reach" do
    expect { build_axn { expects :company, model: { klass: Company, allow_nil: true, if: -> { true }, unless: :x? } } }
      .to raise_error(
        ArgumentError,
        "`if:` / `unless:` / `allow_nil:` aren't allowed inside `model:` on expects :company — put the condition on the " \
        "declaration: `expects :company, model: …, if: …`; set the tolerance there too: `optional:`, `allow_nil:` or " \
        "`allow_blank:`. Inside the bag a gate reaches only the record check (the record's type, the record/id match, " \
        "the not-found report), never the lookup or presence; on the declaration it gates presence too. A tolerance " \
        "there reaches only whether the record check runs on a nil or blank value, never presence.",
      )
    expect { build_axn { exposes :company, model: { klass: Company, allow_blank: true, unless: :x? } } }
      .to raise_error(
        ArgumentError,
        "`unless:` / `allow_blank:` aren't allowed inside `model:` on exposes :company — put the condition on the " \
        "declaration: `exposes :company, model: …, unless: …`; set the tolerance there too: `optional:`, `allow_nil:` " \
        "or `allow_blank:`. Inside the bag a gate reaches only the record-type check, never presence; on the declaration " \
        "it gates presence too. A tolerance there reaches only whether the record-type check runs on a nil or blank " \
        "value, never presence.",
      )
  end

  # Whether the whole field accepts a nil depends on the declaration's other options, so the refusal says only
  # what the bag key reaches, and every bag spelling has a declaration-level one that behaves the same.
  describe "where the declaration's other options decide what the field accepts" do
    # Beside `presence: false`, a bag `allow_nil: true` let a nil or omitted company through.
    it "refuses a bag allow_nil: beside presence: false, whose contract the declaration's optional: states" do
      expect { build_axn { expects :company, model: { klass: Company, allow_nil: true }, presence: false } }
        .to raise_error(ArgumentError, expected_message(:expects, :allow_nil))

      action = build_axn do
        expects :company, model: { klass: Company, finder: :find }, optional: true
        def call = company
        nil
      end
      expect(action.call).to be_ok
      expect(action.call(company_id: nil)).to be_ok
      expect(action.call(company_id: 1)).to be_ok
      expect(action.call(company: "not a record")).not_to be_ok
    end

    # Beside `optional: true`, a closed bag gate let a nil and a non-record exposure through.
    it "refuses a bag if: on an optional exposure, whose contract the declaration's if: states" do
      expect { build_axn { exposes :company, model: { klass: Company, if: -> { false } }, optional: true } }
        .to raise_error(ArgumentError, expected_message(:exposes, :if))

      action = build_axn do
        expects :value, optional: true, allow_nil: true
        exposes :company, model: { klass: Company }, optional: true, if: -> { false }
        def call = expose(company: value)
      end
      expect(action.call(value: nil)).to be_ok
      expect(action.call(value: "not a record")).to be_ok
    end
  end

  it "advertises only the keys a model: bag accepts on an unknown key" do
    expect { build_axn { exposes :company, model: { klass: Company, bogus: 1 } } }
      .to raise_error(ArgumentError, "model: does not support bogus: on exposes :company (supported: klass:, finder:, not_found_on:, id_type:, message:)")
  end

  # This refusal comes first; the bag's `on:`/`except_on:`/`strict:` refusals still own a bag without these keys.
  it "reports ahead of the bag's strict:/on:/except_on: refusals, which still fire alone" do
    %i[expects exposes].each do |direction|
      expect { build_axn { public_send(direction, :company, model: { klass: Company, if: -> { true }, strict: true }) } }
        .to raise_error(ArgumentError, expected_message(direction, :if))
      expect { build_axn { public_send(direction, :company, model: { klass: Company, strict: true }) } }
        .to raise_error(ArgumentError, /`strict:` isn't allowed in model:/)
      expect { build_axn { public_send(direction, :company, model: { klass: Company, on: :create }) } }
        .to raise_error(ArgumentError, /`on:` isn't allowed in model:/)
      expect { build_axn { public_send(direction, :company, model: { klass: Company, except_on: :create }) } }
        .to raise_error(ArgumentError, /`except_on:` isn't allowed in model:/)
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
