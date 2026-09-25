# frozen_string_literal: true

require "spec_helper"
require "open3"

# A NAMED module, so the PRO-3284 owner-label test below can pin the "defined in <a real module name>"
# branch of `Values.displaced_projection_owner_label` — a module built with `Module.new` inline stays
# anonymous and only exercises the OTHER branch.
module SerializationSpecRedactingModule
  def as_json(*) = { name: }
end

RSpec.describe Axn::Extensions::Serialization do
  # An object with no own as_json, no to_h, and #to_s owned by Object — but `respond_to?` is
  # overridden to hide :as_json/:to_h rather than left to chance: another spec file's
  # `require "globalid"` adds a generic Object#as_json globally for the rest of this process (a
  # Rails app does the same), which would otherwise route a plain Object.new through the as_json
  # branch instead of the to_s fallback these examples mean to exercise.
  def opaque_object
    Object.new.tap do |o|
      def o.respond_to?(name, *args)
        return false if %i[as_json to_h].include?(name)

        super
      end
    end
  end

  describe ".render" do
    it "serializes each declared field by wire key (string)" do
      klass = Class.new do
        include Axn
        exposes :count, type: Integer
        def call = expose(count: 3)
      end

      expect(described_class.render(klass.call)).to eq("count" => 3)
    end

    # The configs are DERIVED from the result rather than passed in, so what lands in the body is
    # exactly the declared `exposes` — the same set output_schema reflects. An inbound-only field is
    # not part of that set and must not appear.
    it "renders the declared exposures and nothing else" do
      klass = Class.new do
        include Axn
        expects :multiplier, type: Integer
        exposes :product, type: Integer
        def call = expose(product: multiplier * 2)
      end

      expect(described_class.render(klass.call(multiplier: 4))).to eq("product" => 8)
    end

    # Adapter specs mock results with Axn::Result.ok, which builds a real (factory-made) action
    # behind the facade — so the derivation has to work there too, not just for a declared class.
    it "derives the configs from a mocked result" do
      expect(described_class.render(Axn::Result.ok(count: 3))).to eq("count" => 3)
    end

    # The renderer also refuses a field name with no UTF-8 rendering, and two names that collapse onto one
    # property. Neither is reachable through `render`: `exposes` rejects both when the class is defined
    # (spec/axn/core/validations/property_name_collision_spec.rb), and `render` derives its configs from a
    # declared class. Those two backstops are exercised against a directly-built config list in
    # spec/axn/internal/reflection/values_spec.rb.

    it "renders an ordinary field name as a frozen UTF-8 property" do
      klass = Class.new do
        include Axn
        exposes :count, type: Integer
        def call = expose(count: 3)
      end

      key = described_class.render(klass.call).keys.first
      expect(key).to eq("count")
      expect(key.encoding).to eq(Encoding::UTF_8)
      expect(key).to be_frozen
    end

    it "threads reject_opaque: to the values it serializes" do
      owner = opaque_object
      klass = Class.new do
        include Axn
        auto_log false
        exposes :owner

        define_method(:call) { expose(owner:) }
      end
      result = klass.call

      expect(described_class.render(result)["owner"]).to match(/\A#<Object:0x[0-9a-f]+>\z/)
      expect { described_class.render(result, reject_opaque: true) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`owner`/)
    end

    # The opacity verdict is about the RUNTIME VALUE's singleton class, not the field's declared `type:` — a
    # declared type is only ever a lower bound on what could show up. These two examples are the boundary a
    # declaration-time check (rejected as unsound: see lib/axn/tools.rb's validate_contracts! doc comment)
    # would get wrong.
    it "raises under reject_opaque: true when the exposed value's own class has no to_h/as_json" do
      opaque_base = Class.new do
        def initialize
          @a = 1
        end
      end
      klass = Class.new do
        include Axn
        auto_log false
        exposes :thing, type: opaque_base

        define_method(:call) { expose(thing: opaque_base.new) }
      end

      expect { described_class.render(klass.call, reject_opaque: true) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`thing`/)
    end

    it "renders cleanly under reject_opaque: true when the exposed value is a SUBCLASS of the declared " \
       "type that defines its own to_h" do
      opaque_base = Class.new do
        def initialize
          @a = 1
        end
      end
      subclass_with_to_h = Class.new(opaque_base) do
        def to_h = { a: 1 }
      end
      klass = Class.new do
        include Axn
        auto_log false
        exposes :thing, type: opaque_base

        define_method(:call) { expose(thing: subclass_with_to_h.new) }
      end

      expect(described_class.render(klass.call, reject_opaque: true)).to eq("thing" => { "a" => 1 })
    end

    # PRO-3284: `exposes :d, type: S do ... end` publishes a schema reflected from the DECLARED S's members.
    # A runtime SUBCLASS whose own as_json/to_h renders something else ships a body the schema does not
    # describe — silently, `result.ok?` true throughout. Unlike the `reject_opaque` pair above, this is
    # unconditional (the schema and the body would actively disagree, not merely be unpresentable) and is
    # never reachable from `expose` — only from `render`.
    describe "a value whose own as_json/to_h displaces a member-derived output schema" do
      let(:s) { Data.define(:name, :internal_notes) }
      let(:public_s) do
        klass = s
        Class.new(klass) { def as_json(*) = { name: } }
      end

      # Some examples below mean to pin behavior specifically for a Data/Struct value that has NO as_json
      # of its own — routing through `to_h` outside Rails, or through Rails/ActiveSupport's own `to_h.as_json`
      # inside it. But `Data`/`Struct` getting their OWN `as_json` isn't actually exclusive to "a Rails app":
      # `require "globalid"` (elsewhere in this process — spec/axn/internal/exception_context_spec.rb) pulls
      # in ActiveSupport's real `active_support/core_ext/object/json`, which reopens `Data`/`Struct` DIRECTLY
      # (`Data.instance_method(:as_json).owner == Data`, not the generic `Object` the file-level `opaque_object`
      # comment describes) — so whether this suite happens to be contaminated depends on example run order,
      # not on "Rails" as such. `FRAMEWORK_PROJECTION_OWNERS` already treats that as a non-displacing,
      # framework-owned `as_json` (Data IS in the list), so ownership verdicts are unaffected either way —
      # but `Values.projection_for`'s ROUTE (`as_json` vs `to_h`) is not, and a couple of examples exist
      # specifically to pin ONE of those two routes. This clears `Data#as_json`/`Struct#as_json` for the
      # block's duration, if ActiveSupport put one there, and restores it afterward — deterministic either
      # way, rather than order-dependent on which OTHER spec file in this process ran first.
      def without_activesupport_json_core_ext
        removed = [Data, Struct].select { |klass| klass.method_defined?(:as_json) }
        originals = removed.to_h { |klass| [klass, klass.instance_method(:as_json)] }
        removed.each { |klass| klass.send(:remove_method, :as_json) }
        yield
      ensure
        originals&.each { |klass, method| klass.define_method(:as_json, method) }
      end

      def shaped_action(type:, of: nil, **opts) # rubocop:disable Naming/MethodParameterName -- matches the DSL kwarg it forwards
        Class.new do
          include Axn
          auto_log false
          expects :value
          if of
            exposes :d, type:, of:, **opts do
              field :name, type: String
              field :internal_notes, type: String
            end
          else
            exposes :d, type:, **opts do
              field :name, type: String
              field :internal_notes, type: String
            end
          end
          def call = expose(d: value)
        end
      end

      # No shape block at all — the bare-position rule (`Nestability#contents_object_class?`), never the
      # shape-overlay one, applies to whatever `of:`/`type:` describes.
      def data_action_for(type:, **opts)
        Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :d, type:, **opts
          def call = expose(d: value)
        end
      end

      it "raises, names the field path, the declared class, the value's class, the overriding method and " \
         "its owner, and all three fixes, while leaving result.ok? and the Ruby-side read unaffected" do
        klass = shaped_action(type: s)
        value = public_s.new(name: "Ada", internal_notes: "secret")
        result = klass.call(value:)

        expect(result.ok?).to be(true)
        expect(result.d).to be(value)

        error = nil
        begin
          described_class.render(result)
        rescue Axn::Extensions::Serialization::UnserializableValue => e
          error = e
        end

        expect(error).not_to be_nil
        expect(error.message).to match(/`d`/)
        expect(error.message).to match(/\(#{Regexp.escape(public_s.to_s)}\)/)
        expect(error.message).to match(/declared type #{Regexp.escape(s.to_s)}/)
        expect(error.message).to match(/`#as_json`/)
        # public_s is itself anonymous (never assigned to a constant), so the owner is named the way
        # `NameOwnership#owner_label` names any anonymous module: by where it was written, not its address.
        expect(error.message).to match(/defined in an anonymous module \(#{Regexp.escape(__FILE__)}:\d+\)/)
        expect(error.message).to match(/expose a value that doesn't carry it/)
        expect(error.message).to match(/declare the type it renders as/)
        expect(error.message).to match(/define the projection on the declared type itself/)
      end

      it "still raises with reject_opaque: false (the default) and with reject_opaque: true alike" do
        klass = shaped_action(type: s)
        value = public_s.new(name: "Ada", internal_notes: "secret")

        expect { described_class.render(klass.call(value:), reject_opaque: false) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
        expect { described_class.render(klass.call(value:), reject_opaque: true) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "raises for a subclass overriding to_h (any visibility shadows the built-in)" do
        klass = shaped_action(type: s)
        to_h_subclass = Class.new(s) { def to_h = { name: } }

        expect { described_class.render(klass.call(value: to_h_subclass.new(name: "a", internal_notes: "x"))) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "raises for a private to_h override (it shadows the built-in even though it cannot be dispatched)" do
        klass = shaped_action(type: s)
        private_to_h = Class.new(s) { private def to_h = { name: } }

        expect { described_class.render(klass.call(value: private_to_h.new(name: "a", internal_notes: "x"))) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "raises for an as_json defined by a NAMED included module, naming that module as the owner" do
        klass = shaped_action(type: s)
        mixin_subclass = Class.new(s) { include SerializationSpecRedactingModule }

        expect { described_class.render(klass.call(value: mixin_subclass.new(name: "a", internal_notes: "x"))) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /defined in SerializationSpecRedactingModule/)
      end

      it "raises for an as_json defined by an ANONYMOUS included module, naming it as an anonymous module" do
        klass = shaped_action(type: s)
        redacting_module = Module.new { def as_json(*) = { name: } }
        mixin_subclass = Class.new(s) { include redacting_module }

        expect { described_class.render(klass.call(value: mixin_subclass.new(name: "a", internal_notes: "x"))) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /defined in an anonymous module \(#{Regexp.escape(__FILE__)}:\d+\)/)
      end

      it "raises for a Struct instance's own singleton as_json, naming it as defined on the value itself" do
        st = Struct.new(:name, :internal_notes)
        klass = shaped_action(type: st)
        value = st.new("a", "x")
        def value.as_json(*) = { name: }

        expect { described_class.render(klass.call(value:)) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /defined on this value itself \(a singleton method\)/)
      end

      # Codex review, PR #296: `to_h` displaces the built-in at ANY visibility (unlike `as_json`, which is
      # reached only by dispatch), including a PRIVATE singleton `to_h` or one from a privately-`extend`ed
      # module. `Kernel#singleton_methods` (an earlier, cheaper draft of the frozen-value fast path below)
      # excludes private singleton-level methods entirely, so it would have missed this — verified: the
      # fast path here gates on FROZEN, not on that method, and a Struct instance is mutable.
      it "raises for a Struct instance's own PRIVATE singleton to_h" do
        st = Struct.new(:name, :internal_notes)
        klass = shaped_action(type: st)
        value = st.new("a", "x")
        value.singleton_class.send(:define_method, :to_h) { { name: } }
        value.singleton_class.send(:private, :to_h)

        expect { described_class.render(klass.call(value:)) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /defined on this value itself \(a singleton method\)/)
      end

      it "raises for a Struct instance extended with a module whose to_h is PRIVATE" do
        st = Struct.new(:name, :internal_notes)
        klass = shaped_action(type: st)
        redacting_module = Module.new { private def to_h = { name: } }
        value = st.new("a", "x")
        value.extend(redacting_module)

        expect { described_class.render(klass.call(value:)) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /defined in an anonymous module/)
      end

      # Codex review, PR #296, round 2: freezing a value prevents ADDING a singleton method from that point
      # on, but does not remove one already installed -- a public singleton override given BEFORE freezing
      # still displaces the built-in after. `frozen?` alone is therefore not the fast-path condition (only
      # "is a Data instance AND frozen" is, since Data.new/#with freeze unconditionally at construction,
      # before any window in which an override could have been added -- a Struct is never provably safe
      # this way, so it always takes the full check regardless of its current frozen state).
      it "raises for a Struct instance given a PUBLIC singleton to_h override BEFORE being frozen" do
        st = Struct.new(:name, :internal_notes)
        klass = shaped_action(type: st)
        value = st.new("a", "x")
        def value.to_h = { name: }
        value.freeze

        expect(value.frozen?).to be(true) # confirms this exercises the freeze-after-override ordering
        expect { described_class.render(klass.call(value:)) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /defined on this value itself \(a singleton method\)/)
      end

      it "does not raise for a private/protected as_json override (never reached by dispatch, so the " \
         "built-in member-keyed to_h still renders)" do
        klass = shaped_action(type: s)
        private_as_json = Class.new(s) { private def as_json(*) = { name: } }

        expect(described_class.render(klass.call(value: private_as_json.new(name: "a", internal_notes: "x"))))
          .to eq("d" => { "name" => "a", "internal_notes" => "x" })
      end

      it "does not raise for a subclass with no override at all" do
        klass = shaped_action(type: s)
        plain_subclass = Class.new(s)

        expect(described_class.render(klass.call(value: plain_subclass.new(name: "a", internal_notes: "x"))))
          .to eq("d" => { "name" => "a", "internal_notes" => "x" })
      end

      it "does not raise for the exact declared class" do
        klass = shaped_action(type: s)

        expect(described_class.render(klass.call(value: s.new(name: "a", internal_notes: "x"))))
          .to eq("d" => { "name" => "a", "internal_notes" => "x" })
      end

      it "does not raise when the DECLARED class owns as_json (the static case stays opaque, unchanged)" do
        owns_as_json = Data.define(:name, :internal_notes) { def as_json(*) = { name: } }
        klass = shaped_action(type: owns_as_json)

        expect(described_class.render(klass.call(value: owns_as_json.new(name: "a", internal_notes: "x"))))
          .to eq("d" => { "name" => "a" })
      end

      it "re-checks the DECLARED class live rather than trusting a memoized verdict: reopening the " \
         "declared class with its own as_json after the first render stands the check down" do
        reopenable = Data.define(:name, :internal_notes)
        klass = shaped_action(type: reopenable)
        described_class.render(klass.call(value: reopenable.new(name: "a", internal_notes: "x"))) # warms the memo

        reopenable.define_method(:as_json) { { name: } }
        overriding_subclass = Class.new(reopenable) { def as_json(*) = { name: } }

        expect(described_class.render(klass.call(value: overriding_subclass.new(name: "a", internal_notes: "x"))))
          .to eq("d" => { "name" => "a" })
      end

      # Codex review, PR #296, round 4: the MIRROR direction of the reopening test above. A declared class
      # that owns its own as_json at the first render makes the position OPAQUE, so the memoized guard plan
      # has NO guard object for it at all. If that method is later REMOVED, output_schema immediately starts
      # publishing the member-derived shape (it re-validates every call) -- but a cached `nil` guard cannot
      # retroactively gain a guard object that was never built. `output_render_guards`' `watched_classes` is
      # what makes the memo notice: it re-checks every class found opaque at build time before trusting the
      # cache, and rebuilds the whole plan the moment one of them stops being opaque.
      it "rebuilds the whole memoized plan when a declared class LOSES the as_json it owned at the first " \
         "render, so a position that started opaque can still gain a guard" do
        reopenable = Data.define(:name, :internal_notes) { def as_json(*) = { name: } }
        klass = shaped_action(type: reopenable)
        described_class.render(klass.call(value: reopenable.new(name: "a", internal_notes: "x"))) # warms the memo opaque

        reopenable.send(:remove_method, :as_json)
        overriding_subclass = Class.new(reopenable) { def as_json(*) = { name: } }

        expect { described_class.render(klass.call(value: overriding_subclass.new(name: "a", internal_notes: "secret"))) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "raises for a nested shape member (a Hash field whose own shaped member is such a subclass)" do
        inner_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :w, type: Hash do
            field :inner, type: inner_type do
              field :name, type: String
              field :internal_notes, type: String
            end
          end
          def call = expose(w: { inner: value })
        end
        value = public_s.new(name: "a", internal_notes: "secret")

        expect { described_class.render(klass.call(value:)) }.to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`w\.inner`/)
      end

      # Data-in-Data (not through a Hash/Array): the OUTER value is rendered via `to_h` (`Values.projection_for`
      # prefers it over any incidentally-present generic `Object#as_json`, since `Data` always answers
      # `to_h`), and that recursion is what has to carry `guard` into the inner value — the one path
      # ActiveSupport's own `Data#as_json` (`to_h.as_json`, one step — present in a Rails app, or wherever
      # else that core_ext got loaded) shortcuts around instead (see spec_rails/dummy_app's pinned-gap
      # example, PRO-3547). Wrapped in `without_activesupport_json_core_ext` so this pins the `to_h` route
      # deterministically rather than depending on whether some OTHER spec in this process loaded it first.
      it "raises for a Data value nested directly inside another Data value, via the to_h route" do
        outer_type = Data.define(:inner)
        inner_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :w, type: outer_type do
            field :inner, type: inner_type do
              field :name, type: String
              field :internal_notes, type: String
            end
          end
          def call = expose(w: value)
        end
        value = outer_type.new(inner: public_s.new(name: "a", internal_notes: "secret"))

        without_activesupport_json_core_ext do
          expect { described_class.render(klass.call(value:)) }
            .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`w\.inner`/)
        end
      end

      it "raises at an array element (type: Array, of: S do ... end)" do
        klass = shaped_action(type: Array, of: s)

        expect { described_class.render(klass.call(value: [public_s.new(name: "a", internal_notes: "x")])) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`d\[0\]`/)
      end

      it "raises at a bare `of: S` array position with no block at all" do
        element_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :d, type: Array, of: element_type
          def call = expose(d: value)
        end

        expect { described_class.render(klass.call(value: [public_s.new(name: "a", internal_notes: "x")])) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "does not raise for an Array's elements left fully untyped (`type: Array do ... end`, no `of:`) " \
         "— output_schema emits no items schema at all for them, so there is nothing to guard" do
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :d, type: Array do
            field :name, type: String
          end
          def call = expose(d: value)
        end

        expect(klass.output_schema.dig(:properties, :d)).not_to have_key(:items)
        expect(described_class.render(klass.call(value: [public_s.new(name: "a", internal_notes: "secret")])))
          .to eq("d" => [{ "name" => "a" }])
      end

      it "does not raise for a bare Struct `of:` element with no block (the schema leaves it untyped)" do
        st = Struct.new(:name, :internal_notes)
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :d, type: Array, of: st
          def call = expose(d: value)
        end
        overriding = Class.new(st) { def as_json(*) = { name: } }

        expect(described_class.render(klass.call(value: [overriding.new("a", "x")])))
          .to eq("d" => [{ "name" => "a" }])
      end

      it "raises at a map's values: axis (bare — no shape block at all, so every key routes through the axis)" do
        value_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :m, type: Hash, of: { values: value_type }
          def call = expose(m: value)
        end
        result = klass.call(value: { key: public_s.new(name: "a", internal_notes: "x") })
        expect(result.ok?).to be(true)

        expect { described_class.render(result) }.to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`m\.key`/)
      end

      it "raises at a map's values: axis when the axis is a BAG carrying its own nested shape (`of: " \
         "{values: {klass: S, shape: {...}}}`), not just a bare token" do
        value_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :m, type: Hash, of: { values: { klass: value_type } } do
            # nothing named here -- the values: axis carries its OWN shape via the block below
          end
          def call = expose(m: value)
        end
        result = klass.call(value: { key: public_s.new(name: "a", internal_notes: "x") })
        expect(result.ok?).to be(true)

        expect { described_class.render(result) }.to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`m\.key`/)
      end

      it "raises inside a nested contents bag (`of: { klass: Array, of: { klass: S, shape: } }`, an Array " \
         "of Arrays of S), two `of:` rungs deep" do
        # A bag's own `shape:` at an unnamed, doubly-nested position has no block-DSL sugar (there's no
        # field name to hang a `do...end` off two containers down) — built directly the way
        # spec/axn/core/ambient_context_spec.rb's "reaches a member two containers deep" example does.
        element_type = s
        inner_shape = {
          members: [
            Axn::Core::Contract::ShapeConfig.new(field: :name, validations: { type: { klass: String } }),
            Axn::Core::Contract::ShapeConfig.new(field: :internal_notes, validations: { type: { klass: String } }),
          ],
        }
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :ds, type: Array, of: { klass: Array, of: { klass: element_type, shape: inner_shape } }
          def call = expose(ds: value)
        end
        result = klass.call(value: [[public_s.new(name: "a", internal_notes: "x")]])
        expect(result.ok?).to be(true)

        expect { described_class.render(result) }.to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`ds\[0\]\[0\]`/)
      end

      it "raises for a Struct instance `extend`ed with a module defining as_json" do
        st = Struct.new(:name, :internal_notes)
        redacting_module = Module.new { def as_json(*) = { name: } }
        klass = shaped_action(type: st)
        value = st.new("a", "x")
        value.extend(redacting_module)

        expect { described_class.render(klass.call(value:)) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "raises for a pass-through override (`def as_json(*) = super`) — ownership decides, not behavior: " \
         "the override still displaces the built-in even though it renders identically" do
        pass_through = Class.new(s) { def as_json(*) = super }

        expect { described_class.render(shaped_action(type: s).call(value: pass_through.new(name: "a", internal_notes: "x"))) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "guards an explicitly-shaped key on the SAME class ownership terms as the values: axis (the " \
         "override is refused regardless of which subset of members that key's own shape asks for — an " \
         "ownership rule, not an effect check: PublicS still satisfies meta's own narrower `required`)" do
        value_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :m, type: Hash, of: { values: value_type } do
            field :meta, type: value_type do
              field :name, type: String
            end
          end
          def call = expose(m: value)
        end

        expect { described_class.render(klass.call(value: { meta: public_s.new(name: "a", internal_notes: "x") })) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`m\.meta`/)
      end

      it "keeps a shaped key with no guard of its own (a scalar-typed member) from falling through to a " \
         "sibling values: axis that does not describe it" do
        value_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :m, type: Hash, of: { values: value_type } do
            field :label, type: String
          end
          def call = expose(m: value)
        end

        # `label` (a plain String) has no guard of its own; `other` falls to the values: axis (type: S) and
        # is guarded there. Both render successfully unless `other`'s value displaces its projection.
        expect(described_class.render(klass.call(value: { label: "x", other: s.new(name: "a", internal_notes: "b") })))
          .to eq("m" => { "label" => "x", "other" => { "name" => "a", "internal_notes" => "b" } })
        expect { described_class.render(klass.call(value: { label: "x", other: public_s.new(name: "a", internal_notes: "b") })) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`m\.other`/)
      end

      # A positive control for the "keeps a shaped key … from falling through" example above: THAT example
      # never actually proves the safeguard runs, since a String at `label` would never match the values:
      # axis's guard classes even if it fell through to them. Here `label` is given a runtime value the
      # values: axis's guard WOULD flag (an overriding S instance, ignoring its own declared `type: String`
      # — `render` reads whatever was exposed, contract-valid or not, and the point is what the GUARD walk
      # does with it) — proving the member Hash's PRESENT-nil entry, not merely `label`'s declared type,
      # is what keeps it unguarded.
      it "does not raise for a shaped key with no guard of its own even when its runtime value is one the " \
         "sibling values: axis WOULD flag — proving the member Hash keeps a present nil entry rather than " \
         "dropping it" do
        value_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :m, type: Hash, of: { values: value_type } do
            field :label, type: String
          end
          def call = expose(m: value)
        end

        expect(described_class.render(klass.call(value: { label: public_s.new(name: "a", internal_notes: "b") })))
          .to eq("m" => { "label" => { "name" => "a" } })
      end

      it "raises for a union of Data classes at a contents position, with a shape overlay (both branches " \
         "provably member-keyed, so the overlay's properties/required are asserted regardless of branch)" do
        t = Data.define(:x)
        klass = shaped_action(type: Array, of: [s, t])

        expect { described_class.render(klass.call(value: [public_s.new(name: "a", internal_notes: "x")])) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "does not raise for a BARE union (no shape block) where a sibling branch's own schema is " \
         "untyped ({}) — with no overlay, the position's ENTIRE schema is the anyOf, and an anyOf with an " \
         "unconstrained branch matches anything, so refusing would raise against a schema that promised " \
         "nothing about this value in the first place" do
        untyped_struct = Struct.new(:name, :internal_notes)
        klass = data_action_for(type: Array, of: [s, untyped_struct])

        expect(klass.output_schema.dig(:properties, :d, :items)).to eq(anyOf: [{ type: "object", properties: { name: {}, internal_notes: {} } }, {}])
        expect(described_class.render(klass.call(value: [public_s.new(name: "a", internal_notes: "x")])))
          .to eq("d" => [{ "name" => "a" }])
      end

      it "does not raise at a position whose WHOLE exposure is gated (build_property's own early return " \
         "leaves it untyped before apply_structured_schema! — hence output_render_guards — ever runs)" do
        declared_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :d, type: declared_type, if: -> { false } do
            field :name, type: String
            field :internal_notes, type: String
          end
          def call = expose(d: value)
        end

        expect(klass.output_schema.dig(:properties, :d)).to eq({})
        expect(described_class.render(klass.call(value: public_s.new(name: "a", internal_notes: "x"))))
          .to eq("d" => { "name" => "a" })
      end

      it "does not raise at a position whose own `:type` entry is gated away — the shape's NAMED members " \
         "still emit (an untyped parent is trivially object-shaped), but with no class named there is " \
         "nothing left to check ownership against" do
        declared_type = s
        klass = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :d, type: { klass: declared_type, if: -> { false } } do
            field :name, type: String
            field :internal_notes, type: String
          end
          def call = expose(d: value)
        end

        expect(klass.output_schema.dig(:properties, :d)).to include(properties: { name: anything, internal_notes: anything })
        expect(described_class.render(klass.call(value: public_s.new(name: "a", internal_notes: "x"))))
          .to eq("d" => { "name" => "a" })
      end

      it "does not raise for a field typed as the class with no block and no of: (schema is {})" do
        declared_type = s
        plain = Class.new do
          include Axn
          auto_log false
          expects :value
          exposes :d, type: declared_type
          def call = expose(d: value)
        end

        expect(plain.output_schema.dig(:properties, :d)).to eq({})
        expect(described_class.render(plain.call(value: public_s.new(name: "a", internal_notes: "x"))))
          .to eq("d" => { "name" => "a" })
      end

      # Soundness control: an action declaring every guarded shape above, filled ONLY with exact-class and
      # non-overriding-subclass values, renders byte-identical to the pre-PRO-3284 behaviour — nothing here
      # over-reaches for the ordinary case.
      it "renders an action using every guarded shape unchanged when nothing displaces its projection" do
        d_type = Data.define(:name, :internal_notes)
        x_type = Data.define(:x)
        y_type = Data.define(:y)
        klass = Class.new do
          include Axn
          auto_log false
          exposes :d, type: d_type do
            field :name, type: String
            field :internal_notes, type: String
          end
          exposes :items, type: Array, of: x_type do
            field :x, type: Integer
          end
          exposes :m, type: Hash, of: { values: y_type }

          define_method(:call) do
            expose(
              d: d_type.new(name: "a", internal_notes: "x"),
              items: [x_type.new(x: 1)],
              m: { k: y_type.new(y: 2) },
            )
          end
        end
        result = klass.call
        expect(result.ok?).to be(true) # the type match itself is the setup, not the assertion

        expect(described_class.render(result)).to eq(
          "d" => { "name" => "a", "internal_notes" => "x" },
          "items" => [{ "x" => 1 }],
          "m" => { "k" => { "y" => 2 } },
        )
      end

      # A singleton class is a permanent object that outlives the call, so materializing one for every
      # guarded value at render time would be a lasting side effect on caller data, not just an allocation
      # cost — and on the hot render path this repo already gates allocations on (the alpha-6 allocation
      # gate). `Kernel#singleton_class` (`NativeMethods.method_table`) creates one where none exists;
      # `Kernel#singleton_methods` (`NativeMethods.singleton_level_methods`) answers the same "does this
      # value carry anything beyond its class" question without ever doing so, so the common case (no
      # override at all) must reach for the class-level check alone.
      # Run in a FRESH Ruby process (the same technique spec/axn/standalone_require_spec.rb uses, and for
      # the identical reason): this suite's own process can be contaminated by whichever OTHER spec file
      # happened to run first — `require "globalid"` (spec/axn/internal/exception_context_spec.rb) reopens
      # `Data`/`Struct` with ActiveSupport's real `as_json`, and once that has happened, PRE-EXISTING code
      # (`Values.projection_for`'s `owner_of(value, :as_json)` check, unrelated to this fix) materializes a
      # singleton class for every Data/Struct value reaching it EITHER WAY, guarded or not — swamping the
      # one signal this test means to isolate regardless of any in-process countermeasure. A clean process
      # never runs that `require` at all, so it needs none.
      it "does not materialize a singleton class for a guarded value with no singleton-level override" do
        program = <<~RUBY
          $LOAD_PATH.unshift(#{File.expand_path('../../../lib', __dir__).inspect})
          require "axn"
          require "logger"
          Axn.config.logger = Logger.new(File::NULL)

          x = Data.define(:name)
          guarded_klass = Class.new do
            include Axn
            auto_log false
            expects :values
            exposes :ds, type: Array, of: x do
              field :name, type: String
            end
            define_method(:call) { expose(ds: values) }
          end
          # A BARE `of: x` (no block) is ALSO guarded (a Data class gets member-derived output_schema
          # properties either way), so it is not a valid negative control here. Fully untyped elements
          # (`type: Array`, no `of:` at all) are the one shape this position's `output_schema` never
          # describes at all, and so the one shape genuinely unguarded.
          unguarded_klass = Class.new do
            include Axn
            auto_log false
            expects :values
            exposes :ds, type: Array
            define_method(:call) { expose(ds: values) }
          end

          # `Kernel#singleton_class` is idempotent — calling it twice on the SAME value returns the same
          # class, no new allocation the second time — so every measured value below must be one neither
          # class has rendered before. A throwaway call on ONE value warms each class's own memo
          # (output_schema/render-guard, built once and cached on the class, unrelated to this fix).
          Axn::Extensions::Serialization.render(guarded_klass.call(values: [x.new(name: "a")]))
          Axn::Extensions::Serialization.render(unguarded_klass.call(values: [x.new(name: "a")]))

          # Each Result is built OUTSIDE the measured window: `.call` itself runs full inbound/outbound
          # validation, no part of what this measures.
          unguarded_result = unguarded_klass.call(values: Array.new(50) { x.new(name: "a") })
          guarded_result = guarded_klass.call(values: Array.new(50) { x.new(name: "a") })

          GC.disable
          unguarded_before = ObjectSpace.count_objects[:T_CLASS]
          Axn::Extensions::Serialization.render(unguarded_result)
          unguarded_delta = ObjectSpace.count_objects[:T_CLASS] - unguarded_before

          guarded_before = ObjectSpace.count_objects[:T_CLASS]
          Axn::Extensions::Serialization.render(guarded_result)
          guarded_delta = ObjectSpace.count_objects[:T_CLASS] - guarded_before

          puts [unguarded_delta, guarded_delta].join(" ")
        RUBY

        out, status = Open3.capture2e(RbConfig.ruby, "-e", program)
        expect(status).to be_success, "subprocess failed: #{out}"
        unguarded_delta, guarded_delta = out.strip.split.map(&:to_i)

        expect(unguarded_delta).to eq(0) # the control itself must cost nothing, or the comparison proves nothing
        expect(guarded_delta).to eq(unguarded_delta)
      end

      # Codex review, PR #296, round 3: the action class is user-authored, so nothing stops it defining its
      # own singleton `instance_variable_get` -- a dispatched read of the guard cache would run THAT instead
      # of the real ivar, and a forged `[configs, nil]` return makes the identity check succeed while
      # disabling every displaced-projection guard.
      it "reads the render-guard cache through a bound ivar access, not a dispatched one a hostile action " \
         "class could override to forge a cache hit and disable every guard" do
        klass = shaped_action(type: s)
        klass.define_singleton_method(:instance_variable_get) do |name|
          return [external_field_configs, nil] if name == :@_axn_render_guards

          super(name)
        end

        expect { described_class.render(klass.call(value: public_s.new(name: "a", internal_notes: "x"))) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      # Codex review, PR #296, round 4: `@_axn_render_guards` follows the SAME single-underscore, per-class
      # ivar convention as its sibling `@_axn_validated_outbound` (and `@_axn_config_sources`/
      # `@_axn_config_overrides` elsewhere in this codebase) rather than the double-underscore convention
      # AGENTS.md documents for PER-INSTANCE framework state (`@__context`, set on a running action) -- but an
      # accidental value at that exact ivar slot, from whatever source, must fail SAFELY into a rebuild
      # rather than trust a wrong-shaped value or raise trying to index one.
      it "rebuilds rather than trusts a wrong-shaped value already at the render-guard ivar slot" do
        klass = shaped_action(type: s)
        klass.instance_variable_set(:@_axn_render_guards, true) # some unrelated truthy, non-Array value

        expect { described_class.render(klass.call(value: public_s.new(name: "a", internal_notes: "x"))) }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end
    end

    it "derives the action's class through a bound reader, not a dispatched #class (Codex #259, P2)" do
      # result.__action__ is a user-authored action instance -- nothing stops it defining its own
      # #class (axn's method-shadowing guards reserve call/_run/initialize, not class). A dispatched
      # .class returning a DIFFERENT class would fetch THAT class's external_field_configs instead of
      # this action's own -- other_tool shares the :count name (so axn's OWN internal exposure check,
      # which also reads self.class, doesn't fail first) but ALSO declares an :extra field klass
      # never does; reproduced pre-fix: render tried result.public_send(:extra) against klass's real
      # result and raised NoMethodError, rather than rendering this action's own single exposure.
      other_tool = Class.new do
        include Axn
        auto_log false
        exposes :count, type: Integer
        exposes :extra, optional: true
        def call = expose(count: 999)
      end

      klass = Class.new do
        include Axn
        auto_log false
        exposes :count, type: Integer
        def call = expose(count: 3)
      end
      klass.define_method(:class) { other_tool }

      expect(described_class.render(klass.call)).to eq("count" => 3)
    end
  end
end
