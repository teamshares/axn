# frozen_string_literal: true

require "date"

require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"

require "axn/core/contract/redaction"
require "axn/core/contract/shape_declaration"
require "axn/core/validation/fields"
require "axn/core/flow/handlers/invoker"
require "axn/internal/shape_graph"
require "axn/internal/cycle_guard"
require "axn/result"
require "axn/core/context/internal"

module Axn
  module Core
    module Contract
      def self.included(base)
        base.class_eval do
          # Copy-on-write stores, frozen at every assignment: declaration replaces the array (`+`,
          # never `<<` — which would now raise FrozenError rather than silently mutating the
          # superclass's contract), so the per-class resolved-subfield cache can key on array
          # identity and concurrent readers always see an immutable snapshot.
          class_attribute :internal_field_configs, :external_field_configs, default: [].freeze

          extend ClassMethods
          include InstanceMethods
        end
      end

      # Every top-level reader and boolean predicate alias is defined in this file, so reflection can
      # verify a Symbol condition still resolves to the framework-generated reader — an alias shares
      # its source_location with the aliased definition, so a user method of the same name (a
      # pre-existing predicate target that suppressed generation, or a plain reader redefined after
      # `expects`) reports a different source and is rejected (declarative-emission would otherwise
      # condition on the wire value while runtime evaluates the user method — the looser direction).
      GENERATED_READER_SOURCE_PATH = __FILE__

      # Optionality is shared by FieldConfig and ShapeConfig (axn-mcp derives `required` from BOTH —
      # field configs and nested shape members — through the same predicate).
      module FieldOptionality
        # A field is optional when it carries no `presence: true` validation, or any validator
        # tolerates blank.
        def optional?
          return true unless validations.key?(:presence) && validations[:presence] == true

          validations.values.any? { |v| v.is_a?(Hash) && v[:allow_blank] == true }
        end
      end

      # The grammar of a `user_facing:` value: `true`/`false`, a String, a Symbol (an action method
      # name), or a callable (Proc) — the full `error`/`fail!`/`fails_on` handler shape. Anything else
      # is a programmer error, rejected at declaration. Single-sourced here so the `expects`/`exposes` field-level
      # check, `FieldConfig`'s and `ShapeConfig`'s own construction, the declaration walk that reads every member's
      # value on its way into the snapshot (`_snapshot_member_attributes!`), and `ShapeValidator`'s read of a
      # member axn never snapshotted hold members and fields to one grammar — a member built via the block form,
      # via a raw `shape:` kwarg, or by the caller's own class is validated identically.
      #
      # A value outside the grammar is not inert: the executor treats a truthy one as a resolution rule, so it
      # RECLASSIFIES the violation as user-facing (the contract bug is never reported) and then renders as the
      # caller's own error message — `user_facing: 123` surfaced the literal `"123"`. That is why the check lives
      # at every point a value can enter, not only at the DSL.
      def self.validate_user_facing!(user_facing)
        return if [false, true].include?(user_facing) || user_facing.is_a?(String) || user_facing.is_a?(Symbol) ||
                  Axn::Core::Flow::Handlers::Invoker.callable?(user_facing)

        raise ArgumentError,
              "user_facing: must be true, a String, a Symbol, or a Proc (got #{user_facing.inspect})"
      end

      # The grammar of a `sensitive:` value: `true`/`false`, a Symbol (an action method name), or a Proc — plus
      # `nil`, which means `false` (so `sensitive: some_flag` reads naturally when the flag is unset). Anything
      # else is rejected at declaration, because the runtime failure mode is a LEAK rather than an error: only
      # those values are resolution rules, so `sensitive: "yes"` or `sensitive: 1` left the field out of the
      # name-based redaction set entirely and logged the secret in the clear, with no signal to the author.
      #
      # Closing the value space is also what makes one predicate enough to decide whether redaction needs an
      # action instance: over this grammar, "carries no Proc or Symbol" and "resolves to the same answer with
      # and without an instance" are the same question (see `_has_dynamic_sensitive_fields?`).
      #
      # `case`/`when` consults the real class through `Module#===` (a C-level check) and compares the literals
      # by identity, so nothing a caller-supplied value defines gets to answer whether it is a valid rule —
      # and the offender is named by CLASS rather than by `inspect`, which would be running its code while its
      # own error is being built. A Proc is the callable form the resolver actually implements
      # (`instance_exec(&sensitive)`); a non-Proc callable would be truthiness-tested, i.e. always sensitive.
      #
      # Enforced in `FieldConfig`'s constructor, which every field, subfield and ambient subfield is built by, and
      # in the DECLARATION WALK for every shape member, whatever its class — the walk reads the value once, on its
      # way into the snapshot, so the check and the stored value are the same read
      # (`_snapshot_member_attributes!`). `ShapeConfig`'s constructor checks it too, for the block form.
      def self.validate_sensitive!(sensitive)
        case sensitive
        when true, false, nil, ::Symbol, ::Proc then return
        end

        raise ArgumentError,
              "sensitive: must be true, false, a Symbol naming an action method, or a Proc (got a value of " \
              "class #{Axn::Reflection::PropertyNames.renderable_class_name(sensitive)}) — any other value is not a redaction rule, and " \
              "a truthy one would silently leave the value logged in the clear rather than raise. Use " \
              "`sensitive: true` to always redact, or a Symbol/Proc predicate to decide per call."
      end

      # A shape member's name has to serve as TWO things: the JSON property it renders as (via `to_s`, which
      # the declaration guard canonicalizes) and the schema property key (via `to_sym`, which
      # Reflection::Schema#member_properties emits). A String and a Symbol are the only types for which those
      # conversions are each other's inverse, so they are the only names that mean one property. Any other
      # object defines the two independently, and one whose `to_s` and `to_sym` disagree makes the guard and
      # the schema compare different property names for the same member: the guard sees no collision while
      # the schema keys one property for two members and silently discards the first.
      #
      # Rejected rather than reconciled, because there is nothing to reconcile — an object whose two
      # renderings disagree has no single property name to be. Named by class rather than by `inspect`, which
      # is the offender's own code running while its error is built.
      #
      # Enforced in the DECLARATION WALK, unconditionally, for every member the class will store — the one point a
      # member of any class passes through, and the point before the name is converted. Every STORED member is a
      # `ShapeConfig`, whose constructor holds the same rule and normalizes a String to its Symbol, so a stored
      # name is always the Symbol the schema keys by; that conversion is what keeps parallel `to_s`/`to_sym`
      # readings of an unnormalized name from being two questions that can disagree.
      def self.validate_shape_member_name!(name)
        case name
        when ::String, ::Symbol then return
        end

        raise ArgumentError,
              "a shape member name must be a String or a Symbol (got a name of class " \
              "#{Axn::Reflection::PropertyNames.renderable_class_name(name)}) — a member name is both the JSON " \
              "property it renders as " \
              "and the schema property key it is emitted under, and any other object converts to those two " \
              "independently. Declare the member under a String or Symbol name."
      end

      # The one config type for every declared inbound/outbound field, top-level or subfield — a
      # top-level field is just the depth-0 case (`on: nil`). `reader_as` is the name of the
      # generated accessor method; it defaults to `field` (the wire key), but `expects ..., as:`/
      # `prefix:` decouple them so the caller-facing contract stays `field` while the in-action
      # reader gets its own name. `on:` names the parent reader a subfield is extracted from;
      # `user_facing:` reclassifies a violation of the field into a user-facing failure.
      # `method_call:` opts a subfield into the sharp path — resolving a segment by INVOKING it as a
      # method (Array methods, PORO readers, Data behavioral methods) rather than reading declared
      # data; it is threaded to the resolver as `permit_method_call:` (PRO-2898).
      FieldConfig = Data.define(:field, :validations, :default, :preprocess, :sensitive, :metadata, :reader_as, :user_facing, :on, :method_call) do
        def initialize(field:, validations:, reader_as:, default: nil, preprocess: nil, sensitive: false, metadata: {}, user_facing: false, on: nil,
                       method_call: false)
          # THE choke point for a declared field's `sensitive:` and `user_facing:`, whichever DSL built it
          # (`expects`, `exposes`, an `on:` subfield, an ambient subfield, `Axn::Factory`): every stored
          # FieldConfig is built here, from kwargs, and nothing hands axn one it made itself. That is what makes
          # it the right place for BOTH — a config ASSIGNED onto a class (`internal_field_configs=`) never passes
          # the DSL, so a check that only lives there leaves the value unheld while the executor still resolves
          # it. See Contract.validate_sensitive! / .validate_user_facing!.
          Contract.validate_sensitive!(sensitive)
          Contract.validate_user_facing!(user_facing)
          super
        end

        def description = metadata[:description]

        def subfield? = !on.nil?

        include FieldOptionality

        # Whether the field is declared `type: :boolean` (drives the generated `?` predicate reader).
        def boolean?
          Array(validations.dig(:type, :klass)) == [:boolean]
        end

        # Whether the declared default is applied at runtime: any non-nil default counts (`default:
        # false` on a boolean is meaningful), matching top-level defaults' key-absence semantics.
        # Schema reflection keys off the same rule, so a declared falsey default is emitted and
        # relaxes requiredness exactly when the runtime would apply it.
        def applied_default?
          !default.nil?
        end
      end

      # One member declared inside a structured field's block (`field :name, ...`).
      # Nested members live in validations[:shape][:members], so the tree is uniform
      # at every depth and walked by both ShapeValidator (runtime) and axn-mcp (schema).
      # `method_call:` opts the member into the sharp path — reading it by INVOKING it as a method
      # on the element being validated (a non-`Data` PORO reader or an Array method) rather than
      # reading declared data (Hash keys, Struct/OpenStruct/Data members). It is threaded to the
      # member's validation read as `permit_method_call:`, the shape-block analog of a subfield's
      # `method_call:` (PRO-2907).
      #
      # `field` is always a Symbol on a constructed ShapeConfig: `field "bar"` and `field :bar` are one
      # member name, and the schema keys a member's property by `field.to_sym`, so storing the Symbol makes
      # the stored value the one every consumer reads. It is what keeps the declaration guard (which
      # canonicalizes the name's rendering) and the reflected schema in step by construction — parallel
      # conversions of an unnormalized name are two questions that can disagree. Same rule as a top-level
      # field, whose name `expects`/`exposes` symbolize before anything else looks at it.
      ShapeConfig = Data.define(:field, :validations, :metadata, :method_call, :sensitive, :user_facing) do
        def initialize(field:, validations:, metadata: {}, method_call: false, sensitive: false, user_facing: false)
          # Validate at construction so a member's grammar holds however the ShapeConfig is built — the block
          # form (via `_build_shape_member`), a raw `shape:` kwarg supplying pre-built ShapeConfigs, and the
          # declaration walk's own snapshot of a member of any other class. The walk still reads and checks each
          # value itself, ahead of this: that keeps the error in ITS order (a member carrying both a bad
          # `sensitive:` and an untraversable nested shape is reported as the value defect), and the read it makes
          # is the one it stores. Here the check is the first thing the block form meets.
          Contract.validate_shape_member_name!(field)
          Contract.validate_user_facing!(user_facing)
          Contract.validate_sensitive!(sensitive)
          # `to_sym` is dispatched, so a String SUBCLASS could return something other than its own spelling —
          # but converting once is exactly what makes that harmless: every consumer then reads the one
          # stored Symbol, so a surprising conversion picks a different property name rather than splitting
          # the guard from the schema. That is why this must be the ONLY conversion of the name on every route
          # here: the declaration walk canonicalizes a duck-typed member's name itself, beside the duplicate
          # check that judges it, and hands the Symbol down — so this is a no-op for a member the walk built,
          # and the whole normalization for one built directly (the `field "bar"` block form, a pre-built
          # ShapeConfig in a raw `shape:`, a config assigned via `internal_field_configs=`), which is why it
          # stays.
          super(field: field.to_sym, validations:, metadata:, method_call:, sensitive:, user_facing:)
        end

        include FieldOptionality

        def description = metadata[:description]
      end

      # Collector for the `field ...` calls inside a structured field's block.
      class ShapeBuilder
        attr_reader :declarations

        def initialize
          @declarations = []
        end

        def field(name, **opts, &block)
          @declarations << [name, opts, block]
        end
      end

      module ClassMethods
        # The long-tail declaration/redaction machinery, extracted so this file stays the
        # `expects`/`exposes` DSL a contributor reads. Included into ClassMethods rather than extended
        # separately onto the action class, so ClassMethods remains the single thing `Contract.included`
        # extends and every method is reached with the same implicit receiver, at the same visibility,
        # and in the same lookup position as when it lived in this file.
        include ShapeDeclaration
        include Redaction

        # rubocop:disable Metrics/ParameterLists
        def expects(
          *fields,
          on: nil,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          as: nil,
          prefix: nil,
          user_facing: false,
          method_call: false,
          **,
          &block
        )
          # Canonicalize the wire key to a symbol up front so everything downstream — config.field,
          # reader names, duplicate detection, the inbound read path — is symbol-keyed by construction.
          # `expects "note"` and `expects :note` are the same field; a dotted subfield key (`"a.b"`)
          # symbolizes harmlessly (it's only ever compared/split via `.to_s`). See PRO-2790.
          fields = fields.map(&:to_sym)

          # A subfield's ROUTE is canonicalized on the same terms, and here — before the first guard reads it.
          # A route is judged as written (its root must name a declared reader; `_duplicate_fields` keys a config
          # by it) and then split again by every consumer: `SubfieldTree`, `resolve_parent`'s recipe, the ambient
          # checks, the executor's parent memo. So a caller value whose rendering answered differently on
          # successive reads had one layer judging one route while the tree built another — two subfields
          # silently landing on ONE node, merged as if they were two routes to one wire slot, where the same
          # declaration written honestly is a duplicate. A Symbol's `to_s` is Ruby's own, so afterwards every
          # read is the same answer, and no message renders a route by running the route's own code. Dotted
          # paths symbolize harmlessly, exactly as a dotted `on:` always did: they are only ever split via `to_s`.
          #
          # Absent stays absent — `nil`/`""` mean "no route" — and that verdict is reached WITHOUT running the
          # route's own code, because `present?`/`blank?` are ActiveSupport methods on Object that a String
          # subclass overrides: one answering "blank" here and "present" to a later reader skipped this line
          # entirely and was stored raw, reinstating the split this canonicalization exists to close.
          on = on.to_sym unless Internal::NativeMethods.absent_name?(on)

          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(field.to_s)
          end

          # A field's wire key always names a single key; the nested-path capability lives entirely in a
          # dotted `on:` (`expects :b, on: "a"`). A dotted field NAME is therefore never valid — reject it
          # unconditionally, pointed at the dotted-`on:` spelling (PRO-2926). A dotted `on:` VALUE is fine.
          _reject_dotted_field_name!(fields, on:)

          _validate_user_facing!(user_facing)

          # `method_call:` governs how a SUBFIELD's segment is resolved from its parent (invoke vs.
          # read). A top-level field reads its literal wire key from the context Hash — it never
          # method-dispatches — so `method_call: true` without `on:` could never take effect; reject
          # it rather than accept a silently-inert option (matching the ambient default:/coerce:
          # rejections). `method_call: false` is the default, so it's a harmless no-op anywhere.
          if method_call && on.blank?
            raise ArgumentError,
                  "`method_call: true` is only meaningful on a subfield (declared with `on:`) — a top-level field " \
                  "reads its wire key and never invokes a method. Add `on:` to name the parent, or drop `method_call:`."
          end

          reader_names = _resolve_reader_names(fields, as:, prefix:)
          _validate_reader_names!(reader_names)

          validations, metadata = _partition_field_options(fields, **)
          validations[:shape] = _build_shape(fields, validations:, &block) if block
          _snapshot_declared_shape!(validations, fields)

          if on.present?
            return _expects_subfields(*fields, on:, allow_blank:, allow_nil:, optional:, default:, preprocess:, sensitive:, metadata:,
                                               reader_names:, user_facing:, method_call:, **validations)
          end

          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess:, sensitive:, metadata:,
                                        reader_names:, user_facing:, **validations).tap do |configs|
            _reject_duplicate_fields!(internal_field_configs, configs)
            # Declaring a top-level field can RE-ANCHOR existing subfields (a new root takes precedence over
            # a same-named subfield reader), so the resolved check runs here too rather than only where
            # subfields are declared.

            # Every declaration check has passed; NOW mutate the class (matching _expects_subfields'
            # validate-before-commit ordering), so a rescued declaration error never leaves the class
            # carrying an orphaned config or generated reader. Copy-on-write + freeze: `<<` would
            # mutate the superclass's contract, and identity-keyed caching relies on replacement.
            self.internal_field_configs = (internal_field_configs + configs).freeze
            _define_field_readers!(configs)
          end
        end
        # rubocop:enable Metrics/ParameterLists

        def exposes(
          *fields,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          sensitive: false,
          **,
          &block
        )
          # Symbolize the wire key (see `expects`) so exposes shares the same symbol-keyed contract.
          fields = fields.map(&:to_sym)

          # Stays pre-build, unlike every other declared name: an exposed field name is a property in the
          # SERIALIZED BODY (`Values.serialize_exposed` iterates these configs and raises on an unrenderable
          # one) as well as in `output_schema`, so it must be rejected whatever the schema emits.
          _reject_unrenderable_field_names!(fields)

          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPOSURES.include?(field.to_s)
          end

          # exposes has no `on:`/subfields, so a dotted name has no valid meaning at all (see expects).
          _reject_dotted_field_name!(fields, on: nil, kind: "exposes")

          validations, metadata = _partition_field_options(fields, **)

          validations[:shape] = _build_shape(fields, validations:, outbound: true, &block) if block

          # Ahead of the `user_facing:` walk below so a member carrying both an unusable name and a rejected
          # option is reported as the naming defect it is. That ordering only governs these two walks over
          # resolved members: in the block form the option error surfaces first, raised inside
          # `_build_shape_member` while `_build_shape` above is still assembling the members.
          _snapshot_declared_shape!(validations, fields)

          # The block form rejects a `user_facing:` member inside `_build_shape_member` (above), but a
          # raw `shape:` kwarg supplies pre-built member objects that never route through it — so walk
          # the resolved members here to close that path too (see _reject_outbound_shape_user_facing!).
          _reject_outbound_shape_user_facing!(validations[:shape])

          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess: nil, sensitive:, metadata:, **validations).tap do |configs|
            if configs.any? { |c| c.validations.dig(:type, :coerce) }
              raise ArgumentError, "coerce: is not supported on exposes (outbound fields are serialized, not coerced)."
            end

            _reject_duplicate_fields!(external_field_configs, configs)
            # The outbound claim space. `exposes` has no `on:`, so there are no routes to resolve — but a shape
            # member (and a `Data` type's own members) still name properties under an exposure, and those pairs
            # collapse in `output_schema` exactly as their inbound counterparts do.

            # Copy-on-write + freeze (see internal_field_configs above).
            self.external_field_configs = (external_field_configs + configs).freeze
          end
        end

        def _declared_fields(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless direction.nil? || %i[inbound outbound].include?(direction)

          configs = case direction
                    when :inbound then internal_field_configs
                    when :outbound then external_field_configs
                    else (internal_field_configs + external_field_configs)
                    end

          configs.map(&:field)
        end

        # Everything below is reached only with an implicit receiver, from here and from the other declaration
        # modules extended onto the same class. It is private because an `_`-prefixed name in a module extended
        # onto every action class otherwise lands there as a PUBLIC singleton method, so the convention and the
        # surface disagree. `_declared_fields` stays public above: the context facade, the redaction slice and
        # `Mountable`'s step passthrough call it on the action class from other files.
        private

        # Reject `user_facing:` on any member of an `exposes` shape, at any depth. The block form
        # catches it in `_build_shape_member` on key presence; a raw `shape:` kwarg supplies pre-built
        # member objects that bypass that path, so walk the resolved members (and nested shapes) here.
        # Truthy-based (not key-presence): a pre-built member exposes only its resolved `#user_facing`
        # value, whose `false` default is indistinguishable from unset — only a truthy value is a real
        # opt-in (the block form, seeing the literal opts, still rejects an explicit `user_facing: false`).
        # Walks the SNAPSHOT, so what it reads is what the class will hold and nothing here re-runs a
        # caller's reader. A cyclic graph is impossible for the same reason — every declaration path runs
        # `_validate_and_snapshot_shape!`, which rejects one, before reaching this walk.
        # The name is read BEFORE the violation is detected, so the message is built from a name already in
        # hand rather than by dispatching the reader again once a failure is being reported.
        def _reject_outbound_shape_user_facing!(shape)
          Internal::ShapeGraph.members(shape).each do |member|
            name = Internal::ShapeGraph.fetch(member, :field)
            if Internal::ShapeGraph.read(member, :user_facing)
              raise ArgumentError,
                    "shape member #{_describe_shape_member(member, name)} does not support user_facing: on exposes — an " \
                    "outbound failure is a dev-facing bug (bad output), never a user-facing one. Drop user_facing:."
            end
            _reject_outbound_shape_user_facing!(_member_shape(member))
          end
        end

        # A true duplicate is the SAME wire key declared under the SAME parent route — keyed on the
        # `[on, field]` pair, against `existing` configs AND within `new_configs` itself (`expects :foo,
        # "foo"` is a single batch, so its collision is intra-batch).
        #
        # Identity is the JSON PROPERTY a name renders as, not the Symbol itself: keys are symbol-canonical
        # at declaration, so `:note` and `"note"` are already one field, and canonicalizing to UTF-8 closes
        # the remaining gap — two Symbols whose bytes differ but whose property does not.
        #
        # For a top-level field `on:` is nil, so this reduces to property identity. Two SUBFIELDS that
        # share a leaf wire key but differ by `on:` are NOT duplicates HERE: they are either two routes to
        # one wire path (a merged node) or two distinct nested fields sharing a leaf key — both legitimate,
        # and both gated separately on reader-name uniqueness (`_validate_subfield_reader_names!`, resolved
        # with `as:`). Declaring a genuine duplicate is rejected because two validations would run on one
        # field, the generated reader would be clobbered, and per-field config would collapse
        # ambiguously.
        #
        # This is the SYNTACTIC half of field identity: "the same name declared twice under the same route
        # as written". It cannot see two DIFFERENT routes that resolve to one parent, nor any of the other
        # mechanisms that name a property at a node — that is what the one claim space
        # (`_reject_colliding_property_claims!`) answers. The two are complementary, not redundant: `on:`
        # spelling is what distinguishes declaring one thing twice (rejected here) from reaching one wire slot
        # by two routes (legitimate, and a MERGE under the claim rule), so this check catches exactly the case
        # the claim space treats as legal.
        #
        # Returns `[claimed_field, offending_field]` pairs; equal entries are an identical-name duplicate.
        def _duplicate_fields(existing, new_configs)
          # `on:` is rendered with `to_s` so `:payload` and `"payload"` (and any symbol/string spelling of the
          # same dotted path) name the same route — matching how the SubfieldTree splits `on:` — rather than
          # slipping two configs onto one wire slot on a spelling difference. The DSL already canonicalizes a
          # declared route to a Symbol (see `expects`), so for a declared config this is Ruby's own `to_s` and
          # cannot answer differently here than it does in the tree; the rendering stays because a config
          # ASSIGNED onto a class carries whatever route its author built, exactly as it carries a raw `field`.
          # The route is deliberately not resolved further; see the note above on which half of identity this is.
          #
          # A name with no UTF-8 rendering canonicalizes to nil and names no property, so it is SKIPPED rather
          # than compared: two of them would otherwise key alike and be reported as duplicates of each other.
          # Whether such a name is a defect at all depends on whether the schema emits it, which only the
          # emitted-name walk knows (see `_raise_unrenderable_emitted_name!`).
          #
          # Keyed in ONE pass over `existing`, so each config's route and canonical name are derived once. The
          # two-pass form (reject, then to_h) asked the same config twice, and a `to_s` answering differently the
          # second time reported a different defect than the one it judged — the non-idempotent-dispatch hazard
          # that CANONICALIZING a value always carries. `Hash#[]=` keeps the last entry for a repeated key,
          # exactly as `to_h` did.
          key_for = ->(c) { [c.on.to_s, Axn::Reflection::Values.canonical_wire_key(c.field)] }

          claimed = existing.each_with_object({}) do |c, h|
            key = key_for.call(c)
            h[key] = c.field unless key.last.nil?
          end
          new_configs.each_with_object([]) do |config, collisions|
            key = key_for.call(config)
            next if key.last.nil?
            next collisions << [claimed[key], config.field] if claimed.key?(key)

            claimed[key] = config.field
          end
        end

        # How a shape member's name is written into any message naming that member: the JSON property it
        # renders as, falling back to the escaped `inspect` when its bytes have no UTF-8 rendering. Every
        # such message is a UTF-8 String, and joining raw non-UTF-8 bytes to one raises
        # Encoding::CompatibilityError from the reporting itself — so the caller sees an encoding failure
        # instead of the declaration error that was being reported. The canonical property is
        # byte-identical to the raw spelling for every renderable name, so ordinary messages are unchanged;
        # `inspect` is reserved for the name that has no property to print.
        def _shape_member_label(name) = Axn::Reflection::PropertyNames.renderable_label(name)

        # The two property-name rules are judged on the projection they would appear in, so they run when one is
        # first demanded rather than here (see Axn::Reflection::PropertyNames). What the contract still asks of
        # that layer eagerly is name RENDERING — `exposes` field names, whose bytes reach the serialized body
        # regardless of any schema, and the escaping every declaration message uses.
        def _reject_unrenderable_field_names!(names, kind: "a field name")
          Axn::Reflection::PropertyNames.reject_unrenderable_field_names!(names, kind:)
        end

        # How a declared name is written into a message, shared with the rules above so every message that
        # names a field or member escapes it the same way.
        def _inspect_field_name(name) = Axn::Reflection::PropertyNames.inspect_field_name(name)

        # The three declaration paths (top-level expects, exposes, subfields) report through here rather
        # than each partitioning the result of `_duplicate_fields` themselves. An identical-name duplicate
        # and two names collapsing onto one property are the same defect under one identity rule, but they
        # need different messages, and the identical case keeps the wording it has always had.
        #
        # An identical duplicate is reported first when a batch contains both, so the error is deterministic
        # and names the simpler defect — the one whose fix is unambiguous.
        #
        # The identical branch names each offender by its canonical property rather than by the Symbol: every
        # name reaching here is renderable by construction, and joining a non-UTF-8 name to a UTF-8 one would
        # raise Encoding::CompatibilityError from the reporting itself — surfacing the wrong exception class
        # for the defect. Canonicalizing keeps the message valid UTF-8 and leaves an ASCII name byte-identical.
        #
        # WHICH of the two wordings a collision gets is decided through `PropertyNames.same_declared_name?`, not
        # by `==`: this runs with the failure already certain, and `existing` may hold a config ASSIGNED onto the
        # class, whose `field` is whatever its author built. Asking such a name whether it equals the declared one
        # let it raise INSTEAD of the DuplicateFieldError — replacing the verdict, and outside StandardError
        # escaping class definition entirely.
        def _reject_duplicate_fields!(existing, new_configs)
          collisions = _duplicate_fields(existing, new_configs)
          return if collisions.empty?

          identical, collapsed = collisions.partition { |claimed, offending| Axn::Reflection::PropertyNames.same_declared_name?(claimed, offending) }
          if identical.any?
            names = identical.map { |_claimed, offending| Axn::Reflection::Values.canonical_wire_key(offending) }
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{names.join(', ')}"
          end

          claimed, offending = collapsed.first
          raise Axn::DuplicateFieldError,
                "Duplicate field(s) declared: #{_inspect_field_name(claimed)} and #{_inspect_field_name(offending)} " \
                "both render as the JSON property #{Axn::Reflection::Values.canonical_wire_key(offending).inspect} — a " \
                "field name becomes a property name in the reflected schema and in serialized output, so the two would " \
                "collapse onto one. Declare them under names that stay distinct once converted to UTF-8."
        end

        # Map each declared field to the name of its generated reader. Without `as:`/`prefix:` the
        # reader is named for the wire key (identity). `as:` renames a single field's reader;
        # `prefix:` is sugar that prepends to every field's reader (literal concatenation, so the
        # caller supplies the separator). The wire key (`field`) stays canonical regardless.
        #
        # Wire keys are never dotted (dotted field NAMES are rejected upstream by
        # _reject_dotted_field_name!), so a reader name is only ever renamed, never path-derived:
        # `as:` renames a single field, `prefix:` prepends to each. The one dotted constraint left is on
        # the `as:` VALUE itself — a reader name still can't be dotted.
        def _resolve_reader_names(fields, as:, prefix:)
          return fields.to_h { |f| [f, f] } if as.nil? && prefix.nil?

          raise ArgumentError, "`as:` and `prefix:` cannot be combined" if as && prefix

          if as
            raise ArgumentError, "`as:` can only be provided when declaring a single field (use prefix: for several)" if fields.size > 1

            # Canonicalized before the dotted check rather than after it, so the name the check JUDGES is the
            # name the reader is defined under — `to_s` and `to_sym` are two dispatches on the same caller
            # object, and a String subclass answering them differently had the guard clearing one spelling
            # while another was generated. A Symbol's `to_s`/`inspect` are Ruby's own, so both the check and
            # the message it may raise are now decided by axn.
            reader = as.to_sym
            raise ArgumentError, "`as:` reader name may not be dotted (#{reader.inspect} would not name a method)" if reader.to_s.include?(".")

            { fields.first => reader }
          else
            fields.to_h { |f| [f, :"#{prefix}#{f}"] }
          end
        end

        # A field's wire key names one key; the nested-path capability lives entirely in a dotted `on:`
        # (`expects :b, on: "a"`). A dotted field NAME is therefore never a valid declaration — reject it
        # everywhere (top-level, subfield, or exposes) and point at the dotted-`on:` spelling. (A dotted
        # `on:` VALUE is orthogonal and fine; only the field NAME is constrained.)
        def _reject_dotted_field_name!(fields, on:, kind: "a top-level field")
          dotted = fields.select { |f| f.to_s.include?(".") }
          return if dotted.empty?

          if kind == "exposes"
            raise ArgumentError,
                  "a dotted field name (#{dotted.map(&:to_s).inspect}) is not valid for exposes " \
                  "(outbound fields have no nested-path reader)"
          end

          *parents, leaf = dotted.first.to_s.split(".")
          suggested_on = [on, *parents].map(&:to_s).reject(&:empty?).join(".")
          raise ArgumentError,
                "a dotted field name (#{dotted.map(&:to_s).inspect}) is not supported — name the leaf and move the " \
                "path into `on:` (e.g. `expects :#{leaf}, on: #{suggested_on.inspect}`). A dotted `on:` pulls a value " \
                "out of a nested structure; a field's own name is always a single wire key."
        end

        # Renamed readers must clear the same reserved-name bar as wire keys (identity readers are
        # already reserved-checked against their wire key in `expects`), and no two declarations may
        # resolve to the same reader name.
        def _validate_reader_names!(reader_names)
          reader_names.reject { |field, reader| field == reader }.each_value do |reader|
            raise ContractViolation::ReservedAttributeError, reader if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(reader.to_s)
          end

          # A collision is a *new* reader name already claimed by an existing config under a different
          # wire key. A same-wire-key clash is a genuine duplicate field, reported downstream with a
          # clearer DuplicateFieldError, so it's excluded here. Checking every new reader (not just
          # aliases) catches alias-vs-plain clashes in either declaration order — e.g.
          # `expects :bar, as: :foo` then `expects :foo`, which would otherwise silently clobber the
          # `bar` reader. Intra-call duplicates (distinct fields → same reader) are caught too.
          # Only configs that actually generated a reader can be collided with. A dotted-key subfield
          # defines no method, so its name stays free; consult the method table rather than every
          # config so those readerless declarations don't manufacture phantom collisions.
          existing = (internal_field_configs + subfield_configs)
                     .select { |c| method_defined?(c.reader_as) }
                     .to_h { |c| [c.reader_as, c.field] }
          collisions = reader_names.filter_map { |field, reader| reader if existing.key?(reader) && existing[reader] != field }
          collisions |= reader_names.values.tally.select { |_, count| count > 1 }.keys
          raise ArgumentError, "Reader name collision: #{collisions.uniq.join(', ')}" if collisions.any?
        end

        # `user_facing:` reclassifies a violation of this field from a dev-facing exception into a
        # user-facing failure (see Executor). Its value doubles as the surfaced message: `true` uses
        # the field's own validation message; a String overrides it; a Symbol names an action method
        # and a Proc computes it from the InboundValidationError — the full `error`/`fail!`/`fails_on`
        # handler shape. Single-sourced through the module-level grammar check (see above).
        #
        # `FieldConfig`'s constructor holds the same rule and is the CHOKE POINT (it catches a config assigned
        # onto a class, which never passes this DSL). This call stays because it runs earlier in the declaration:
        # a declaration carrying both a bogus `user_facing:` and, say, a reader-name collision is reported as the
        # value defect, exactly as the shape walk checks a member's value ahead of `ShapeConfig`'s constructor.
        def _validate_user_facing!(user_facing)
          Contract.validate_user_facing!(user_facing)
        end

        RESERVED_FIELD_NAMES_FOR_EXPECTATIONS = %w[
          fail! ok?
          inspect default_error
          each_pair
          default_success
          action_name
          inputs
          ambient_context
        ].freeze

        RESERVED_FIELD_NAMES_FOR_EXPOSURES = %w[
          fail! ok?
          inspect each_pair default_error
          ok error success message
          result
          outcome
          exception
          elapsed_time
          finalized?
          __action__
          standalone
          inputs
          ambient_context
        ].freeze

        KNOWN_VALIDATION_KEYS = Set.new(%i[
                                          absence acceptance comparison confirmation exclusion format
                                          inclusion length numericality presence uniqueness
                                          type model validate of shape coerce
                                          if unless on message strict
                                        ]).freeze

        # Types for which a shape block is meaningless — the block describes the members of a
        # structured value (Array elements, Hash keys, or a class's readers), not a scalar.
        SHAPE_INCOMPATIBLE_TYPES = [String, Integer, Float, Numeric, TrueClass, FalseClass, Symbol, NilClass,
                                    Date, Time, DateTime,
                                    :boolean, :uuid, :params].freeze

        # Field-level options a shape member supports (beyond validations + metadata). `sensitive:` is
        # one of them: a member's name is added to the ParameterFilter set by the sensitive-name
        # collectors, which descend into shape members via `_sensitive_candidate_configs`, and
        # ParameterFilter redacts by key name at any depth (array elements included) — so a per-element
        # or nested Hash member redacts precisely. When the value in a member-bearing position is NOT a
        # Hash (an object-backed shape, or malformed input), ParameterFilter can't reach into it, so
        # `_mask_unfilterable_shape_value` redacts that value wholesale before logging/inspect — see
        # there for the safe-over-precise trade-off.
        #
        # Shape members are reader-less, validation/schema-only declarations (a `ShapeConfig`, no reader,
        # no participation in value resolution), so `default:`/`preprocess:` — which produce/transform a
        # value that needs a resolution target to land on (resolved on the read path post-PRO-2903) —
        # have nowhere to apply and are rejected rather than silently dropped when converting to a
        # ShapeConfig. `model:` is rejected separately (see `_build_shape_member`) for the related but
        # distinct reason that it resolves an id and exposes an `_id` companion reader a member lacks.
        SHAPE_MEMBER_FIELD_OPTIONS = %i[allow_blank allow_nil optional method_call sensitive user_facing].freeze
        SHAPE_MEMBER_UNSUPPORTED_OPTIONS = %i[default preprocess].freeze

        # Reader-renaming options (`as:`/`prefix:`) rename the reader a field generates. A shape member is
        # reader-less, so they have nothing to rename — but they are legitimate keys elsewhere, so a bare
        # validations parse would reject them as "Unknown key(s)" (wrongly implying they are never valid).
        # `_build_shape_member` rejects them explicitly with the reader-less reason instead.
        SHAPE_MEMBER_READER_OPTIONS = %i[as prefix].freeze

        # Parse a structured field's block into a `{ members: [...], container: <klass> }` validation
        # value. `container` lets ShapeValidator defer a type mismatch to TypeValidator (rather than
        # trying to extract members from the wrong kind of value).
        def _build_shape(fields, validations: nil, outbound: false, &)
          raise ArgumentError, "a shape block can only be declared on a single field" if fields.size > 1

          container = _shape_compatible_type!(validations)

          builder = ShapeBuilder.new
          builder.instance_exec(&)

          members = builder.declarations.map { |name, opts, subblock| _build_shape_member(name, opts, subblock, outbound:) }

          { members:, container: }
        end

        # A member reuses the same option handling as a top-level field (optional/allow_blank/
        # default/etc. + validations + metadata), but yields a ShapeConfig and never a reader.
        def _build_shape_member(name, opts, subblock, outbound: false)
          unsupported = opts.keys & SHAPE_MEMBER_UNSUPPORTED_OPTIONS
          if unsupported.any?
            raise ArgumentError,
                  "shape member `#{_shape_member_label(name)}` does not support #{unsupported.map { |k| "#{k}:" }.join('/')} " \
                  "(shape blocks declare validation/schema only)"
          end

          reader_opts = opts.keys & SHAPE_MEMBER_READER_OPTIONS
          if reader_opts.any?
            raise ArgumentError,
                  "shape member `#{_shape_member_label(name)}` does not support #{reader_opts.map { |k| "#{k}:" }.join('/')} " \
                  "(they rename a field's generated reader, but a shape member is reader-less; " \
                  "use them on a top-level `expects` field or an `on:` subfield)."
          end

          # `user_facing:` reclassifies an INBOUND violation into the user-facing failure bucket. An
          # outbound (`exposes`) failure means the action produced bad output — always a dev bug, never
          # the caller's fault — and the outbound settlement path never consults `user_facing:`, so on an
          # exposes shape member it would be silently inert. Reject it loudly on key presence (even an
          # explicit `user_facing: false`), matching top-level `exposes`, which rejects `user_facing:`
          # as an unknown key regardless of value.
          if outbound && opts.key?(:user_facing)
            raise ArgumentError,
                  "shape member `#{_shape_member_label(name)}` does not support user_facing: on exposes — an outbound failure is a " \
                  "dev-facing bug (bad output), never a user-facing one. Drop user_facing:."
          end

          _raise_member_model_unsupported!(name) if opts.key?(:model)

          field_opts = opts.slice(*SHAPE_MEMBER_FIELD_OPTIONS)
          field_validations, metadata = _partition_field_options([name], **opts.except(*SHAPE_MEMBER_FIELD_OPTIONS))

          field_validations[:shape] = _build_shape([name], validations: field_validations, outbound:, &subblock) if subblock

          config = _parse_field_configs(name, metadata:, **field_opts, **field_validations).first
          if config.validations.dig(:type, :coerce)
            raise ArgumentError,
                  "coerce: is not supported on a shape member (it has no reader for a coerced value to resolve " \
                  "onto; use it on a top-level `expects` field or an `on:` subfield)."
          end

          # `user_facing:` (full parity with a field's) is validated in ShapeConfig's constructor below,
          # so the block and raw `shape:` paths hold members to one grammar.
          ShapeConfig.new(field: name, validations: config.validations, metadata: config.metadata,
                          method_call: config.method_call, sensitive: config.sensitive, user_facing: config.user_facing)
        end

        # A shape block requires a single, structured type:. Mirrors the of: guard's strictness.
        # Returns the structured klass (Array, Hash, or a member-bearing class).
        def _shape_compatible_type!(validations)
          type = validations&.dig(:type)
          # `case`/`when` (via ShapeGraph) rather than `is_a?`: `type:` is a caller-supplied bag, and a Hash
          # subclass denying its own class would have the whole bag read as the declared class.
          type_bag = Internal::ShapeGraph.hash_or_nil(type)
          klass = nil.equal?(type_bag) ? type : type_bag[:klass]
          klasses = Array(klass)
          return klasses.first if klasses.size == 1 && SHAPE_INCOMPATIBLE_TYPES.exclude?(klasses.first)

          raise ArgumentError,
                "a shape block requires a single structured type: (Array, Hash, or a class) — got #{klasses.inspect}"
        end

        # A raw `shape:` kwarg (as opposed to the `do…end` block, whose `_build_shape` derives
        # `:container` from `type:`) may omit `:container`. Derive it from the declared type the same
        # way the block form does, so a raw shape validates identically instead of reaching
        # ShapeValidator with a nil container (`value.is_a?(nil)` → TypeError at call time). A
        # block-built shape already carries `:container`, so this fires only for the raw form; a raw
        # shape with an incompatible/missing `type:` raises the same declaration error the block form
        # does (via `_shape_compatible_type!`). Mutates `validations`.
        #
        # Nothing the shape object can define decides whether derivation happens: the type test goes
        # through `ShapeGraph.hash_or_nil`, the "already has one?" test reads the key rather than asking
        # `key?`, and `nil` is the receiver of the emptiness check rather than the caller's value (`nil?`
        # is overridable and this is a type test). An overridden `is_a?`, `key?` or `nil?` would otherwise
        # skip derivation, leaving a nil container that reaches ShapeValidator and raises a bare
        # `TypeError: class or module required` on EVERY call instead of the declaration error this exists
        # to produce. Reading the key also derives for an explicit `container: nil`, the same unusable
        # state spelled out.
        #
        # `:members` is taken from `ShapeGraph.members` — the same read every guard makes — and NOT from
        # the shape's own entries. This runs after those guards, so whatever it stores is what reflection
        # then treats as authoritative: copying the raw entries instead would promote members a lying `[]`
        # had hidden from the guards into a plain Hash the schema reads, which is the split the guards
        # exist to prevent (a hidden colliding pair emits a duplicate property; a hidden cyclic member
        # reaches reflection and overflows the stack). Every other entry is copied via `each`, the one
        # method a walk requires. Assembled as a plain Hash rather than taken from the shape's `merge`,
        # which a subclass can override to return anything — including a non-Hash, or something that drops
        # the container just derived.
        def _derive_raw_shape_container!(validations)
          shape = Internal::ShapeGraph.hash_or_nil(validations[:shape])
          return if nil.equal?(shape)

          # Detached ALWAYS, not only when a container has to be derived: deriving one is a write, and what is
          # stored IS the contract, so writing into the caller's own Hash would change a shape they still hold.
          # One level is all this needs — the deep copy, and the bound on how much there is to copy, belong to
          # the single declaration walk (see _validate_and_snapshot_shape!), which is also what captures the
          # members list carried forward here. A shape nested inside a `do…end` block reaches this before that
          # walk, which is exactly why the write must not land on the caller's object.
          #
          # The walk itself is the other caller, for every member's nested `shape:` (see
          # `_check_and_copy_shape_members!`). The node it hands over is already axn's own copy, and the detach
          # is load-bearing there for a different reason: that copy is SHARED by every member reusing the shape,
          # while the container comes from the enclosing member's `type:` — so writing in place would give one
          # position the container derived for another.
          detached = Internal::ShapeGraph.detach_node(shape)
          detached[:container] = _shape_compatible_type!(validations) if nil.equal?(detached[:container])
          _reject_non_class_container!(detached[:container])
          validations[:shape] = detached
        end

        # A container is what the shaped value is type-checked against (`value.is_a?(container)` in
        # ShapeValidator), so it has to be a class or module. A raw `shape:` may name its own, and nothing
        # checked it — so a junk value reached that check and every call raised a bare `TypeError: class or
        # module required`, with nothing pointing at the declaration that caused it. Held to the same bar the
        # derived container is (`_shape_compatible_type!` rejects a `type:` that is not a structured class),
        # since this is the same value arrived at two ways.
        #
        # `Module` covers a class and a module both, tested with `case`/`when` so nothing the value defines
        # decides the answer.
        def _reject_non_class_container!(container)
          case container
          when ::Module then return
          end

          raise ArgumentError,
                "a shape's `container:` must be a class (got #{_inspect_field_name(container)}) — it is what the " \
                "shaped value is type-checked against, so a non-class makes every call raise `TypeError: class " \
                "or module required`. Name the container class (`Hash`, `Array`, or the object's own class), or " \
                "omit `container:` and let it be derived from `type:`."
        end

        def _partition_field_options(fields, **options)
          metadata_keys = Axn::Extensions.config.registered_field_metadata_keys
          metadata = options.slice(*metadata_keys)
          validations = options.except(*metadata_keys)

          unknown = validations.keys.reject { |k| KNOWN_VALIDATION_KEYS.include?(k) }
          if unknown.any?
            raise ArgumentError,
                  "Unknown key(s) #{unknown.map(&:inspect).join(', ')} in field declaration. " \
                  "Not a recognized validation or registered field metadata key."
          end

          if metadata.present? && fields.size > 1
            raise ArgumentError,
                  "Field metadata (#{metadata.keys.join(', ')}) can only be provided when declaring a single field"
          end

          _symbolize_option_bags!(validations)

          [validations, metadata]
        end

        # Option-bag keys are axn's own grammar — `klass:`, `in:`, `with:`, `minimum:` — and every consumer reads
        # them as Symbols (`options[:klass]`, `options[:in]`), axn's and ActiveModel's alike. A bag keyed by
        # STRINGS therefore answers no consumer at all, which is what a params-derived Hash or
        # `.with_indifferent_access` produces: `type:`, `inclusion:` and `length:` declared cleanly and then
        # rejected the values they were declared to accept, `model:` looked up a class inferred from the field
        # name, and `of:` raised "must supply :klass". Symbol-canonical here, for the same reason a field name
        # and a shape member name are symbol-canonical at declaration: one spelling per slot, decided once.
        #
        # KEYS only, and only the bag's own. Values stay the caller's objects (an `inclusion:` list must keep
        # its own `include?`), and nothing deeper is touched — below a bag is the caller's data, whose meaning
        # is not axn's to reinterpret.
        #
        # Runs AFTER the unknown-key rejection above, deliberately: a String key at the DECLARATION level
        # (`expects :a, "type" => String`) is an unknown key and still says so, rather than being quietly
        # accepted by this.
        def _symbolize_option_bags!(validations)
          Internal::ShapeGraph.each_entry(validations) do |key, value|
            bag = Internal::ShapeGraph.hash_or_nil(value)
            next if nil.equal?(bag)

            symbolized = _symbol_keyed_bag(bag) { "the `#{key}:` option bag" }
            validations[key] = symbolized unless nil.equal?(symbolized)
          end
        end

        # The bag with String keys converted, or nil when every key is already a Symbol — so an ordinary
        # declaration allocates nothing here. A key that is neither is left exactly as it came: it is not this
        # grammar, and reinterpreting it would be widening rather than canonicalizing.
        #
        # Read through the bound-`each` seam, never by asking the bag to convert itself: `symbolize_keys` (like
        # `transform_values` and `dup` before it) is the caller's own method, and an indifferent-access bag is a
        # Hash subclass like any other.
        #
        # The label is YIELDED rather than passed, so naming the bag costs nothing until there is an error to
        # name: every declaration pays for a String built here otherwise, which is measurable on a shape-heavy
        # contract (240 members, ~1ms).
        def _symbol_keyed_bag(bag)
          found = false
          Internal::ShapeGraph.each_entry(bag) do |key, _value|
            case key
            when ::String then found = true
            end
          end
          return nil unless found

          copy = {}
          Internal::ShapeGraph.each_entry(bag) do |key, value|
            canonical = case key
                        when ::String then key.to_sym
                        else key
                        end
            _raise_ambiguous_option_key!(yield, canonical) if copy.key?(canonical)

            copy[canonical] = value
          end
          copy
        end

        def _raise_ambiguous_option_key!(label, canonical)
          raise ArgumentError,
                "#{label} declares #{Axn::Reflection::PropertyNames.inspect_field_name(canonical)} twice — once " \
                "under a String key and once under a Symbol — and one option cannot hold two values, so " \
                "canonicalizing them would silently drop one of the two declared. Declare the option once, under " \
                "a Symbol key."
        end

        # Pure parse: builds the configs without touching the class (no readers defined), so callers
        # can run every declaration check before committing anything.
        def _parse_field_configs( # rubocop:disable Metrics/ParameterLists
          *fields,
          on: nil,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          metadata: {},
          reader_names: {},
          user_facing: false,
          method_call: false,
          **validations
        )
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          if validations.key?(:model)
            _validate_model_batch!(fields, on:)
            _reject_model_transform!(fields, on:, preprocess:, validations:)
          end

          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            reader = reader_names[field] || field
            FieldConfig.new(field:, validations: parsed_validations, on:, default:, preprocess:, sensitive:, metadata:,
                            reader_as: reader, user_facing:, method_call:)
          end
        end

        # `coerce:`/`preprocess:` transform a scalar WIRE value, but a `model:` field resolves a record
        # from an id/record — its value is the record, not a scalar to coerce, and the class check `model:`
        # already performs is not what `coerce:` does. So neither ever had a coherent meaning on a model
        # field, and (now that subfield transforms resolve on the read path, which the model reader does
        # not route through) applying them would silently do nothing. Reject at declaration — loud, never
        # silently inert. To transform the lookup TOKEN, declare/transform the `<field>_id` field instead.
        def _reject_model_transform!(fields, on:, preprocess:, validations:)
          offending = []
          offending << "coerce:" if validations.key?(:coerce) || (validations[:type].is_a?(Hash) && validations[:type][:coerce])
          offending << "preprocess:" unless preprocess.nil?
          return if offending.empty?

          where = on ? "#{fields.map(&:to_s).inspect} with on: #{on}" : fields.map(&:to_s).inspect
          raise ArgumentError,
                "#{offending.join(' / ')} is not supported on a `model:` field (#{where}) — a model field resolves a " \
                "record from an id, not a scalar to coerce/preprocess. To transform the lookup token, declare or " \
                "transform the `<field>_id` field instead."
        end

        # A model: batch that also names a model field's own `<field>_id` companion (e.g.
        # `expects :company, :company_id, model:`) can never work at any level: model: applies to
        # EVERY field in the batch, so the `<field>_id` is itself a model: field (it would require
        # `<field>_id_id` and reject a raw id), and it collides with the raw-id reader the model:
        # field already generates. A model: field exposes its own `<field>_id` reader for the raw id,
        # so the explicit one is both redundant and broken. (Declaring the id in a separate expects
        # doesn't help either — the generated `<field>_id` reader already exists, so it trips the
        # duplicate-reader guard.)
        def _validate_model_batch!(fields, on: nil)
          batch = fields.map(&:to_sym)
          model_field = batch.find { |f| batch.include?(Axn::Internal::FieldConfig.model_id_key(f)) }
          return unless model_field

          id_key = Axn::Internal::FieldConfig.model_id_key(model_field)
          where = on ? "#{fields.map(&:to_s).inspect} with on: #{on}" : fields.map(&:to_s).inspect
          raise ArgumentError,
                "a model: batch (#{where}) names both " \
                ":#{model_field} and its own id companion :#{id_key} — but model: applies to every field " \
                "in the batch, so :#{id_key} becomes a second model: field (requiring :#{id_key}_id) " \
                "rather than the raw id. The model: field :#{model_field} already generates a " \
                ":#{id_key} reader for the raw id; drop the explicit :#{id_key}."
        end

        # Generate the readers for an already-validated, already-committed batch of top-level inbound
        # configs. Two passes, matching _define_subfield_readers!: all explicit primary readers first,
        # then the auto-generated companions (boolean `?` predicates, model `<field>_id` readers), so a
        # companion defers to an explicit same-named reader regardless of declaration order.
        def _define_field_readers!(configs)
          # rubocop:disable Style/CombinableLoops
          configs.each { |c| _define_field_reader(c.reader_as, c.field) }
          configs.each do |c|
            _define_boolean_predicate_reader(c.reader_as) if c.boolean?
            _define_model_id_reader(c.reader_as, c.field, c.validations[:model]) if c.validations.key?(:model)
          end
          # rubocop:enable Style/CombinableLoops
        end

        # An auto-generated companion reader (boolean predicate, model `<field>_id`) defers to any
        # pre-existing method of the same name rather than clobbering it — but, unlike a silent skip,
        # leaves a debug-level breadcrumb so a surprising shadow is discoverable. Returns true when
        # the name is free (caller should define it), false when it's taken (already logged).
        def _reader_name_available?(name, kind:)
          return true unless method_defined?(name) || private_method_defined?(name)

          Axn.config.logger.debug { "[Axn] #{self.name || 'Action'}: skipping auto-generated #{kind} reader `#{name}` (already defined)" }
          false
        end

        # `model:` fields get a `<reader>_id` reader meaning "the primary key of the resolved
        # record", reading the raw id from the inbound context. The subfield contract defines the
        # same reader against an `on:` parent — both share `_define_model_id_reader_from`.
        def _define_model_id_reader(reader, source_field, model_options)
          by_primary_key = model_options.is_a?(Hash) && model_options[:finder] == :find
          _define_model_id_reader_from(reader:, source_field:, by_primary_key:) do |id_key|
            # The `<field>_id` token: reuse a DECLARED `<field>_id` field's CACHED reader value
            # (resolve_value) so this companion agrees with that field's own reader, validation, and the
            # model-consistency check, and a stateful preprocess runs at most once per call. An undeclared
            # id is the caller's raw token. A caller-OMITTED id resolves nil here (present-record
            # authority) and falls through to the resolved record's own id.
            id_config = self.class.internal_field_configs.find { |c| c.field == id_key }
            next @__context.provided_data[id_key] unless id_config

            @__context.provided_data[id_key].nil? ? nil : Axn::Core::ContractForSubfields.resolve_value(self, id_config)
          end
        end

        # Defines the `<reader>_id` reader shared by the top-level and subfield `model:` contracts.
        # For the default (id-based `:find`) finder a directly-supplied, non-blank id IS the pk, so
        # it's returned without resolving the record; otherwise (a record was passed, the id was
        # blank, or a custom finder is in play) it reads the resolved — and memoized — record's `.id`,
        # so it never triggers a second lookup. A blank id is treated as absent (matching the
        # resolver/consistency check), and a missing record yields nil rather than the raw input —
        # which for a custom finder is a lookup token, not a primary key. `raw_reader` yields the raw
        # `<field>_id` value for the caller's context (top-level provided_data vs. the `on:` parent).
        def _define_model_id_reader_from(reader:, source_field:, by_primary_key:, &raw_reader)
          id_reader = Internal::FieldConfig.model_id_key(reader)
          return unless _reader_name_available?(id_reader, kind: "model id")

          id_key = Internal::FieldConfig.model_id_key(source_field)
          define_method(id_reader) do
            raw = instance_exec(id_key, &raw_reader)
            next raw if by_primary_key && !raw.nil? && !raw.to_s.strip.empty?

            record = public_send(reader)
            record.respond_to?(:id) ? record.id : nil
          end
        end

        def _define_field_reader(reader, source = reader)
          # Allow local access to explicitly-expected fields on the action instance.
          # NOTE: exposes fields are intentionally excluded — access those via result.field instead.
          # `reader` is the method name (may be aliased via as:/prefix:); `source` is the wire key
          # the value actually lives under in the inbound context.
          define_method(reader) { internal_context.public_send(source) }
        end

        def _define_boolean_predicate_reader(field)
          field_name = field.to_s
          return if field_name.end_with?("?")

          predicate_name = "#{field_name}?"
          return unless _reader_name_available?(predicate_name, kind: "boolean predicate")

          alias_method predicate_name, field
        end

        # `coerce: <Type>` → `type: { klass: <Type>, coerce: true }`. The sugar value carries the
        # target type (a Class or array of Classes), never a boolean — the boolean lives only inside
        # the type hash. Combining with an explicit `type:` is contradictory (the sugar already
        # declares the type), so it raises.
        def _expand_coerce_sugar!(validations)
          return unless validations.key?(:coerce)

          if validations.key?(:type)
            raise ArgumentError,
                  "coerce: and type: cannot be combined (coerce: already declares the type). " \
                  "Use `type: { klass: …, coerce: true }` when you also need sibling type options."
          end

          target = validations.delete(:coerce)
          if [true, false].include?(target)
            raise ArgumentError,
                  "coerce: must be a type (a Class or array of Classes), not a boolean. " \
                  "The boolean form lives inside `type: { klass: …, coerce: true }`."
          end

          validations[:type] = { klass: target, coerce: true }
        end

        # A coerce target must be in the v1 coercible set (Axn::Reflection::Coercion::SUPPORTED); an
        # unsupported type raises not-yet-supported so expanding the set stays a deliberate future
        # ticket. `String` may accompany a coercible type as a passthrough branch (the raw wire scalar
        # itself), which is why `coerce: [Date, String]` is legal — but a target set with no coercible
        # member coerces nothing and is a declaration mistake.
        def _validate_coercion!(type_hash)
          # The flag is a strict boolean — this base layer raises on DSL misuse rather than treating
          # any truthy value (`coerce: :typo`) as enabled. `coerce: false` is a valid no-op (the type
          # is declared, coercion off), so it passes here and skips the coercible-set checks below.
          coerce = type_hash[:coerce]
          raise ArgumentError, "coerce: must be true or false (got #{coerce.inspect})" unless [true, false].include?(coerce)
          return unless coerce

          klasses = Array(type_hash[:klass])
          coercible = Axn::Reflection::Coercion.coercible_klasses(type_hash)
          unsupported = klasses - coercible - [String]

          unless unsupported.empty?
            raise ArgumentError,
                  "coerce: does not yet support #{unsupported.map(&:inspect).join(', ')} " \
                  "(supported: #{Axn::Reflection::Coercion::SUPPORTED.join(', ')}). " \
                  "String may accompany a coercible type as a passthrough."
          end

          return unless coercible.empty?

          raise ArgumentError,
                "coerce: needs at least one coercible type (#{Axn::Reflection::Coercion::SUPPORTED.join(', ')}); " \
                "got #{klasses.map(&:inspect).join(', ')}."
        end

        # A blank gate is canonicalized away at declaration, EXACTLY tracking the set of condition
        # values ActiveModel ignores. AM resolves if:/unless: through
        # ActiveSupport::Callbacks::Callback#check_conditionals, which early-returns an empty
        # condition list `if conditionals.blank?` (activesupport 7.2.2.2, active_support/callbacks.rb)
        # — so a blank condition is NO conditional at all and the validators run unconditionally.
        # Measured against AM 7.2.2.2 via `validates :f, presence: true, if: <value>` with the field
        # absent: `nil`, `false`, `""`, any whitespace-only String, and `[]` all RUN the validators
        # (they are blank, hence ungated — `if: false` means "no condition", NOT "never run"), which
        # is precisely `value.blank?`. We reuse that same predicate here, so a REMAINING gate key
        # downstream — the push-down exemption in _parse_field_validations, reflection's
        # conditionally_gated?, and the contradiction carve-outs — always denotes a REAL, enforced
        # gate. Without this, a blank gate would be classified as gated though it runs
        # unconditionally: ancestor-forcing would be wrongly relaxed, and the dead-tolerance check
        # would wrongly accept a contradiction-shaped contract (schema looser than runtime). Only
        # non-blank opaque values survive as gates (a Symbol, a Proc; a non-blank String survives
        # here but AM then rejects it at validator build — loud, unchanged). Mutates `validations`.
        def _canonicalize_blank_gates!(validations)
          Internal::FieldConfig::CONDITIONAL_GATE_KEYS.each do |key|
            next unless validations.key?(key)

            validations.delete(key) if validations[key].blank?
          end
        end

        # Axn's own validators accept a direct value in place of an options bag (`type: Hash`,
        # `of: Hash`, `model: User`, `validate: ->(v){}`), and each of them owns the expansion of its own
        # shorthand. THE seam that applies them, so a declaration reaching a validator — or a consumer
        # reading a declared bag — meets one canonical spelling however it was written.
        #
        # Called for a top-level field/subfield (below) and for every shape MEMBER
        # (`ShapeDeclaration#_symbol_keyed_member_validations`), which is the whole reason it is a seam
        # rather than four lines: `#field` + `#validations` is the entire member contract, so nothing
        # expanded a raw `shape:` member's bag, and the bare spelling — the only one anyone writes by hand
        # — reached the validators and the projection as a Class. Every consumer of a declared bag reads
        # `[:klass]`, so `type: Hash` validated nothing and failed every call with `ArgumentError: must
        # supply :klass`, while `of: Hash` asked a Class for `[:klass]` and took the projection down with
        # `ArgumentError: odd number of arguments for Hash`. Expanding here is what makes the parity
        # `ShapeConfig` claims — a member declared via the block form, via a raw `shape:` kwarg, or by the
        # caller's own class is validated identically — true of the bag as well as of the name.
        #
        # `fields` names the declaration for the one expander that reads it (`model:` infers its class from
        # the field name); a member passes the canonical Symbol the declaration walk already judged it under,
        # so nothing here converts a caller-supplied name a second time. A member never arrives carrying
        # `model:` at all — a reader-less member cannot resolve a record, so it is refused ahead of this rather
        # than expanded into a bag that would quietly type-check the element instead.
        #
        # The `of:` pair below is the same seam deliberately, not a guard that happens to sit here: both read
        # the bag the expansion just produced (`type:`'s klass list, `of:`'s own bag), so they are the checks
        # canonicalizing MAKES possible, and splitting them from it is what let a member expand like a field
        # and validate like nothing. Together they are one rule with two halves — the option only means
        # something over an Array, and it must name what the elements are — and neither has any runtime
        # counterpart to fall back on: `OfValidator` returns before it inspects a value that is not an Array,
        # so `of:` beside `type: Hash` never applied at all, while `of: nil` reached `check_validity!` and
        # raised on every call instead of at the author.
        def _canonicalize_validator_options!(validations, fields)
          validations[:type] = Axn::Validators::TypeValidator.apply_syntactic_sugar(validations[:type], fields) if validations.key?(:type)
          validations[:model] = Axn::Validators::ModelValidator.apply_syntactic_sugar(validations[:model], fields) if validations.key?(:model)
          validations[:validate] = Axn::Validators::ValidateValidator.apply_syntactic_sugar(validations[:validate], fields) if validations.key?(:validate)
          return unless validations.key?(:of)

          validations[:of] = Axn::Validators::OfValidator.apply_syntactic_sugar(validations[:of], fields)
          declared_klasses = Array(validations.dig(:type, :klass))
          raise ArgumentError, "of: requires type: Array (got #{declared_klasses.inspect})" unless declared_klasses == [Array]

          raise ArgumentError, "of: must supply :klass" if validations[:of][:klass].nil?
        end

        # This method applies any top-level options to each of the individual validations given.
        # It also allows our custom validators to accept a direct value rather than a hash of options.
        def _parse_field_validations(
          *fields,
          allow_nil: false,
          allow_blank: false,
          **validations
        )
          Internal::ShapeGraph.detach_option_containers!(validations)
          _canonicalize_blank_gates!(validations)

          # `coerce: <Type>` sugar → a coerce flag inside the type bag (coercion binds to the type;
          # it is meaningless without one). Runs before the type: sugar so the resulting `{ klass: }`
          # hash flows through the normal path.
          _expand_coerce_sugar!(validations)

          # Validate the coerce target set (covers BOTH the sugar above and an explicit
          # `type: { klass:, coerce: true }`). Deliberately NOT part of the canonicalization seam below, and so
          # not applied to a shape member: `coerce:` is a field-only option — it resolves a coerced value onto a
          # reader, which a member has not got, and the block form rejects it on a member outright — so the
          # coercible-set check would half-legitimize an option a member may not carry at all. It runs ahead of
          # the seam rather than after it (where it sat when the `of:` checks were inline here) so that a
          # declaration failing both is still reported by its coercion error: only `_expand_coerce_sugar!` can
          # produce a `coerce:` key, and the type sugar never adds one, so the bag it reads is already final.
          _validate_coercion!(validations[:type]) if validations[:type].is_a?(Hash) && validations[:type].key?(:coerce)

          _canonicalize_validator_options!(validations, fields)

          _derive_raw_shape_container!(validations)

          # Push allow_blank and allow_nil to the individual validations
          if allow_blank || allow_nil
            # A truthy explicit presence: can never fire under a tolerance flag — the pushed-down
            # allow_blank/allow_nil would make the presence validator accept exactly the values it
            # exists to reject — so the combination is dead machinery, rejected at declaration.
            # (`presence: false` is coherent: explicit suppression, same intent as the flag.)
            if validations[:presence]
              raise ArgumentError,
                    "optional:/allow_blank:/allow_nil: cannot be combined with an explicit `presence:` — " \
                    "the tolerance is pushed into every validator, so the presence check could never fail. " \
                    "Declare one requiredness signal (drop the flag, or drop presence:)."
            end

            # ActiveModel's shared "default" options (`if:`/`unless:`/`on:`/`strict:`/`allow_blank:`/
            # `allow_nil:`) ride the hash as sibling keys of the validators but are NOT validators —
            # there is nothing to push tolerance into, and normalizing them as scalars would corrupt
            # them (e.g. `strict: true` → `strict: { allow_blank:, allow_nil: }`, which then raises a
            # bare `TypeError` at strict-raise time instead of `ActiveModel::StrictValidationFailed`).
            # Slice them out (reusing AM's own canonical list so the set can't drift), transform only
            # the real validators, then restore verbatim. Core-Ruby delete (not ActiveSupport's
            # Hash#except!): axn runs outside Rails, where that core_ext may never be loaded.
            shared_option_keys = Axn::Validation::Base.shared_validation_option_keys
            shared_options = validations.slice(*shared_option_keys)
            shared_option_keys.each { |key| validations.delete(key) }
            validations.transform_values! do |v|
              # A falsy validator value (`presence: false`, or a `nil`/`false` on any validator) is
              # disabled — `validates` skips it (`next unless options`), so there is nothing to push
              # tolerance into; pass it through unchanged (mirrors AM's own falsy-skip).
              next v unless v

              # Any other value is normalized exactly as `validates` would (scalar → options hash),
              # then the tolerance rides on top — so `numericality: true`, `inclusion: [..]`/`1..5`,
              # `format: /re/`, etc. combine transparently with optional:/allow_blank:/allow_nil:,
              # matching how they behave without a tolerance flag (PRO-2915).
              { allow_blank:, allow_nil: }.merge(Axn::Validation::Base.normalize_validator_options(v))
            end
            validations.merge!(shared_options)
          else
            # Apply default presence validation (unless the type is boolean or params)
            type_values = Array(validations.dig(:type, :klass))
            validations[:presence] = true unless validations.key?(:presence) || type_values.include?(:boolean) || type_values.include?(:params)
          end

          fields.map { |field| [field, validations] }
        end
      end

      # Keys the framework owns in the execution/exception-report context, so they can't be set via
      # set_execution_context or the additional_execution_context hook: :inputs/:outputs are the
      # structural pair, and :async/:ambient_context/:axn_stack/:tags/:dimensions are
      # framework-populated in execution_context / Internal::ExceptionContext.build — reserving them
      # here prevents a user value from being silently overwritten when they're assigned after merging
      # the user's extra keys. :tags/:dimensions carry the resolved `tag`/`dimension` facets (PRO-2853).
      RESERVED_EXECUTION_CONTEXT_KEYS = %i[inputs outputs async ambient_context axn_stack tags dimensions].freeze

      module InstanceMethods
        def internal_context = @__internal_context ||= _build_context_facade(:inbound)
        def result = @__result ||= _build_context_facade(:outbound)

        # Resolved declared-inbound fields as a Hash (defaults/preprocess applied, model: fields
        # resolved to their record), keyed by wire key. Splat into a nested action to forward
        # inputs: `Child.call(**inputs, override: x)`. Reads through internal_context (not raw
        # provided_data) so a model: field supplied by `<field>_id` forwards the resolved record —
        # the record lives only in the reader. Fields whose resolved value is nil are omitted, so a
        # nested action still applies its own absent/default handling for them.
        def inputs
          self.class._declared_fields(:inbound).each_with_object({}) do |field, hash|
            value = internal_context.public_send(field)
            hash[field] = value unless value.nil?
          end
        end

        delegate :default_error, :default_success, to: :internal_context

        # Accepts:
        # - a single Axn::Result: forwards (result.declared_fields & own outbound declared fields)
        # - two positional arguments (key, value)
        # - a hash of key/value pairs
        def expose(*args, **kwargs)
          return _expose_from_result(args.first) if args.size == 1 && kwargs.empty? && args.first.is_a?(Axn::Result)

          if args.any?
            if args.size != 2
              raise ArgumentError,
                    "expose must be called with exactly two positional arguments (or a hash of key/value pairs)"
            end

            kwargs.merge!(args.first => args.last)
          end

          kwargs.each do |key, value|
            # Symbolize the exposure key to match the symbol-canonical outbound contract (PRO-2790):
            # `exposes "saved"` declares `:saved`, and the result facade / outbound validation read
            # `exposed_data[:saved]`. Without this a string-keyed write (`expose("saved", v)`,
            # `expose("saved" => v)`, or a string `expose_return_as`) would store under "saved" and
            # the declared field would read nil.
            key = key.to_sym

            raise Axn::ContractViolation::UnknownExposure, key unless result.respond_to?(key)

            @__context.exposed_data[key] = value
          end
        end

        # Set additional context to be included in execution_context for exception reporting/handlers.
        # This context is NOT included in automatic pre/post logging (which only logs inputs/outputs).
        # Framework-owned keys (RESERVED_EXECUTION_CONTEXT_KEYS) are stripped before merging.
        def set_execution_context(**kwargs)
          @__additional_execution_context ||= {}
          @__additional_execution_context.merge!(kwargs.except(*RESERVED_EXECUTION_CONTEXT_KEYS))
        end

        # Clear any previously set additional execution context
        def clear_execution_context
          @__additional_execution_context = nil
        end

        # Returns a structured hash for exception reporting and handlers.
        # Contains :inputs, :outputs, any extra keys from set_execution_context / additional_execution_context
        # hook, and (when present) a sensitive-filtered :ambient_context.
        # Framework-owned keys (RESERVED_EXECUTION_CONTEXT_KEYS) from extra context are stripped before merging.
        def execution_context
          explicit_context = @__additional_execution_context || {}
          hook_context = respond_to?(:additional_execution_context, true) ? additional_execution_context : {}
          extra_context = explicit_context.merge(hook_context).except(*RESERVED_EXECUTION_CONTEXT_KEYS)

          ctx = {
            inputs: _safe_execution_context_slice { inputs_for_logging },
            outputs: _safe_execution_context_slice { outputs_for_logging },
            **extra_context,
          }

          # Resolving/filtering ambient context can raise (e.g. a failing ambient_context_provider
          # whose error is now memoized and re-raised on every read — see
          # Axn::Core::AmbientContext#ambient_context). Building exception-report context must never
          # itself raise, or the real exception never reaches Axn.config.on_exception, so omit
          # ambient_context here rather than propagate.
          ambient = _safe_execution_context_slice do
            ambient_filter = self.class._has_dynamic_sensitive_fields? ? self.class._build_instance_filter(self) : self.class.inspection_filter
            masked = self.class._mask_unfilterable_shapes(ambient_context, self.class._sensitive_ambient_shape_paths(self), self)
            self.class.send(:_filter_tolerating_cycles, ambient_filter, masked)
          end
          ctx[:ambient_context] = ambient if ambient.present?
          ctx
        end

        private

        # Exception-report context must never itself raise (a failing ambient provider can propagate
        # through sensitive-predicate evaluation while building any of these slices, since resolving
        # inputs_for_logging/outputs_for_logging may evaluate a dynamic `sensitive:` predicate that
        # reads ambient_context). Degrade to {} rather than let it escape.
        #
        # Rescues the same set as Axn::Extensions.best_effort's side-channel default (see
        # SWALLOWABLE_BEYOND_STANDARD_ERROR): building a report is the archetypal side channel, and
        # ActiveSupport::ParameterFilter — which sensitive-field filtering runs every slice through —
        # has no cycle guard of its own, so a self-referential value reaches here as a
        # SystemStackError. This is the only net between that and the real exception never being
        # reported at all.
        def _safe_execution_context_slice
          yield
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
          {}
        end

        # Forward the intersection of a nested result's declared exposures and this action's own
        # declared exposures. Reads declared fields (static contract) so it is safe on a failed
        # result — it forwards whatever the child managed to expose (nil for the rest) and never
        # inspects ok?/error or calls fail!. An empty intersection is always a wiring mistake.
        def _expose_from_result(source_result)
          forwardable = source_result.declared_fields & self.class._declared_fields(:outbound)

          if forwardable.empty?
            raise Axn::ContractViolation::NoMatchingExposures.new(
              declared: self.class._declared_fields(:outbound),
              exposed: source_result.declared_fields,
            )
          end

          forwardable.each do |field|
            @__context.exposed_data[field] = source_result.public_send(field)
          end
        end

        # Filtered inbound fields only (no additional context) - used by automatic logging and execution_context
        def inputs_for_logging
          self.class._context_slice(data: @__context.__combined_data, direction: :inbound, action_instance: self)
        end

        # Filtered outbound fields only (no additional context) - used by automatic logging and execution_context
        def outputs_for_logging
          self.class._context_slice(data: @__context.__combined_data, direction: :outbound, action_instance: self)
        end

        def _build_context_facade(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

          klass = direction == :inbound ? Axn::Core::InternalContext : Axn::Result
          implicitly_allowed_fields = direction == :inbound ? self.class._declared_fields(:outbound) : []

          klass.new(action: self, context: @__context, declared_fields: self.class._declared_fields(direction), implicitly_allowed_fields:)
        end
      end
    end
  end
end
