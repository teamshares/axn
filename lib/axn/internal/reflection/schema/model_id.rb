# frozen_string_literal: true

require "axn/internal/field_config"
# A model id renders through the same serializer every other emitted literal does.
require "axn/internal/reflection/values"

module Axn
  module Internal
    module Reflection
      module Schema
        # The `<field>_id` property a `model:` field generates, and the reconciliation that decides its type.
        # A model field takes a RECORD at runtime but a lookup TOKEN on the wire, so this is the one place the
        # document describes something the declaration never names directly — inferred from the model class's
        # own primary key where it can be, reconciled against an explicitly-declared `id_type:` or an explicit
        # sibling field where those exist, and refused at declaration where they disagree.
        module ModelId
          # Which token `model_id_type_token` infers for each ActiveRecord primary-key attribute type
          # (`klass.type_for_attribute(klass.primary_key).type`). Every value here is one of
          # `Internal::FieldConfig::MODEL_ID_TYPE_TOKENS` — that constant, not a copy of it here, is what
          # Contract's declaration-time `id_type:` guard also reads, so the declared and inferable
          # vocabularies cannot drift apart (`Internal::Reflection::X` derives a JSON view and nothing
          # runs upward FROM it into declaration-time code, per AGENTS.md). An AR type with no entry
          # (`:binary`, `:decimal`, a custom `ActiveRecord::Type` this table doesn't know) falls back to
          # today's untyped property rather than guessing.
          AR_PRIMARY_KEY_TYPE_TOKENS = {
            integer: Integer,
            string: String,
            uuid: :uuid,
          }.freeze

          # Returns [id_field_symbol, prop_hash] for a model: config, given the id's ALREADY-RESOLVED type
          # token (or nil for the untyped fallback) — computed by the caller via
          # `reconciled_model_id_type_token`, never re-derived here, so a merged node's multiple model
          # routes are reconciled exactly once regardless of which route's config this happens to build
          # the description/klass from. Projected through the SAME `single_type_for` this module already
          # uses for every declared `type:`, so the JSON type table has one owner and `:uuid` gets its
          # `format: "uuid"` for free.
          def model_id_property(config, id_type)
            model_opts = config.validations[:model]
            klass = model_opts[:klass]
            # The declared class written into PROSE, which owes both halves of that obligation: the name is read
            # natively (`ClassName.of_module` binds `Module#to_s`, so a `name`/`to_s` of the class's own cannot
            # answer it — measured, one that raises took the whole reflection down), and its bytes are RENDERED,
            # because a constant may hold non-UTF-8 ones that cannot be joined to axn's prose at all. The
            # declaration guard has already refused a non-Module `model:` token, so the receiver is always a
            # Module here; `Module#to_s` also names an ANONYMOUS class, where the `name` this replaces answered
            # nil and left the description reading "ID of the  record".
            klass_name = Axn::Internal::Text.renderable(Axn::Internal::ClassName.of_module(klass))
            id_field = Axn::Internal::FieldConfig.model_id_key(config.field)
            prop = { description: config.description || "ID of the #{klass_name} record" }

            apply_single_type!(prop, single_type_for(id_type, for_output: false), config, nullable: nil_allowed?(config)) if id_type

            [id_field, prop.compact]
          end

          # The token behind a model config's OWN emitted type, or nil for today's untyped fallback. A
          # declared `id_type:` always wins, whatever the finder and whether or not the class is
          # ActiveRecord at all. Absent that, infer from the class's own primary key — but ONLY when doing
          # so cannot silently mislead: the finder must resolve BY that primary key
          # (`by_primary_key_finder?` — a custom finder's token has no reason to share the PK's type), and
          # the class's ancestry must NATIVELY include ActiveRecord::Base (`includes_module?`, never
          # `klass < ActiveRecord::Base`, which the class is free to override). Every other combination —
          # a PORO, a custom finder, no ActiveRecord loaded at all — returns nil, same as before this
          # method existed.
          def model_id_type_token(model_opts, klass)
            return model_opts[:id_type] if model_opts.key?(:id_type)
            return nil unless defined?(::ActiveRecord::Base)
            return nil unless Axn::Internal::NativeMethods.includes_module?(klass, ::ActiveRecord::Base)
            return nil unless Axn::Internal::FieldConfig.by_primary_key_finder?(model_opts)

            infer_ar_primary_key_type_token(klass)
          end

          # The single id-type TOKEN to emit for a (possibly merged) wire node's model routes, or nil for
          # the untyped fallback. A DECLARED `id_type:` agreed across every route always wins outright —
          # never merely one candidate among the inferred ones, which let a route's explicit claim collide
          # with, and be rejected against, another route's UNASKED-FOR AR inference. Only absent any
          # declared `id_type:` does this fall back to reconciling each route's OWN inferred type
          # (`model_id_type_token`, evaluated per config against its own `klass` — a merged node's routes
          # may each point at a different AR class). Distinct non-nil inferred results are compared by
          # simple `.uniq`, always safe here since every value in play is one of the CLOSED
          # `Internal::FieldConfig::MODEL_ID_TYPE_TOKENS` (never a caller-supplied class with hostile
          # equality).
          #
          # Two routes' MERELY INFERRED types disagreeing degrades to the untyped fallback rather than
          # raising: unlike a declared `id_type:` conflict, NEITHER author asked for a type check here — two
          # legitimate model routes at one node simply happen to point at AR classes with different
          # primary-key column types, which is an entirely legal runtime contract (each route resolves
          # through its own class's own `.find`). Reflection's inference is opportunistic everywhere else in
          # this feature (a composite PK, an unreachable connection, a custom finder all fall back silently
          # rather than erroring), and `Axn::Tools.validate_contracts!` runs this at APP BOOT — raising here
          # would let an add-on schema *nicety* take an otherwise working application down. A DECLARED
          # disagreement stays a hard error (an author's own explicit, conflicting words about the SAME
          # property, caught above by `reconciled_declared_id_type`); an INFERRED one is just inference
          # failing to reach a confident answer, same as every other inference gap this method already
          # treats that way.
          def reconciled_model_id_type_token(model_configs, id_field)
            declared = reconciled_declared_id_type(model_configs, id_field)
            return declared if declared

            tokens = model_configs.filter_map { |c| model_id_type_token(c.validations[:model], c.validations[:model][:klass]) }.uniq
            tokens.size == 1 ? tokens.first : nil
          end

          # THE single DECLARED `id_type:` agreed across a (possibly merged) node's model routes, or nil
          # when none declares one — never touches inference, so this is always cheap and non-dispatching
          # and safe to compute regardless of whether an explicit sibling is about to make the result
          # moot. Raises when two-plus routes declare DISAGREEING values, checked here rather than left
          # for a later inference-vs-declared mismatch to surface confusingly: a declared claim must be
          # resolved, and found consistent, entirely on its own terms before it is ever weighed against
          # either an explicit sibling (`reject_model_id_type_conflict!`) or another route's mere AR
          # inference (`reconciled_model_id_type_token`) — both call this first and trust its answer
          # outranks whatever they'd otherwise derive.
          def reconciled_declared_id_type(model_configs, id_field)
            declared = declared_model_id_types(model_configs)
            return declared.first if declared.size <= 1

            raise ArgumentError,
                  "multiple model: routes declare disagreeing id_type: values for the same generated " \
                  "#{renderable_id_field(id_field)} (#{declared.map(&:inspect).join(' vs ')}) — declare " \
                  "it consistently across every route, or only on one."
          end

          # THE distinct DECLARED `id_type:` tokens across a (possibly merged) node's model routes —
          # `reconciled_declared_id_type` (above) is the single-value form every caller actually wants;
          # this is the raw set it (and its own emptiness check) reads.
          def declared_model_id_types(model_configs)
            model_configs.filter_map { |c| c.validations[:model][:id_type] if c.validations[:model].key?(:id_type) }.uniq
          end

          # Reads the class's OWN primary key type — a genuine dispatch into ActiveRecord (and, through
          # it, any custom `ActiveRecord::Type` the class itself registered), the one deliberate exception
          # to this module's no-dispatch doctrine (see the header comment on
          # reflection_does_not_dispatch_spec.rb, which states it). Rescued broadly rather than narrowly:
          # no database connection (`ActiveRecord::NoDatabaseError`), no such table
          # (`ActiveRecord::StatementInvalid`), and any other misconfiguration are all ordinary, expected
          # outcomes here — reflection must never fail a schema build over a class it cannot fully
          # introspect — so every one of them falls back to the SAME untyped property a PORO model or a
          # custom finder already gets, never surfaces as an exception, and never touches boot at all
          # beyond the one probe `Axn::Tools.validate_contracts!` triggers per tool class.
          #
          # A composite primary key (an Array) and a tableless/keyless model (nil) are both declared
          # non-goals of the `<field>_id` reader convention itself
          # (internal-docs/specs/2026-06-17-model-id-reader-design.md:38-40), so both fall back here too,
          # deliberately, rather than being treated as an error.
          def infer_ar_primary_key_type_token(klass)
            pk = klass.primary_key
            return nil unless pk.is_a?(::String)

            AR_PRIMARY_KEY_TYPE_TOKENS[klass.type_for_attribute(pk).type]
          rescue StandardError
            nil
          end

          # A model lookup needs a non-nil token. Single source of truth for the generated `<field>_id`'s
          # requiredness AND nullability, considering the model field plus any explicit `<field>_id` sibling
          # (order-independent — runs after all properties are built).
          #
          # The id is OMITTABLE only when the model field itself is omittable (a nil-tolerant model, or one
          # with its own usable default) AND no descendant requires presence per its own annotation (a
          # defaulted descendant is self-rescuing at read time). A subfield default now applies at read time
          # at any depth under a model — value-level defaults, PRO-2889, no synthesis involved — so a
          # defaulted descendant resolves to its own value and never forces the id; only a descendant with no
          # rescuing signal (no usable default, not nil-tolerant) strands an omitted record and keeps the id
          # required. OR an explicit `<field>_id` sibling carries a usable DEFAULT (inbound defaults supply
          # the token before the lookup). A merely nullable/optional explicit id with no default doesn't help.
          # When the id IS required it also can't be null, so any `null` branch is stripped.
          #
          # KNOWN LIMITATION (accepted divergence): this covers a shallow model field and its explicit shallow
          # id sibling. Self-referential id/model contracts nested under a parent (a `model:` subfield with a
          # sibling defaulted `<field>_id` subfield) are not reconciled here — the parent may reflect as
          # required though runtime synthesizes it. That is the safe direction (stricter than runtime).
          def apply_model_id_requiredness!(config, children, field_configs, properties, required, ann)
            # The key alone, not `model_id_property(config)` — this pass runs for EVERY model config
            # regardless of whether an explicit sibling exists, so re-deriving the whole property here
            # would re-run the same (possibly AR-dispatching, PRO-3384) inference `build_input` already
            # skipped or already discarded, for a value this method never reads.
            id_field = Axn::Internal::FieldConfig.model_id_key(config.field)
            # Excludes a model config sharing this name such a config never writes to THIS key (it emits
            # its own generated id one level deeper) and never rescues it with a default of its own, so
            # matching one here would misattribute both the type-conflict check below and the
            # `usable_default?` rescue just past it.
            explicit_id = field_configs.find { |c| c.field == id_field && !c.validations[:model] }
            reject_model_id_type_conflict!([config], explicit_id, id_field)
            merge_model_id_type_into_sibling!(properties[id_field], [config], explicit_id, id_field) if properties[id_field]
            # A default at ANY depth under the model applies at read time (value-level defaults,
            # PRO-2889) — no synthesis is involved — so descendant omittability is the ordinary
            # annotation-derived rule, same as every other parent.
            model_omittable = optional_for_schema?(config) && !children_require_presence?(children, ann)
            return if model_omittable || (explicit_id && usable_default?(explicit_id, subfield: false))

            key = id_field.to_s
            required << key unless required.include?(key)
            reject_null!(properties[id_field]) if properties[id_field]
          end

          # A declared `id_type:` and an explicit `<field>_id` sibling's OWN `type:` are two claims about the SAME
          # wire property, and the sibling always wins the emitted one (its branch writes unconditionally; the
          # model's only `||=`s) regardless of which is declared first, at either depth — so a disagreement between
          # the two would otherwise be swallowed with no sign the model ever said something else. Reject it
          # outright rather than let the overwrite silently pick a winner, matching the family PRO-2901 already
          # rejects (two conflicting claims about one merged wire node). Shared by both call sites (top-level
          # `apply_model_id_requiredness!`, which passes a one-element `[config]`; nested `apply_children!`, which
          # passes every route's config at that merged node), each passing its own `id_field` since a nested one
          # derives it from the wire KEY rather than from a config's `field` (an `as:`-aliased subfield can
          # differ).
          #
          # First reconciles the DECLARED side across every route (`declared_model_id_types` — cheap,
          # non-dispatching, and correct even when an explicit sibling makes `model_id_property` itself
          # unreachable): two routes each declaring a disagreeing `id_type:` is rejected here before either is ever
          # compared to a sibling. Only once that resolves to at most one candidate is it compared against the
          # sibling — derived from CONFIGS via `single_type_for`/`json_type_for`, not from an already-built
          # property, so it needs neither side to have been emitted yet (the nested call site cannot guarantee its
          # sibling node was visited first in the same pass).
          #
          # Compared on the FULL projected constraint — base `:type` AND `:format` (comparing `:type` alone let
          # `id_type: :uuid` beside an explicit `type: String` sibling through silently, since both project to the
          # same base `"string"`, quietly dropping the uuid-shape requirement the declaration asked for) — but the
          # direction is deliberately asymmetric, not a strict equality: a sibling only needs to be AT LEAST as
          # constrained as `id_type:` demands, never exactly as loose. `id_type: String` (no format) is satisfied
          # by an explicit `type: :uuid` sibling (a valid REFINEMENT — nothing the declaration claimed is
          # contradicted), while `id_type: :uuid` is NOT satisfied by a plain `type: String` sibling (a WIDENING —
          # the declared format constraint would silently vanish). `type_pair_satisfies?` below encodes exactly
          # that: the base type must match, and only when `id_type:` itself asserts a `format` must the sibling
          # assert the SAME one.
          #
          # EVERY branch of an explicit UNION sibling must satisfy it, not merely one: `id_type: Integer` beside an
          # explicit `type: [Integer, String]` sibling has an integer branch that trivially satisfies the check,
          # but the WINNING property is the WHOLE union — admitting the string branch too — so accepting on any one
          # satisfied branch let the sibling silently widen past what `id_type:` promised.
          #
          # A sibling whose type resolves to NOTHING BUT `null` needs its own rule: `json_type_pairs` strips the
          # `null` branch (requiredness is reconciled elsewhere), so a null-ONLY sibling — `type: NilClass` —
          # reduces to an EMPTY set, and a bare `.all?` on that empty set is vacuously true — which would let a
          # null-only sibling silently satisfy ANY declared `id_type:`, whether or not the model can ever actually
          # go without a real id. An EMPTY (post-strip) set here can only mean every branch the sibling admits was
          # null (`explicit_id.validations` is already known to carry a `:type` key by the time this runs, and
          # `json_type_for` never returns `{}` for one on input), so `sibling_satisfies_declared_id_type?` (below)
          # treats it as a question about the MODEL's own nullability rather than deciding it outright — see there
          # for why.
          def reject_model_id_type_conflict!(model_configs, explicit_id, id_field)
            declared = reconciled_declared_id_type(model_configs, id_field)
            return if declared.nil?
            return unless explicit_id

            declared_shape = single_type_for(declared, for_output: false)
            # `build_property`, not `json_type_for(explicit_id.validations, ...)`: `json_type_for` alone
            # doesn't know about the tolerance-driven relaxations `build_property` applies afterward — a
            # blank-tolerant `type: :uuid` sibling still projects `format: "uuid"` through `json_type_for`
            # alone, so comparing against IT said "satisfies", while the ACTUAL winning property (built the
            # same way `build_input` builds every other property) drops that format for exactly the reason
            # `apply_single_type!`'s own comment gives: a blank value would fail a strict `format: "uuid"` the
            # runtime doesn't enforce. Comparing the raw pre-relaxation shape let the format vanish with no
            # error; comparing the real emitted one catches it.
            sibling_prop = build_property(explicit_id)
            # Gated on the BUILT property carrying a type- or enum-bearing key, not on
            # `explicit_id.validations` having a `:type` entry:
            # `inclusion:`/`numericality:` alone — no `type:` at all — can still make `json_type_for` (and
            # so `build_property`) infer a type (an `inclusion: { in: ["abc"] }` sibling emits `{type:
            # "string", ...}`), and a HETEROGENEOUS `inclusion:` set (`in: [1, "abc"]`) can't reduce to one
            # type at all, so `json_type_for` emits `enum:` alone with NEITHER `:type` nor `:anyOf` —
            # `build_property` still applies it as the value constraint (see `apply_type_info!`'s own
            # enum-only branch). Gating on the raw validations, or on `:type`/`:anyOf` alone, skipped the
            # comparison entirely for exactly these siblings, letting a declared `id_type: Integer` silently
            # lose to an inferred (or enum-admitted) type with no error. A sibling with NONE of these three
            # keys is the one genuine "nothing to compare" case (a bare `default:`, say) — everything else
            # must be checked, the null-only.
            return unless sibling_prop.key?(:type) || sibling_prop.key?(:anyOf) || sibling_prop.key?(:enum)

            typed, satisfied = sibling_satisfies_declared_id_type?(sibling_prop, declared_shape, model_configs)
            return if satisfied

            # Same `typed` branch the check above used, so the message names whichever half of the
            # property actually decided the verdict — a homogeneous single-value `inclusion:` sibling
            # carries BOTH a `:type` (what the comparison above used) and an `:enum` (its value
            # constraint), and describing it by the wrong one would misname what actually disagreed.
            explicit_desc = if typed
                              json_type_pairs(sibling_prop).map { |pair| pair[:format] ? "#{pair[:type]}/#{pair[:format]}" : pair[:type] }
                            else
                              # `Identity.describe`, not a raw `.inspect`: an `inclusion:` set's members
                              # are the AUTHOR'S OWN literals, and one whose `inspect` raises (or answers
                              # something not a String) would replace this ArgumentError with its own
                              # exception while the message is being built — `describe` reads it the same
                              # non-dispatching way every other foreign value in this codebase's messages
                              # is named.
                              ["enum: [#{Array(sibling_prop[:enum]).map { |v| Internal::Identity.describe(v) }.join(', ')}]"]
                            end
            explicit_desc = ["null-only"] if explicit_desc.empty?
            raise ArgumentError,
                  "model: id_type: #{declared.inspect} disagrees with the explicitly declared " \
                  "#{renderable_id_field(id_field)}'s own type: (#{explicit_desc.join(', ')}) — declare " \
                  "one or the other."
          end

          # Whether a sibling's projected type/enum satisfies a declared `id_type:`, and whether the check
          # ran the typed or the enum-only branch (the caller needs `typed` again to describe a mismatch).
          # Extracted from `reject_model_id_type_conflict!` (which the accumulated findings against
          # this one check pushed over this file's complexity budget) rather than folding another branch
          # into that method's body.
          #
          # The enum-only branch checks each LITERAL's own base JSON type (`enum_scalar_type`, the same
          # classifier `json_type_for`'s own inclusion branch already uses) against `declared_shape` —
          # reading each literal's real class, never a method it defines, the same non-dispatching
          # discipline as everywhere else reflection classifies a caller-supplied value. KNOWN LIMITATION,
          # stated rather than hidden: this checks base TYPE only, not `id_type: :uuid`'s FORMAT — a
          # homogeneous String `inclusion:` set of non-uuid-shaped literals still passes, since the uuid
          # pattern is TypeValidator's own regex, a runtime-layer concern this reflection module has no
          # dependency on and should not duplicate.
          #
          # A null-only sibling (every branch strips to empty) is satisfied — not a conflict — exactly when
          # EVERY model route at this node also tolerates nil: `model: ..., allow_nil: true` beside
          # `company_id, type: NilClass, optional: true` is a genuinely working, callable pairing (verified:
          # `.call` succeeds with the id omitted OR explicitly nil), and the declared `id_type:` is never
          # actually contradicted since the sibling never carries a non-null value for it to disagree with.
          # It's a real conflict only when some route does NOT tolerate nil — there, the id is REQUIRED to
          # resolve a record at least sometimes, but the sibling can never supply one, and THAT combination
          # fails at every call (also verified). `.all?`, not `.any?`: a single non-nilable route among
          # several merged ones still needs a real id sometimes.
          def sibling_satisfies_declared_id_type?(sibling_prop, declared_shape, model_configs)
            null_only_ok = model_configs.all? { |c| nil_allowed?(c) }
            typed = sibling_prop.key?(:type) || sibling_prop.key?(:anyOf)
            type_ok = if typed
                        explicit_pairs = json_type_pairs(sibling_prop)
                        explicit_pairs.empty? ? null_only_ok : explicit_pairs.all? { |pair| type_pair_satisfies?(declared_shape, pair) }
                      end
            # An `inclusion:` sibling's own literals satisfy on base type ALONE, matching this method's
            # KNOWN LIMITATION for the enum-only case (a homogeneous String `inclusion:` set of
            # non-uuid-shaped literals already passes there, deliberately, rather than duplicating
            # TypeValidator's own uuid regex) — checked here too whenever the sibling carries an `:enum`,
            # not gated behind `typed` being false: `type: String, inclusion: { in: [uuid_string] }` builds
            # BOTH `:type` and `:enum`, so `typed` is true and the bare type-pair check alone fails a
            # required `id_type: :uuid` (the sibling's plain `type: String` carries no `format: "uuid"` of
            # its own) — a real value-level match rejected only because an explicit `type:` happened to sit
            # beside the `inclusion:` that already narrows it, which is backwards: adding a type shouldn't
            # make an otherwise-tolerated enum stricter.
            enum_ok = if sibling_prop.key?(:enum)
                        literals = Array(sibling_prop[:enum]).compact
                        literals.empty? ? null_only_ok : literals.all? { |literal| enum_scalar_type(literal) == declared_shape[:type] }
                      end
            satisfied = typed ? (type_ok || enum_ok) : enum_ok
            [typed, satisfied]
          end

          # A declared `id_type:` beside an explicit sibling that emits no type of its OWN at all (a bare
          # `default:`, `length:`, or other metadata-only declaration — the one case
          # `reject_model_id_type_conflict!` above deliberately has nothing to compare, so it returns
          # without raising) is not a conflict, but it isn't free either: nothing else was ever going to
          # write a `:type` there, since the sibling always wins the emitted property outright — so the
          # declared `id_type:` has to be merged in explicitly, or it is simply lost with no error and no
          # trace. Mutates `target_property` (the sibling's OWN already-built emission) in place; a no-op
          # whenever there is nothing to merge (no declared type, no sibling, or the sibling already
          # carries type/anyOf/enum of its own — which `reject_model_id_type_conflict!` has already
          # either accepted as compatible or raised on, so this method never overwrites a type the
          # sibling itself asserted).
          def merge_model_id_type_into_sibling!(target_property, model_configs, explicit_id, id_field)
            return unless explicit_id
            return if target_property.key?(:type) || target_property.key?(:anyOf) || target_property.key?(:enum)

            declared = reconciled_declared_id_type(model_configs, id_field)
            return if declared.nil?

            # The SIBLING's own nullability/blank-tolerance, not the model config's — `target_property` is
            # the sibling's emission, so its own `allow_nil:`/`allow_blank:` govern whether `"null"` joins
            # the merged type and whether a blank-tolerant `:uuid`'s `format:` stands down (the same rule
            # `apply_single_type!` already applies for every other property).
            apply_single_type!(target_property, single_type_for(declared, for_output: false), explicit_id, nullable: nil_allowed?(explicit_id))
            # `reject_null!` already ran on this (untyped) property earlier in the same build and, finding
            # no `:type` to narrow, fell back to its `not: { type: "null" }` marker — now redundant (a real
            # `:type` excludes null on its own, and `apply_single_type!` just decided that question fresh)
            # and, left in place, a confusing double-marker beside the type that just replaced its reason
            # for existing.
            target_property.delete(:not) if target_property[:not] == { type: "null" }
          end

          # `id_field` rendered safely into an error message — `Values.canonical_wire_key` (already a
          # dependency of this file) renders its actual UTF-8 characters when the bytes convert, falling
          # back to `Symbol#inspect` — which a genuine Symbol (never a caller-subclassable object; every
          # `id_field` here comes from `FieldConfig.model_id_key`, which always returns one) answers
          # without running anything overridable, and always in valid UTF-8 even for exotic bytes. Bare
          # interpolation would risk `Encoding::CompatibilityError` from THIS message's own UTF-8 text:
          # `model_id_key` always returns a Symbol, but nothing stops that Symbol from holding a legal,
          # ASCII-compatible, non-UTF-8 encoding (a Latin-1 field name).
          def renderable_id_field(id_field)
            Values.canonical_wire_key(id_field) || id_field.inspect
          end

          # Whether a sibling's projected (type, format) PAIR satisfies what a declared `id_type:` demands
          # — see `reject_model_id_type_conflict!` for why this is a one-way "at least as strict" test
          # rather than equality.
          def type_pair_satisfies?(declared, sibling_pair)
            return false unless declared[:type] == sibling_pair[:type]
            return true unless declared[:format]

            declared[:format] == sibling_pair[:format]
          end

          # The base JSON `:type`/`:format` pairs a built property NAMES — one entry per branch for
          # `{anyOf: [...]}`, one for a plain `{type: "string", format: "uuid"}` node, and one PER element
          # when nullability has turned `:type` itself into an Array (`{type: ["string", "null"]}` —
          # `build_property`'s own post-tolerance shape for a nullable SINGLE type, distinct from `anyOf`,
          # which is reserved for a genuinely DECLARED union); empty when the node names no type at all (an
          # `inclusion:`/`numericality:`-only bag that couldn't prove one). Every `"null"` entry is excluded
          # either way: `nil` is never a candidate satisfying a lookup token's type, and requiredness is
          # reconciled separately (`apply_model_id_requiredness!`/the nested `reject_null!` pass). Also
          # accepts a `json_type_for`-shaped (pre-nullability) argument — that never puts an Array at a
          # single member's `:type`, so `Array(m[:type])` is a one-element wrap there and reads identically.
          def json_type_pairs(type_info)
            members = type_info[:anyOf] || (type_info[:type] ? [type_info] : [])
            members.flat_map { |m| Array(m[:type]).reject { |t| t == "null" }.map { |t| { type: t, format: m[:format] } } }
          end
        end
      end
    end
  end
end
