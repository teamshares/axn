# frozen_string_literal: true

# Rails loads ActiveSupport's Object#as_json globally, so every object responds to as_json. These
# specs guard that serialize_value still prefers a value object's own to_h over that generic dump.
RSpec.describe Axn::Internal::Reflection::Values do
  it "sanity: Rails has added the generic Object#as_json" do
    expect(Object.new).to respond_to(:as_json)
  end

  it "serializes a value object via its own to_h, not ActiveSupport's generic Object#as_json ivar dump" do
    dto = Class.new do
      def initialize = @internal_secret = "leak"
      def to_h = { label: "public" }
    end.new

    expect(described_class.serialize_value(dto)).to eq("label" => "public")
  end

  it "still follows a value object's OWN as_json when it defines one" do
    dto = Class.new do
      def as_json(*) = { via: "as_json" }
      def to_h = { via: "to_h" }
    end.new

    expect(described_class.serialize_value(dto)).to eq("via" => "as_json")
  end

  # A value with neither its own as_json nor a to_h declares no shape at all. Only in Rails does it reach
  # the as_json branch — the generic Object#as_json is the sole reason it responds — so this is where the
  # reject_opaque verdict on that shape is observable.
  describe "a value whose only as_json is ActiveSupport's generic Object#as_json" do
    let(:undeclared) do
      Class.new do
        def initialize
          @name = "widget"
          @secret = "tok"
        end
      end.new
    end

    it "renders ActiveSupport's instance-variable dump by default" do
      expect(described_class.serialize_value(undeclared, path: "owner")).to eq("name" => "widget", "secret" => "tok")
    end

    it "raises under reject_opaque:, since the dump leaks internals and isn't the declared schema's shape" do
      expect { described_class.serialize_value(undeclared, path: "owner", reject_opaque: true) }
        .to raise_error(
          Axn::Extensions::Serialization::UnserializableValue,
          %r{`owner`.*declares no JSON projection of its own.*give the value its own `as_json`/`to_h`}m,
        )
    end

    it "leaves an ActiveRecord model, which has its own as_json, serializing under reject_opaque:" do
      user = User.new(name: "Ada")

      expect(user.method(:as_json).owner).not_to eq(Object)
      expect(described_class.serialize_value(user, path: "user", reject_opaque: true)).to include("name" => "Ada")
    end

    it "leaves a value object with a to_h serializing under reject_opaque:" do
      dto = Class.new do
        def initialize = @internal_secret = "leak"
        def to_h = { label: "public" }
      end.new

      expect(described_class.serialize_value(dto, path: "dto", reject_opaque: true)).to eq("label" => "public")
    end

    it "raises for a value with no to_hash, whose generic as_json therefore dumps instance variables" do
      expect(undeclared).not_to respond_to(:to_hash)
      expect { described_class.serialize_value(undeclared, path: "owner", reject_opaque: true) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /declares no JSON projection of its own/)
    end

    # ActiveSupport's generic Object#as_json delegates to `to_hash` when the value has one and only dumps
    # `instance_values` when it doesn't — so a `to_hash` IS a declared projection, and the generic route
    # renders it faithfully. Rejecting it would be a false positive against a value that serializes fine.
    it "serializes a value declaring only to_hash, whose generic as_json delegates to it, under reject_opaque:" do
      dto = Class.new do
        def initialize = @internal_secret = "leak"
        def to_hash = { label: "public" }
      end.new

      expect(dto).not_to respond_to(:to_h)
      expect(dto.method(:as_json).owner).to eq(Object)
      expect(described_class.serialize_value(dto, path: "dto")).to eq("label" => "public")
      expect(described_class.serialize_value(dto, path: "dto", reject_opaque: true)).to eq("label" => "public")
    end

    it "checks the same shape at depth, naming the nested path" do
      expect { described_class.serialize_value({ rows: [undeclared] }, path: "out", reject_opaque: true) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`out\.rows\[0\]`/)
    end
  end

  # PRO-3284, under Rails: the SAME `Values.displacing_projection` predicate, but the mechanism a subclass's
  # override reaches through differs from the non-Rails suite (spec/axn/extensions/serialization_spec.rb),
  # because ActiveSupport's core_ext is loaded globally here.
  describe "a value whose own as_json/to_h displaces a member-derived output schema (PRO-3284)" do
    let(:s) { Data.define(:name, :internal_notes) }

    def shaped_action(type:)
      Class.new do
        include Axn
        auto_log false
        expects :value
        exposes :d, type: do
          field :name, type: String
          field :internal_notes, type: String
        end
        def call = expose(d: value)
      end
    end

    it "raises for a subclass's own PUBLIC as_json (reached by dispatch, exactly as outside Rails)" do
      subclass = Class.new(s) { def as_json(*) = { name: } }
      klass = shaped_action(type: s)

      expect { Axn::Extensions::Serialization.render(klass.call(value: subclass.new(name: "a", internal_notes: "x"))) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
    end

    # Outside Rails, a Data subclass's `to_h` is the FALLBACK route. Under Rails, `Data#as_json` is
    # `to_h.as_json` (ActiveSupport's core_ext) — an IMPLICIT-RECEIVER call, which reaches a to_h override
    # regardless of its visibility. `displacing_projection` names the same method either way (any-visibility
    # `to_h`), so the schema and the renderer agree without knowing which mechanism is in play.
    it "raises for a subclass's own to_h, reached here via Data#as_json = to_h.as_json rather than the " \
       "to_s-degradation route the non-Rails suite exercises for the same override" do
      subclass = Class.new(s) { def to_h = { name: } }
      klass = shaped_action(type: s)
      value = subclass.new(name: "a", internal_notes: "x")

      expect(value.as_json).to eq("name" => "a") # confirms the Rails mechanism this test is actually pinning
      expect { Axn::Extensions::Serialization.render(klass.call(value:)) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
    end

    it "raises for Enumerable mixed into a Data subclass (Enumerable is not a framework projection owner)" do
      subclass = Class.new(s) do
        include Enumerable
        def each(&) = to_h.each(&)
      end
      klass = shaped_action(type: s)

      expect { Axn::Extensions::Serialization.render(klass.call(value: subclass.new(name: "a", internal_notes: "x"))) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
    end

    it "does not raise for a plain subclass with no override, or for the exact declared class" do
      klass = shaped_action(type: s)

      expect(Axn::Extensions::Serialization.render(klass.call(value: Class.new(s).new(name: "a", internal_notes: "x"))))
        .to eq("d" => { "name" => "a", "internal_notes" => "x" })
      expect(Axn::Extensions::Serialization.render(klass.call(value: s.new(name: "a", internal_notes: "x"))))
        .to eq("d" => { "name" => "a", "internal_notes" => "x" })
    end

    # KNOWN GAP, deliberately left open (see the CHANGELOG entry and PRO-3547, the follow-up ticket): a
    # Data/Struct value nested directly inside ANOTHER Data/Struct is rendered by ActiveSupport's own
    # `Data#as_json` (`to_h.as_json`) in ONE step, so a displacing override on the INNER value is never
    # reached by `serialize_value` at all — the walker only ever sees the plain Hash `to_h.as_json` produces.
    # Nesting through a Hash or an Array IS covered in both environments (see the non-Rails suite's nested
    # and array-element examples), so this gap is specifically the direct Data-in-Data / Struct-in-Struct
    # case.
    it "does NOT catch a displacing subclass nested directly inside another Data value (pinned gap)" do
      outer = Data.define(:inner)
      inner_type = s
      subclass = Class.new(inner_type) { def as_json(*) = { name: } }
      klass = Class.new do
        include Axn
        auto_log false
        expects :value
        exposes :w, type: outer do
          field :inner, type: inner_type do
            field :name, type: String
            field :internal_notes, type: String
          end
        end
        def call = expose(w: value)
      end
      value = outer.new(inner: subclass.new(name: "a", internal_notes: "x"))

      expect(value.as_json).to eq("inner" => { name: "a" }) # confirms ActiveSupport renders it in one step, symbol-keyed
      expect(Axn::Extensions::Serialization.render(klass.call(value:))).to eq("w" => { "inner" => { "name" => "a" } })
    end
  end
end
