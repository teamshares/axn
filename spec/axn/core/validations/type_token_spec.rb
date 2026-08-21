# frozen_string_literal: true

# A field's own `type:` is the last position of the defect PRO-3165/PRO-3166 closed in every `of:` bag
# position: a token that is not a Class/Module, not a union of them, and not one of `:boolean`/`:uuid`/
# `:params` reaches `value.is_a?(token)` and raises a bare `TypeError: class or module required` on every
# call, naming neither the field nor the option. It was left open there because it is not an `of:` position
# — this pins the field-level guard that closes it (PRO-3207), reusing the same predicate rather than a
# fourth copy of it.
RSpec.describe "an unsupported type: token" do
  def unsupported(named)
    "type: must name a type — a Class, a union of them, or one of :boolean, :uuid, :params (got #{named})"
  end

  describe "every non-class spelling" do
    it "refuses a boolean" do
      expect { build_axn { expects :v, type: false } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    it "refuses an Integer" do
      expect { build_axn { expects :v, type: 5 } }
        .to raise_error(ArgumentError, unsupported("a value of class Integer"))
    end

    it "refuses a String naming a class by name rather than the class itself" do
      expect { build_axn { expects :v, type: "String" } }
        .to raise_error(ArgumentError, unsupported("a value of class String"))
    end

    it "refuses a Symbol outside the pseudo-type roster" do
      expect { build_axn { expects :v, type: :nonsense } }
        .to raise_error(ArgumentError, unsupported(":nonsense"))
    end

    # A union names types, so each member is judged as one and the OFFENDER is what gets named — not the
    # list, whose `inspect` would run every member's own.
    it "refuses a union carrying one, naming the offending member" do
      expect { build_axn { expects :v, type: [String, false] } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    # `nil` is an unsupported token like any other, and the one that hides from a `find`-based search: the
    # answer for "found nil" and for "found nothing" is the same object. Searched by INDEX for that reason
    # (`_reject_unsupported_type_token!`).
    it "refuses a union carrying nil" do
      expect { build_axn { expects :v, type: [String, nil] } }
        .to raise_error(ArgumentError, unsupported("a value of class NilClass"))
    end

    it "refuses the bag form naming one" do
      expect { build_axn { expects :v, type: { klass: false } } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    it "refuses a union inside the bag form" do
      expect { build_axn { expects :v, type: { klass: [String, nil] } } }
        .to raise_error(ArgumentError, unsupported("a value of class NilClass"))
    end

    # A Hash is a nested contract at an `of:` axis and a type token here, so it is refused rather than
    # skipped — and named as the Hash the author wrote, which needs the bare form answered before
    # `Array()` reaches it as its entry pairs and reports "a value of class Array".
    it "refuses a bag written where the class belongs" do
      expect { build_axn { expects :v, type: { klass: { klass: String } } } }
        .to raise_error(ArgumentError, unsupported("a value of class Hash"))
    end
  end

  # A field's `type:` has no second option left to constrain it — unlike a bag, which also has `of:`/
  # `shape:` — so "supplied but names nothing" is the bare-axis situation, not the bag one, and folds into
  # this guard exactly as `_reject_unsupported_map_axis!` folds it into itself rather than deferring
  # (contrast `_reject_unsupported_of_klass!`, which defers a bag's own emptiness elsewhere).
  describe "supplied but naming nothing" do
    it "refuses type: nil" do
      expect { build_axn { expects :v, type: nil } }
        .to raise_error(ArgumentError, unsupported("a value of class NilClass"))
    end

    it "refuses an empty union" do
      expect { build_axn { expects :v, type: [] } }
        .to raise_error(ArgumentError, unsupported("a value of class Array"))
    end

    it "refuses a bag naming an empty union" do
      expect { build_axn { expects :v, type: { klass: [] } } }
        .to raise_error(ArgumentError, unsupported("a value of class Array"))
    end

    it "refuses a bag carrying no klass: at all" do
      expect { build_axn { expects :v, type: { message: "custom" } } }
        .to raise_error(ArgumentError, unsupported("a value of class NilClass"))
    end
  end

  # The hole reached every position a field does, not just `expects` — the guard sits at the one seam
  # (`_canonicalize_validator_options!`) every one of these routes through.
  describe "every position, not just expects" do
    it "refuses one on exposes" do
      expect { build_axn { exposes :v, type: false } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    it "refuses one on a subfield" do
      expect do
        build_axn do
          expects :v
          expects :a, on: :v, type: false
        end
      end.to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    it "refuses one on an ambient subfield" do
      expect { build_axn { expects :a, on: :ambient_context, type: false } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    it "refuses one on a block-form shape member" do
      expect { build_axn { expects(:items, type: Array) { field :a, type: false } } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    it "refuses a union carrying nil on a block-form shape member" do
      expect { build_axn { expects(:items, type: Array) { field :a, type: [String, nil] } } }
        .to raise_error(ArgumentError, unsupported("a value of class NilClass"))
    end

    it "refuses one on a raw ShapeConfig member" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :n, validations: { type: false })
      expect { build_axn { expects :m, type: Hash, shape: { members: [member] } } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end
  end

  # `of:` holds `type:` to a STRICTLY NARROWER rule (Array or Hash only, since that class decides how `of:`
  # reads) and refuses every token this guard would, naming the classes that are actually legal there. This
  # guard defers to it entirely rather than firing first and prescribing the weaker fix — `_declared_of_container!`
  # runs unconditionally whenever `:of` is present, so deferring is always safe.
  describe "deferred to the of: container refusal" do
    it "leaves a non-class type: beside of: to the container message" do
      expect { build_axn { expects :v, type: false, of: Integer } }
        .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [a value of class FalseClass])")
    end

    it "leaves a non-class union beside of: to the container message" do
      expect { build_axn { expects :v, type: [Array, nil], of: Integer } }
        .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [Array, a value of class NilClass])")
    end

    # The container derivation this defers to (`_declared_of_container!`) reads `type:`'s klass through the
    # same safe `_declared_type_tokens` classifier this guard does — never `Kernel#Array()` — so a token
    # whose `to_ary` lies about naming the container directly, or raises, cannot slip past the deferral
    # (found by Codex review, round 4: the deferral bypassed the round-3 fix entirely, since it routes into
    # a DIFFERENT function that had its own separate, unfixed `Array()` call).
    it "still refuses a token whose to_ary lies about naming the container, even though of: is present" do
      liar = Object.new
      liar.define_singleton_method(:to_ary) { [Array] }

      expect { build_axn { expects :v, type: liar, of: Integer } }
        .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [a value of class Object])")
    end

    it "reports the declaration error rather than a raising to_ary's own exception, even though of: is present" do
      hostile = Object.new
      hostile.define_singleton_method(:to_ary) { raise("to_ary ran") }

      expect { build_axn { expects :v, type: hostile, of: Integer } }
        .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [a value of class Object])")
    end
  end

  # `shape:` is NOT deferred to, unlike `of:` — deliberately. `shape:`'s own container check (via
  # `_shape_compatible_type!`/`_reject_non_class_container!`) often ALSO judges `type:`, but only when the
  # shape supplies no `container:` of its own; a shape carrying its own already-valid one skips that
  # derivation entirely, leaving `type:` unjudged by anything. Detecting which state applies would mean
  # reading the shape's own `container:` a second time, independent of whatever the container-derivation
  # code reads — and a hostile `[]` that answers differently between the two reads could let a bad `type:`
  # slip through both checks (found by Codex review, round 2, on a raw shape MEMBER whose nested `shape:`
  # was a Hash subclass with a stateful `[]`). Checking `type:` here UNCONDITIONALLY whenever `shape:` is
  # present sidesteps the whole question — this guard's verdict never depends on reading anything twice.
  describe "not deferred to shape:, even when a container check there would also catch it" do
    it "still catches a non-class type: on a block-form shape" do
      expect { build_axn { expects(:v, type: false) { field :a, type: String } } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    it "still catches a non-class union on a raw shape:" do
      expect { build_axn { expects :v, type: ["Hash", Hash], shape: { members: [] } } }
        .to raise_error(ArgumentError, unsupported("a value of class String"))
    end

    # The exact combination Codex's round-1 finding named: a raw `shape:` supplying its own already-valid
    # `container:` skips the shape's own derivation entirely, so this guard is the only thing that catches
    # `type: false` here at all.
    it "still catches a non-class type: when the shape: supplies its own valid container:" do
      expect { build_axn { expects :v, type: false, shape: { members: [], container: Hash } } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    # The exact combination Codex's round-2 finding named: a raw shape MEMBER whose nested `shape:` is a
    # Hash subclass with a stateful `[]` — answering `nil` the first time `:container` is read and a valid
    # class the second — so a guard that reads it once to decide whether to defer, and trusts a LATER,
    # independent read elsewhere to actually validate `type:`, can be fooled into checking nothing at all.
    # This guard has no such gap: it never reads the shape's container, so there is nothing to fool.
    it "still catches a non-class type: on a member whose nested shape: has a lying container reader" do
      lying_shape = Class.new(Hash) do
        def initialize(*)
          super
          @reads = 0
        end

        def [](key)
          return super unless key == :container

          @reads += 1
          @reads == 1 ? nil : Hash
        end
      end.new
      lying_shape[:members] = []
      member = Axn::Core::Contract::ShapeConfig.new(field: :n, validations: { type: false, shape: lying_shape })

      expect { build_axn { expects :m, type: Hash, shape: { members: [member] } } }
        .to raise_error(ArgumentError, unsupported("a value of class FalseClass"))
    end

    # A GOOD `type:` still leaves a genuinely bad explicit `container:` to the shape's own message — this
    # guard only ever speaks about `type:` itself, never about `container:`.
    it "leaves a bad explicit container: (with a good type:) to the shape message" do
      expect { build_axn { expects :v, type: Hash, shape: { members: [], container: 5 } } }
        .to raise_error(ArgumentError, /container.*must be a class.*Integer/)
    end
  end

  describe "controls" do
    it "leaves a class alone" do
      action = build_axn { expects :v, type: String }

      expect(action.call(v: "x")).to be_ok
      expect(action.call(v: 1)).not_to be_ok
    end

    # A `Module` covers a class and a module both, tested with `case`/`when` so nothing the token defines
    # decides whether it is one — a Module is as much a type as a class.
    it "leaves a MODULE alone" do
      action = build_axn { expects :v, type: Comparable }

      expect(action.call(v: 1)).to be_ok
    end

    it "leaves each pseudo-type alone" do
      expect { build_axn { expects :v, type: :boolean } }.not_to raise_error
      expect { build_axn { expects :v, type: :uuid } }.not_to raise_error
      expect { build_axn { expects :v, type: :params } }.not_to raise_error
    end

    it "leaves a union of a class and a pseudo-type alone" do
      action = build_axn { expects :v, type: [String, :uuid] }

      expect(action.call(v: "x")).to be_ok
    end

    it "leaves Data/Struct alone, as ordinary classes" do
      point = Data.define(:x)
      holder = Struct.new(:x)

      expect { build_axn { expects :v, type: point } }.not_to raise_error
      expect { build_axn { expects :v, type: holder } }.not_to raise_error
    end

    # The offender is named through `_declared_type_label`, never its own `inspect`/`to_s` — a token can
    # define either, and one that raises while a declaration error is built would replace this
    # ArgumentError with the caller's exception (outside StandardError, escaping every rescue meant to
    # settle it).
    it "reports the declaration error rather than the token's own exception" do
      impostor = Object.new
      impostor.define_singleton_method(:to_s) { raise("to_s ran") }
      impostor.define_singleton_method(:inspect) { raise("inspect ran") }

      expect { build_axn { expects :v, type: impostor } }
        .to raise_error(ArgumentError, unsupported("a value of class Object"))
    end

    # `_supported_type_token?` classifies through `case`/`when ::Module`, never `is_a?` — a value that
    # lies about its own `is_a?` still cannot pass itself off as a Module. Declared inside the type bag,
    # since the bare-`type:` sugar asks a value `is_a?(Hash)` before this guard is ever reached (the same
    # workaround `nil_empty_axes_matrix_spec.rb` uses for the identical reason).
    it "is immune to a token that lies about is_a?" do
      impostor = Object.new
      impostor.define_singleton_method(:is_a?) { |_klass| true }

      expect { build_axn { expects :v, type: { klass: impostor } } }
        .to raise_error(ArgumentError, unsupported("a value of class Object"))
    end

    # `_declared_type_tokens` classifies the union-or-single-token split through `case`/`when ::Array`,
    # never `Kernel#Array()` — `Array()` tries `to_ary` (then `to_a`) before wrapping, and both are the
    # caller's own methods: one defining `to_ary` decides how it gets read (returning `[String]` would wave
    # a genuinely unsupported token through as if it were a union naming a real class), and one whose
    # `to_ary` raises replaces this guard's actionable `ArgumentError` with whatever it throws (found by
    # Codex review, round 3).
    it "is immune to a token whose to_ary lies about being a union of real classes" do
      liar = Object.new
      liar.define_singleton_method(:to_ary) { [String] }

      expect { build_axn { expects :v, type: liar } }
        .to raise_error(ArgumentError, unsupported("a value of class Object"))
    end

    it "reports the declaration error rather than a raising to_ary's own exception" do
      hostile = Object.new
      hostile.define_singleton_method(:to_ary) { raise("to_ary ran") }

      expect { build_axn { expects :v, type: hostile } }
        .to raise_error(ArgumentError, unsupported("a value of class Object"))
    end
  end
end

# `model:`'s `klass:` has the identical hole: `ModelValidator#validate_each` builds a `TypeValidator` over
# the same bag and delegates, so a token outside its grammar reaches the same `value.is_a?(token)` and
# raises the same bare `TypeError` on every call. The grammar is narrower than `type:`'s, though — a model
# field resolves a record by calling a finder method ON `klass:`, never by asking a value `is_a?` of it, so
# a union or a pseudo-type Symbol has nothing to dispatch through and is refused rather than accepted.
RSpec.describe "an unsupported model: token" do
  def unsupported_model(named)
    "model: klass: must name a single Class or Module (got #{named}) — a model field resolves a record " \
      "by calling a finder method on this class, so a union or a pseudo-type has nothing to dispatch through."
  end

  describe "every non-class spelling" do
    it "refuses an Integer" do
      expect { build_axn { expects :v, model: 5 } }
        .to raise_error(ArgumentError, unsupported_model("a value of class Integer"))
    end

    it "refuses a Symbol" do
      expect { build_axn { expects :v, model: :nonsense } }
        .to raise_error(ArgumentError, unsupported_model(":nonsense"))
    end

    it "refuses the bag form naming one" do
      expect { build_axn { expects :v, model: { klass: 5 } } }
        .to raise_error(ArgumentError, unsupported_model("a value of class Integer"))
    end
  end

  # Nobody declares `model:` with a union — there is exactly one class to resolve a record through — and
  # the runtime hole it opens is worse than a crash: `TypeValidator` iterates a union happily, so
  # `FieldResolvers::Model#derive_value` reaches `[A, B].respond_to?(:find)` (true, via `Enumerable#find`)
  # and calls `Array#find` instead of either class's own finder, silently resolving to the wrong thing
  # under `best_effort` rather than raising at all.
  describe "a union" do
    it "refuses two real classes" do
      a = Struct.new(:id)
      b = Struct.new(:id)

      expect { build_axn { expects :v, model: [a, b] } }
        .to raise_error(ArgumentError, unsupported_model("a value of class Array"))
    end

    it "refuses a union carrying nil" do
      expect { build_axn { expects :v, model: [String, nil] } }
        .to raise_error(ArgumentError, unsupported_model("a value of class Array"))
    end
  end

  describe "controls" do
    it "leaves a real class alone" do
      record = Struct.new(:id) { def self.find(id) = new(id) }
      action = build_axn do
        expects :v, model: record
        exposes :got
        def call = expose(got: v)
      end

      expect(action.call(v_id: 5).got).to eq(record.new(5))
    end

    it "leaves a real class named by String alone" do
      stub_const("RealModelToken", Struct.new(:id) { def self.find(id) = new(id) })
      action = build_axn do
        expects :v, model: "RealModelToken"
        exposes :got
        def call = expose(got: v)
      end

      expect(action.call(v_id: 5).got).to eq(RealModelToken.new(5))
    end

    it "leaves model: true (defaulted from the field name) alone" do
      stub_const("V", Struct.new(:id) { def self.find(id) = new(id) })
      action = build_axn do
        expects :v, model: true
        exposes :got
        def call = expose(got: v)
      end

      expect(action.call(v_id: 5).got).to eq(V.new(5))
    end

    # A Module is as much a dispatch target as a Class — `ApiService.find_by_id`-style namespaces are a
    # documented use case — so it is accepted at declaration on the same terms `type:` accepts one.
    it "leaves a Module alone" do
      mod = Module.new { def self.find(id) = id }

      expect { build_axn { expects :v, model: mod } }.not_to raise_error
    end

    # `false`/`nil` are both falsy in Ruby, so `apply_syntactic_sugar`'s `options[:klass] ||= fields.first
    # .to_s.classify` fallback used to swallow them into the SAME "please infer" path `model: true` takes —
    # meaning `model: false` either raised a confusing `NameError: uninitialized constant User` (no such
    # constant) or silently, successfully resolved through `User` (one happens to exist), depending on
    # unrelated global state (found by Codex review, round 4). `_reject_falsy_model_klass!` now catches this
    # before the sugar ever runs, regardless of what else the app defines.
    it "rejects a falsy klass: outright, regardless of whether the inferred constant happens to exist" do
      stub_const("V", Class.new { def self.find(_id) = new })

      message = "model: klass: false/nil is not a type to resolve a record through — pass `model: true` " \
                "(or omit klass: entirely) to infer the class from the field name, or name the class explicitly."
      expect { build_axn { expects :v, model: false } }.to raise_error(ArgumentError, message)
      expect { build_axn { expects :v, model: nil } }.to raise_error(ArgumentError, message)
      expect { build_axn { expects :v, model: { klass: false } } }.to raise_error(ArgumentError, message)
      expect { build_axn { expects :v, model: { klass: nil } } }.to raise_error(ArgumentError, message)
    end

    it "leaves model: true alone, the one falsy-adjacent spelling that means please infer" do
      stub_const("V", Class.new { def self.find(_id) = new })

      expect { build_axn { expects :v, model: true } }.not_to raise_error
    end

    # `model: { finder: ... }` with no `klass:` at all infers the class exactly as `model: true` does,
    # only overriding the finder — a documented, spec-covered spelling (`reader_alias_spec.rb`) this guard
    # must not treat as "explicitly falsy": an ABSENT key is not the same state as one written as `nil`.
    it "leaves a klass:-less bag alone" do
      stub_const("V", Class.new { def self.find(_id) = new })

      expect { build_axn { expects :v, model: { finder: :find } } }.not_to raise_error
    end
  end
end
