# frozen_string_literal: true

require "axn/internal/field_config"
# A model id renders through the same serializer every other emitted literal does.
require "axn/internal/reflection/values"
# A gated id's requirement is named with the shared residue sentence.
require "axn/internal/reflection/schema/vocabulary"

module Axn
  module Internal
    module Reflection
      module Schema
        # The `<field>_id` property a `model:` field generates, and the reconciliation that decides its type.
        # A model field takes a RECORD at runtime but a lookup TOKEN on the wire, so this is the one place the
        # document describes something the declaration never names directly — inferred from the model class's
        # own primary key where it can be, reconciled against an explicitly-declared `id_type:` or an explicit
        # sibling field where those exist.
        module ModelId
          include Vocabulary

          # Which token `model_id_type_token` infers for each ActiveRecord primary-key attribute type
          # (`klass.type_for_attribute(klass.primary_key).type`). Every value here is one of
          # `Internal::FieldConfig::MODEL_ID_TYPE_TOKENS`. An AR type with no entry (`:binary`, `:decimal`, a
          # custom `ActiveRecord::Type` this table doesn't know) falls back to the untyped property rather
          # than guessing.
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

            # Nullable with gates closed: a gated model's id may arrive nil on the calls its gate closes. A required
            # id has its null branch stripped again once requiredness is known.
            if id_type
              shape = model_id_type_schema(id_type)
              if shape
                apply_single_type!(prop, shape, config, nullable: nil_admitted_with_gates_closed?(config))
              else
                prop = record_residue(prop, unstated_id_type_residue(id_type))
              end
            end

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
          # may each point at a different AR class). Inferred results are compared by simple `.uniq`, safe since
          # every one is a `Internal::FieldConfig::MODEL_ID_TYPE_TOKENS` member; a declared token may be any
          # class the author names, so those are compared by identity.
          #
          # Routes that DISAGREE — two declared `id_type:`s, or two inferred primary-key types — degrade to the
          # untyped fallback. The id's type is a description of the lookup token, not a check the runtime
          # makes: each route resolves through its own finder whatever the token's class, so no single type is
          # true of the node and leaving it out is exact rather than loose. Reflection's inference is
          # opportunistic everywhere else in this feature too (a composite PK, an unreachable connection, a
          # custom finder all fall back silently), and `Axn::Tools.validate_contracts!` runs this at APP BOOT,
          # where raising would let a schema nicety take a working application down.
          def reconciled_model_id_type_token(model_configs)
            declared = declared_model_id_types(model_configs)
            return declared.size == 1 ? declared.first : nil unless declared.empty?

            tokens = model_configs.filter_map { |c| model_id_type_token(c.validations[:model], c.validations[:model][:klass]) }.uniq
            tokens.size == 1 ? tokens.first : nil
          end

          # THE single DECLARED `id_type:` agreed across a (possibly merged) node's model routes, or nil when
          # none declares one or they disagree — never touches inference, so it is cheap and non-dispatching.
          def reconciled_declared_id_type(model_configs)
            declared = declared_model_id_types(model_configs)
            declared.first if declared.size == 1
          end

          # THE distinct DECLARED `id_type:` tokens across a (possibly merged) node's model routes.
          def declared_model_id_types(model_configs)
            model_configs.each_with_object([]) do |c, tokens|
              next unless c.validations[:model].key?(:id_type)

              token = c.validations[:model][:id_type]
              tokens << token unless tokens.any? { |seen| Axn::Internal::Identity.same?(seen, token) }
            end
          end

          # The JSON type a declared or inferred id token projects to, or nil when the token has no SCALAR
          # spelling — a lookup token is a key a client sends, so a class projecting to an object, an array,
          # null or nothing at all describes no token, and the id is left untyped with the omission named.
          SCALAR_ID_TYPES = %w[string integer number].freeze

          def model_id_type_schema(id_type)
            shape = single_type_for(id_type, for_output: false)
            shape if SCALAR_ID_TYPES.include?(shape[:type])
          end

          def unstated_id_type_residue(id_type)
            "its `id_type:` (#{PropertyNames.renderable_module_name(id_type)}) has no JSON type a lookup token " \
              "can take, so the id's type is not stated"
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
          # When the id IS required it also can't be null, so any `null` branch is stripped. The nested twin
          # (`apply_model_id_child!`) applies the same defaulted-sibling rescue.
          def apply_model_id_requiredness!(config, children, field_configs, properties, required, ann)
            # The key alone, not `model_id_property(config)` — this pass runs for EVERY model config
            # regardless of whether an explicit sibling exists, so re-deriving the whole property here
            # would re-run the same (possibly AR-dispatching, PRO-3384) inference `build_input` already
            # skipped or already discarded, for a value this method never reads.
            id_field = Axn::Internal::FieldConfig.model_id_key(config.field)
            # Excludes a model config sharing this name such a config never writes to THIS key (it emits
            # its own generated id one level deeper) and never rescues it with a default of its own, so
            # matching one here would misattribute both the `id_type:` merge below and the
            # `usable_default?` rescue just past it.
            explicit_id = field_configs.find { |c| c.field == id_field && !c.validations[:model] }
            merge_model_id_type_into_sibling!(properties[id_field], [config], explicit_id) if properties[id_field]
            properties[id_field] = with_model_lookup_residue(properties[id_field], [config]) if properties[id_field]
            # A default at ANY depth under the model applies at read time (value-level defaults,
            # PRO-2889) — no synthesis is involved — so descendant omittability is the ordinary
            # annotation-derived rule, same as every other parent.
            stranded = children_require_presence?(children, ann)
            return if (optional_for_schema?(config) && !stranded) || (explicit_id && usable_default?(explicit_id, subfield: false))

            # Only a gate imposes the requirement: the id is left out of `required`, and the conditional
            # requirement is named on it, exactly as an ordinary field's is.
            if requiredness_conditionally_relaxable?(config) && !stranded
              properties[id_field] = with_gated_requirement(properties[id_field], [config])
              return
            end

            key = id_field.to_s
            required << key unless required.include?(key)
            reject_null!(properties[id_field]) if properties[id_field]
          end

          # An explicit `<field>_id` sibling and a `model:` route both describe the same wire property, and the
          # sibling always wins it (its branch writes unconditionally; the model's only `||=`s) regardless of
          # which is declared first, at either depth. That is the runtime's answer too: the sibling's own
          # checks run on every call, while `id_type:` checks nothing — it only describes the lookup token — so
          # a sibling whose type differs from `id_type:` leaves the document exact, not loose.
          #
          # Only a sibling that emits no type of its OWN (a bare `default:`, `length:`, or other metadata-only
          # declaration) takes the declared `id_type:`, since nothing else will ever write a `:type` there.
          # Mutates `target_property` (the sibling's OWN already-built emission) in place; a no-op whenever
          # there is nothing to merge (no declared type, no sibling, or a sibling carrying type/anyOf/enum of
          # its own, which this never overwrites).
          def merge_model_id_type_into_sibling!(target_property, model_configs, explicit_id)
            return unless explicit_id
            return if target_property.key?(:type) || target_property.key?(:anyOf) || target_property.key?(:enum)

            declared = reconciled_declared_id_type(model_configs)
            return if declared.nil?

            shape = model_id_type_schema(declared)
            return target_property.merge!(record_residue(target_property, unstated_id_type_residue(declared))) unless shape

            # The SIBLING's own nullability/blank-tolerance, not the model config's — `target_property` is
            # the sibling's emission, so its own `allow_nil:`/`allow_blank:` govern whether `"null"` joins
            # the merged type and whether a blank-tolerant `:uuid`'s `format:` stands down (the same rule
            # `apply_single_type!` already applies for every other property).
            apply_single_type!(target_property, shape, explicit_id,
                               nullable: nil_admitted_with_gates_closed?(explicit_id))
            # `reject_null!` already ran on this (untyped) property earlier in the same build and, finding
            # no `:type` to narrow, fell back to its `not: { type: "null" }` marker — now redundant (a real
            # `:type` excludes null on its own, and `apply_single_type!` just decided that question fresh)
            # and, left in place, a confusing double-marker beside the type that just replaced its reason
            # for existing.
            target_property.delete(:not) if target_property[:not] == { type: "null" }
          end
        end
      end
    end
  end
end
