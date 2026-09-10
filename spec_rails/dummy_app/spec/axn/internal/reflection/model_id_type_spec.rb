# frozen_string_literal: true

require "json_schemer"

# PRO-3384: a `model:` field's generated `<field>_id` is typed from the class's own ActiveRecord
# primary key when the finder is the default `:find` — an inference the non-Rails suite
# (spec/axn/internal/reflection/schema_spec.rb, "model: id_type:") cannot exercise because it needs a
# real database connection. This is the Rails-specific half AGENTS.md asks for: mirror an
# ActiveRecord-dependent `model:` behavior here, not in the gem's own spec/.
#
# It is also the positive control for `reflection_does_not_dispatch_spec.rb`'s doctrine amendment: that
# spec's probe token can never load ActiveRecord, so it can assert the AR branch is narrow but not that
# it is ever REACHED, or that a hostile answer from it degrades safely rather than taking the whole
# schema build down. The last two examples below are that proof.

# A custom AR type registered only on the attribute itself, not the adapter-wide type registry — this is
# exactly how a real Postgres uuid primary key answers `type_for_attribute(pk).type`, just declared here
# so the sqlite-backed dummy app can exercise AR_PRIMARY_KEY_TYPE_TOKENS[:uuid] without one. Top-level,
# not inside the example group: `establish_connection` (below) and a class constant both refuse to run
# inside a block ("Anonymous class is not allowed" / Lint/ConstantDefinitionInBlock).
class UuidType < ActiveRecord::Type::String
  def type = :uuid
end

# The unreachable-connection base `establish_connection` needs a NAMED class to run against at all.
class UnreachableConnectionBase < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: "/nonexistent-dir-pro-3384/db.sqlite3")
end

