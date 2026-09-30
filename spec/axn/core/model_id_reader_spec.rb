# frozen_string_literal: true

# Non-Rails coverage for the `model:` id reader (`<field>_id`) and the record/id
# consistency check. Uses plain POROs with finders so it runs outside Rails.
RSpec.describe "model: id reader and consistency" do
  let(:co_class) do
    Class.new do
      def self.name = "Co"
      attr_reader :id

      def initialize(id) = @id = id
      # default finder: by primary key
      def self.find(id) = new(id)
      def ==(other) = other.is_a?(self.class) && other.id == id
    end
  end

  # Custom finder: looks a record up by a NON-id token. The token lives in the `<field>_id` key.
  let(:directory_class) do
    co = co_class
    Class.new do
      define_singleton_method(:find_by_token) { |tok| tok == "abc" ? co.new(42) : nil }
    end
  end

  describe "`<field>_id` reader — default finder (the pk)" do
    let(:action) do
      klass = co_class
      build_axn do
        expects :company, model: { klass:, finder: :find }
        exposes :cid

        def call = expose(cid: company_id)
      end
    end

    it "returns the supplied id directly when only an id is given" do
      expect(action.call(company_id: 5).cid).to eq(5)
    end

    it "returns the record's id when a record is given" do
      expect(action.call(company: co_class.new(7)).cid).to eq(7)
    end

    it "treats a blank id as absent, returning the record's pk (form-params case)" do
      # A record alongside `company_id: ""` (common from form params): the blank id is not the pk,
      # so the reader must fall through to the record's id rather than exposing "".
      expect(action.call(company: co_class.new(7), company_id: "").cid).to eq(7)
    end
  end

  describe "`<field>_id` reader — custom finder (still the pk, via the resolved record)" do
    let(:action) do
      klass = co_class
      dir = directory_class
      build_axn do
        expects :company, model: { klass:, finder: dir.method(:find_by_token) }
        exposes :cid

        def call = expose(cid: company_id)
      end
    end

    it "returns the resolved record's primary key, not the lookup token" do
      result = action.call(company_id: "abc")
      expect(result).to be_ok
      expect(result.cid).to eq(42)
    end
  end

  describe "`<field>_id` reader — custom finder with no match" do
    let(:action) do
      klass = co_class
      dir = directory_class
      build_axn do
        expects :company, model: { klass:, finder: dir.method(:find_by_token) }, allow_nil: true
        exposes :cid, allow_nil: true

        def call = expose(cid: company_id)
      end
    end

    it "returns nil, not the unmatched lookup token, when no record resolves" do
      # The token "xyz" matches nothing, so the record is nil — `<field>_id` means "the record's
      # primary key", so it must be nil rather than leaking the (non-pk) lookup token.
      result = action.call(company_id: "xyz")
      expect(result).to be_ok
      expect(result.cid).to be_nil
    end
  end

  describe "`<field>_id` reader — alias aware" do
    let(:action) do
      klass = co_class
      build_axn do
        expects :company, model: { klass:, finder: :find }, as: :raw_company
        exposes :cid

        def call = expose(cid: raw_company_id)
      end
    end

    it "names the id reader after the alias" do
      expect(action.call(company_id: 9).cid).to eq(9)
    end
  end

  describe "`<field>_id` reader — does not clobber an explicit declaration" do
    it "leaves a separately-declared company_id field intact" do
      klass = co_class
      action = build_axn do
        expects :company, model: { klass:, finder: :find }
        expects :company_id, type: Integer
        exposes :cid

        def call = expose(cid: company_id)
      end

      # company_id reader is the explicitly-declared field, not the auto model-id reader
      expect(action.call(company_id: 5).cid).to eq(5)
    end
  end

  # The generated `<field>_id` reader is inferred, so an explicit declaration of that name takes it in either order,
  # nested exactly as at the top level. Nested, the explicit declaration written SECOND used to be refused as a
  # duplicate sub-key while the reverse order declared.
  describe "`<field>_id` reader — yields to an explicit declaration in either order" do
    { "top level" => "", "nested" => "expects :payload, type: Hash" }.each do |position, parent|
      context "#{position}, an explicit `type: Integer` id" do
        let(:build) do
          klass = co_class
          on = position == "nested" ? { on: :payload } : {}
          lambda do |order|
            build_axn do
              class_eval(parent)
              decls = [-> { expects :company, **on, model: { klass:, finder: :find } }, -> { expects :company_id, **on, type: Integer }]
              (order == :model_first ? decls : decls.reverse).each { |decl| instance_exec(&decl) }
              exposes :cid

              def call = expose(cid: company_id)
            end
          end
        end
        let(:payload) { position == "nested" ? { payload: { company_id: 5 } } : { company_id: 5 } }

        it "declares with the model first, and the id reader is the explicit field" do
          expect(build.call(:model_first).call(**payload).cid).to eq(5)
        end

        it "declares with the id first, and the id reader is the explicit field" do
          expect(build.call(:id_first).call(**payload).cid).to eq(5)
        end
      end

      context "#{position}, a second `model:` field named `<field>_id`" do
        let(:build) do
          klass = co_class
          on = position == "nested" ? { on: :payload } : {}
          lambda do |order|
            build_axn do
              class_eval(parent)
              decls = [-> { expects :company, **on, model: { klass:, finder: :find } }, -> { expects :company_id, **on, model: { klass:, finder: :find } }]
              (order == :model_first ? decls : decls.reverse).each { |decl| instance_exec(&decl) }
              exposes :record

              def call = expose(record: company_id)
            end
          end
        end
        let(:payload) do
          record = co_class.new(7)
          position == "nested" ? { payload: { company_id: record, company_id_id: 7 } } : { company_id: record, company_id_id: 7 }
        end

        it "declares in both orders, and the id reader is the explicit field's record in both" do
          records = %i[model_first id_first].map { |order| build.call(order).call(**payload).record }
          expect(records).to all(eq(co_class.new(7)))
        end
      end
    end
  end

  describe "record / id consistency check (default finder)" do
    let(:action) do
      klass = co_class
      build_axn do
        expects :company, model: { klass:, finder: :find }
        exposes :ok_marker

        def call = expose(ok_marker: "ok")
      end
    end

    it "passes when a record and a matching id are both supplied" do
      expect(action.call(company: co_class.new(5), company_id: 5)).to be_ok
    end

    it "fails with InboundValidationError when they disagree" do
      result = action.call(company: co_class.new(5), company_id: 9)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end

    it "renders the mismatch as the exception message (errors object, not a raw String)" do
      # ValidationError#message reads errors.full_messages, so raising with a String would
      # NoMethodError the moment anything renders the message (result.error, inspect, call!).
      result = action.call(company: co_class.new(5), company_id: 9)
      expect { result.exception.message }.not_to raise_error
      expect(result.exception.message).to match(/conflicts with company_id=9/)
    end

    it "passes when only a record is supplied" do
      expect(action.call(company: co_class.new(5))).to be_ok
    end

    it "still dominates a user_facing field's own validation failure (the mismatch is independent)" do
      klass = co_class
      action = build_axn do
        # user-facing custom validation that rejects the record — but the record/id contradiction is
        # an independent programmer error computed from raw inputs, so it must still page.
        expects :company, model: { klass:, finder: :find }, user_facing: true, validate: ->(_rec) { "is not active" }
        def call = nil
      end
      result = action.call(company: co_class.new(5), company_id: 9)
      expect(result.outcome).to be_exception
      expect(result.exception.message).to match(/conflicts with company_id=9/)
    end
  end

  describe "consistency check is skipped for custom finders" do
    it "does not flag a record + a (different-looking) lookup token" do
      klass = co_class
      dir = directory_class
      action = build_axn do
        expects :company, model: { klass:, finder: dir.method(:find_by_token) }
        exposes :ok_marker

        def call = expose(ok_marker: "ok")
      end

      # record id=42 alongside the token "abc" — would "disagree" by id, but custom finder skips the check
      expect(action.call(company: co_class.new(42), company_id: "abc")).to be_ok
    end
  end

  describe "subfield `<field>_id` reader" do
    let(:action) do
      klass = co_class
      build_axn do
        expects :payload
        expects :company, on: :payload, model: { klass:, finder: :find }
        exposes :cid

        def call = expose(cid: company_id)
      end
    end

    it "returns the id from the parent" do
      expect(action.call(payload: { company_id: 11 }).cid).to eq(11)
    end

    it "derives its 'by primary key' fast-path flag through the shared FieldConfig predicate, not an " \
       "inline re-derivation (Codex review round 3, PR #269: this reader independently re-derived " \
       "'by_primary_key' instead of going through FieldConfig.by_primary_key_finder?, so a later change " \
       "to that predicate's semantics could silently disagree between the top-level and nested " \
       "readers). Ordinary field validation resolves the record regardless of which branch the reader " \
       "itself takes, so nothing about the fast path is observable in the RETURNED id alone — this " \
       "verifies the shared call directly instead." do
      klass = co_class
      expect(Axn::Internal::FieldConfig).to receive(:by_primary_key_finder?).at_least(:once).and_call_original

      build_axn do
        expects :payload
        expects :company, on: :payload, model: { klass:, finder: :find }
        def call; end
      end
    end

    it "resolves the model and its id to nil when the parent is nil (no NoMethodError)" do
      # A `model:` subfield hanging off a nil/absent parent must resolve to nil (parent absent),
      # not blow up reaching into nil for the record/id (PRO-2857).
      klass = co_class
      action = build_axn do
        expects :payload, optional: true
        expects :company, on: :payload, model: { klass:, finder: :find }, optional: true
        exposes :cid, allow_nil: true

        def call = expose(cid: company_id)
      end

      result = action.call(payload: nil)
      expect(result).to be_ok
      expect(result.cid).to be_nil
    end

    it "returns nil, not the unmatched lookup token, for a custom finder with no match" do
      # Subfield analog of the top-level custom-finder case: an unmatched token must not be exposed
      # as the record's primary key.
      klass = co_class
      dir = directory_class
      action = build_axn do
        expects :payload
        expects :company, on: :payload, model: { klass:, finder: dir.method(:find_by_token) }, allow_nil: true
        exposes :cid, allow_nil: true

        def call = expose(cid: company_id)
      end

      result = action.call(payload: { company_id: "xyz" })
      expect(result).to be_ok
      expect(result.cid).to be_nil
    end
  end

  describe "rejects coerce:/preprocess: on a model: field (they transform a scalar, not a record)" do
    it "rejects coerce: on a top-level model field" do
      klass = co_class
      expect do
        build_axn { expects :company, model: { klass: }, coerce: Integer }
      end.to raise_error(ArgumentError, /coerce:.*not supported on a `model:` field.*<field>_id/m)
    end

    it "rejects preprocess: on a top-level model field" do
      klass = co_class
      expect do
        build_axn { expects :company, model: { klass: }, preprocess: ->(v) { v } }
      end.to raise_error(ArgumentError, /preprocess:.*not supported on a `model:` field/)
    end

    it "rejects coerce: on a model subfield" do
      klass = co_class
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :company, on: :payload, model: { klass: }, coerce: Integer
        end
      end.to raise_error(ArgumentError, /coerce:.*not supported on a `model:` field.*with on: payload/m)
    end

    it "rejects preprocess: on a model subfield" do
      klass = co_class
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :company, on: :payload, model: { klass: }, preprocess: ->(v) { v }
        end
      end.to raise_error(ArgumentError, /preprocess:.*not supported on a `model:` field/)
    end

    it "still allows a plain model field (no transform)" do
      klass = co_class
      expect { build_axn { expects :company, model: { klass: } } }.not_to raise_error
    end
  end
end