RSpec.describe "model: <field>_id type inference from an ActiveRecord primary key (PRO-3384)" do
  before(:all) do
    Rails.application.initialize! unless Rails.application.initialized?

    unless ActiveRecord::Base.connection.table_exists?(:string_pk_things)
      ActiveRecord::Base.connection.create_table(:string_pk_things, id: :string) { |t| t.string :name }
    end

    unless ActiveRecord::Base.connection.table_exists?(:uuid_pk_things)
      ActiveRecord::Base.connection.create_table(:uuid_pk_things, id: :string) { |t| t.string :name }
    end

    unless ActiveRecord::Base.connection.table_exists?(:composite_pk_things)
      ActiveRecord::Base.connection.create_table(:composite_pk_things, primary_key: %i[a b]) do |t|
        t.string :a
        t.string :b
      end
    end
  end

  let(:string_pk_klass) { Class.new(ActiveRecord::Base) { self.table_name = "string_pk_things" } }
  let(:uuid_pk_klass) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "uuid_pk_things"
      attribute :id, UuidType.new
    end
  end
  let(:composite_pk_klass) { Class.new(ActiveRecord::Base) { self.table_name = "composite_pk_things" } }

  # `nullable:` is this helper's own flag (translated to `allow_nil: true` on the declaration); every
  # other keyword lands in the `model:` bag unchanged, so a caller spells exactly what it wants to
  # declare (`schema_for(klass: User, finder: :find_by)`, `schema_for(klass: User, id_type: String)`).
  def schema_for(nullable: false, **model_opts)
    klass = Class.new do
      include Axn

      if nullable
        expects :record, model: model_opts, allow_nil: true
      else
        expects :record, model: model_opts
      end
      def call = nil
    end
    klass.input_schema
  end

  it "types the generated id as integer from an integer primary key" do
    schema = schema_for(klass: User)

    expect(schema[:properties][:record_id]).to include(type: "integer")
    expect(schema[:properties][:record_id]).not_to have_key(:not)
  end

  it "types the generated id as string from a string primary key" do
    schema = schema_for(klass: string_pk_klass)

    expect(schema[:properties][:record_id]).to include(type: "string")
  end

  it "types the generated id as a uuid, format included, from a uuid-typed primary key" do
    schema = schema_for(klass: uuid_pk_klass)

    expect(schema[:properties][:record_id]).to include(type: "string", format: "uuid")
  end

  it "leaves the id untyped for a custom finder, even on an ActiveRecord class (the id token has no " \
     "reason to share the primary key's type)" do
    schema = schema_for(klass: User, finder: :find_by)

    expect(schema[:properties][:record_id]).not_to have_key(:type)
  end

  it "lets a declared id_type: win over inference outright, even under the default :find finder" do
    schema = schema_for(klass: User, id_type: String)

    expect(schema[:properties][:record_id]).to include(type: "string")
  end

  it "falls back untyped for a composite primary key (a documented non-goal of the <field>_id " \
     "reader convention)" do
    schema = schema_for(klass: composite_pk_klass)

    expect(schema[:properties][:record_id]).not_to have_key(:type)
  end

  it "admits null for an optional model field's inferred id, and the requiredness pass still " \
     "strips it once the field is required" do
    optional_schema = schema_for(klass: User, nullable: true)
    required_schema = schema_for(klass: User)

    expect(optional_schema[:properties][:record_id][:type]).to eq(%w[integer null])
    expect(Array(optional_schema[:required])).not_to include("record_id")

    expect(required_schema[:properties][:record_id]).to include(type: "integer")
    expect(required_schema[:properties][:record_id]).not_to have_key(:not)
    expect(required_schema[:required]).to include("record_id")
  end

  it "types a NESTED on: model subfield's generated id from the primary key too" do
    klass = Class.new do
      include Axn

      expects :payload, type: Hash
      expects :record, on: :payload, model: { klass: User }
      def call = nil
    end
    payload = klass.input_schema[:properties][:payload]

    expect(payload[:properties][:record_id]).to include(type: "integer")
  end

  # Codex review round 5 (PR #269): a merged nested node with one route declaring `id_type:` and
  # another route (no id_type: of its own) pointing at a real AR class raised, since the declared and
  # AR-inferred tokens were reconciled as two equally-weighted, disagreeing candidates. A DECLARED
  # `id_type:` must win outright over another route's mere inference, never merely be one candidate
  # among the inferred ones.
  it "lets a declared id_type: on one merged-node route win over another route's AR-inferred type, " \
     "rather than treating them as disagreeing candidates" do
    other_klass = string_pk_klass
    klass = Class.new do
      include Axn

      expects :payload, type: Hash
      expects :user, on: "payload.account", model: { klass: User, id_type: Integer }, as: :user_route1
      expects :account, on: :payload, type: Hash
      expects :user, on: :account, model: { klass: other_klass }
      def call = nil
    end

    account = klass.input_schema[:properties][:payload][:properties][:account]
    expect(account[:properties][:user_id]).to include(type: "integer")
  end

  # Codex review round 6 (PR #269): two merged-node routes with NEITHER declaring `id_type:`, each
  # backed by a real AR class with a DIFFERENT primary-key column type, raised — even though neither
  # author ever asked for a type check on this property; it's an inference-only disagreement (two
  # legitimate model routes just happen to point at classes with different PK types), not an authored
  # contradiction. Since `Axn::Tools.validate_contracts!` builds `.input_schema` at app boot, raising
  # here could take an otherwise-working application down over a schema NICETY. Falls back to the
  # untyped property instead, same as every other "can't confidently infer" case.
  it "falls back untyped, rather than raising, when two merged-node routes' INFERRED types disagree " \
     "and neither declares id_type:" do
    other_klass = string_pk_klass
    klass = Class.new do
      include Axn

      expects :payload, type: Hash
      expects :user, on: "payload.account", model: { klass: User }, as: :user_route1
      expects :account, on: :payload, type: Hash
      expects :user, on: :account, model: { klass: other_klass }
      def call = nil
    end

    account = nil
    expect { account = klass.input_schema[:properties][:payload][:properties][:account] }.not_to raise_error
    expect(account[:properties][:user_id]).not_to have_key(:type)
  end

  it "falls back untyped rather than raising when the class's own primary_key raises" do
    hostile = Class.new(ActiveRecord::Base) do
      self.table_name = "string_pk_things"
      define_singleton_method(:primary_key) { raise "boom (simulated hostile primary_key)" }
    end

    schema = nil
    expect { schema = schema_for(klass: hostile) }.not_to raise_error
    expect(schema[:properties][:record_id]).not_to have_key(:type)
  end

  it "falls back untyped rather than raising when the connection is unreachable" do
    unreachable = Class.new(UnreachableConnectionBase) { self.table_name = "string_pk_things" }

    schema = nil
    expect { schema = schema_for(klass: unreachable) }.not_to raise_error
    expect(schema[:properties][:record_id]).not_to have_key(:type)
  end

  # Codex review round 6 (PR #269) raised a related concern that measured false: that a model route's
  # own `allow_blank: true` could strip the `format: "uuid"` `type_allows_blank?` normally drops for a
  # blank-tolerant `type: :uuid` FIELD. It can't — `type_allows_blank?` reads `config.validations[:type]`,
  # which a `model:` config never carries at all (its own type comes from `id_type:`/inference, not a
  # `type:` validator), so the check is unreachable for a model config regardless of `allow_blank:`.
  # Pinned directly here rather than only by absence of a failure elsewhere.
  it "never drops a uuid id_type:'s format due to allow_blank: on the model field itself" do
    klass = uuid_pk_klass
    action = Class.new do
      include Axn

      expects :record, model: { klass:, id_type: :uuid }, allow_blank: true
      def call = nil
    end

    record_id = action.input_schema[:properties][:record_id]
    expect(record_id[:format]).to eq("uuid")
    expect(Array(record_id[:type])).to include("string")
  end

  describe "against a real JSON Schema engine" do
    def accepts?(prop, value)
      JSONSchemer.schema(prop.transform_keys(&:to_s)).valid?(value)
    end

    it "the inferred integer property accepts an integer id and rejects a string one" do
      prop = schema_for(klass: User)[:properties][:record_id]

      expect(accepts?(prop, 1)).to be true
      expect(accepts?(prop, "1")).to be false
    end

    it "the inferred uuid property accepts a uuid string and rejects an integer" do
      prop = schema_for(klass: uuid_pk_klass)[:properties][:record_id]

      expect(accepts?(prop, "0f8fad5b-d9cb-469f-a165-70867728950e")).to be true
      expect(accepts?(prop, 1)).to be false
    end

    it "the nullable inferred property accepts null" do
      prop = schema_for(klass: User, nullable: true)[:properties][:record_id]

      expect(accepts?(prop, nil)).to be true
      expect(accepts?(prop, 1)).to be true
    end
  end
end
