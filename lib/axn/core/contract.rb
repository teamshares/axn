# frozen_string_literal: true

require "date"

require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"

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
              "class #{Axn::Internal::ClassName.of(sensitive)}) — any other value is not a redaction rule, and " \
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
              "#{Axn::Internal::ClassName.of(name)}) — a member name is both the JSON property it renders as " \
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
          # Absent stays absent — `nil`/`""` mean "no route", and `present?` decides that without rendering
          # anything.
          on = on.to_sym if on.present?

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

        # Everything redaction derives from the DECLARATION rather than from a call: the candidate config
        # set, whether resolving `sensitive:` needs an instance at all, the static field-name filter, the
        # static shape paths, and — per shape — which members a mask has to descend into.
        #
        # All of it is a pure function of the class, because a stored shape graph is a declaration-time
        # SNAPSHOT — every node a Hash axn built, every member a `ShapeConfig` axn constructed from values read
        # once (`_snapshot_member_attributes!`). That is what makes an identity-keyed table sound at all: a
        # retained member would have left `sensitive:` free to change with nothing the key could see, so the
        # first read of a contract decided it and a later flip changed nothing. Re-deriving it per logged call
        # instead made the cost of redaction scale with the size of that graph, and worst for the contracts
        # that use no `sensitive:` at all: concluding "there is nothing to redact" is exactly what requires
        # visiting every member, so a 24,000-member shape with no `sensitive:` anywhere cost more per logged
        # call (~34ms) than the same shape with one.
        #
        # Keyed by the IDENTITY of the three config arrays, exactly as `_resolved_subfields` is and as
        # `PropertyNames.validate_outbound!`'s verdict is: the arrays are copy-on-write, so ANY later
        # declaration — a reopened class, a subclass, `Mountable`'s builder clearing them, a downstream gem
        # assigning the attribute directly — mints new ones and the stale table misses on `equal?`. That is
        # invalidation with no hook to keep in sync, which matters more here than for a schema cache: a
        # stale answer does not merely disagree with the contract, it fails to redact a `sensitive:` field
        # declared after the first logged call.
        def _contract_redaction
          internals = internal_field_configs
          externals = external_field_configs
          subfields = subfield_configs
          memo = @_axn_contract_redaction
          return memo if memo&.current?(internals, externals, subfields)

          @_axn_contract_redaction = ContractRedaction.new(internals:, externals:, subfields:)
        end

        # The table `_contract_redaction` hands out. Mutable (so not a `Data`) because each fact is derived
        # on first demand and written once, with `nil` meaning "not yet derived" — which none of the values
        # can be. Unlocked deliberately: every slot's value is the one answer that contract will ever have, so
        # a racing second derivation recomputes it and writes the same thing (the resolved-subfield cache's
        # single-ivar-write reasoning). The two per-shape tables are the same bargain one level down — a lost
        # race costs a repeat derivation, and a single Hash insert is not interruptible by another Ruby thread.
        class ContractRedaction
          attr_reader :internals, :externals, :subfields
          attr_accessor :candidates, :dynamic, :static_fields, :filter,
                        :static_shape_paths, :static_ambient_shape_paths

          def initialize(internals:, externals:, subfields:)
            @internals = internals
            @externals = externals
            @subfields = subfields
            # Per shape / per config, by identity — neither defines a `hash`/`eql?` axn would want to run,
            # and identity is the right question anyway: the stored graph is the one axn snapshotted.
            @nested_members = {}.compare_by_identity
            @member_names = {}.compare_by_identity
          end

          def current?(internals, externals, subfields)
            @internals.equal?(internals) && @externals.equal?(externals) && @subfields.equal?(subfields)
          end

          def nested_members_for(shape, &derive) = @nested_members.fetch(shape) { @nested_members[shape] = derive.call }

          def member_names_for(config, &derive) = @member_names.fetch(config) { @member_names[config] = derive.call }
        end
        private_constant :ContractRedaction

        def inspection_filter
          memo = _contract_redaction
          memo.filter ||= ActiveSupport::ParameterFilter.new(sensitive_fields)
        end

        def sensitive_fields
          _static_sensitive_fields
        end

        # Every config whose `sensitive:` participates in redaction: the declared inbound/outbound fields
        # and subfields, plus (recursively) the members of any shape block they carry. Shape members live
        # in validations[:shape][:members] at every depth, so the walk is uniform — a sensitive member at
        # any nesting level contributes its name to the ParameterFilter set (which redacts by key name at
        # any depth, array elements included). Single-sources the traversal for all three collectors.
        # Derived from the arrays the memo is KEYED on, never re-read from the class: a table that answered
        # from a newer contract than the one it is keyed to would be a stale answer wearing a valid key.
        def _sensitive_candidate_configs
          memo = _contract_redaction
          memo.candidates ||= (memo.internals + memo.externals + memo.subfields)
                              .flat_map { |config| _flatten_sensitive_candidates(config) }
        end

        def _flatten_sensitive_candidates(config, seen = nil, depth = 0)
          # Through the shared seam: a member list that hides itself from `flat_map` would drop a
          # `sensitive:` member from the redaction set, which leaks rather than merely disagreeing.
          shape = Internal::ShapeGraph.shape_in(config.validations)
          # Bounded BOTH ways, because the configs this walks need not have been DECLARED: the declaration walk
          # rejects an untraversable graph and snapshots what it accepts, but `internal_field_configs` and friends
          # are writable, so a config assigned onto a class carries whatever shape its author built — pointed back
          # at itself (which `CycleGuard` sees) or minting a fresh nested shape on every read (which nothing sees
          # but depth). This runs while a log line or an exception report is being built — once per contract, or
          # per logged call for a `sensitive:` that resolves against the action — and the alternative is
          # SystemStackError from a log line, a side channel taking down the call it observes.
          #
          # Nothing is lost by stopping at a cycle: it re-reaches members an enclosing frame is already
          # collecting. Past the depth bound there IS no honest answer, and the wholesale mask does the work —
          # `_shape_has_sensitive_member?` answers true there, so the whole value is redacted rather than
          # filtered per member.
          return [config] if nil.equal?(shape) || depth > Internal::ShapeGraph::MAX_NESTING

          nested = Axn::Internal::CycleGuard.guard(shape, seen, on_cycle: []) do |open|
            Internal::ShapeGraph.members(shape).flat_map { |member| _flatten_sensitive_candidates(member, open, depth + 1) }
          end
          [config, *nested]
        end

        def _static_sensitive_fields
          memo = _contract_redaction
          memo.static_fields ||= _sensitive_candidate_configs
                                 .select { |c| _config_sensitive(c) == true }
                                 .flat_map { |c| _sensitive_field_keys(c) }
        end

        # Whether resolving this contract's `sensitive:` needs an action instance — and therefore the ONE
        # question every reuse decision below turns on. It can be one question because the value space is closed
        # at declaration (see Contract.validate_sensitive!): over `true`/`false`/`nil`/Symbol/Proc, "carries a
        # Proc or Symbol" and "would resolve differently with an instance than without" are the same set. A
        # second, stricter predicate existed here to cover a truthy value that is neither — which the
        # instanceless path counted as not-sensitive while the per-instance path truthiness-tested it as
        # sensitive, observably so for a non-Hash shaped value — and rejecting that value at declaration is what
        # removes the divergence instead of guarding it.
        #
        # `false` is one of the two answers, so the memo is guarded on `nil` rather than written with `||=`: an
        # `||=` here re-ran the whole candidate walk on every logged call for precisely the contracts that have
        # no dynamic `sensitive:` — which is nearly all of them.
        def _has_dynamic_sensitive_fields?
          memo = _contract_redaction
          return memo.dynamic unless memo.dynamic.nil?

          memo.dynamic = _sensitive_candidate_configs.any? do |config|
            # `case`/`when` consults the real class, so a caller-supplied member's value cannot decide whether
            # it needs an instance — the same non-dispatching test the declaration guard uses.
            case _config_sensitive(config)
            when ::Proc, ::Symbol then true
            else false
            end
          end
        end

        def _resolve_sensitive_fields(action_instance)
          return _static_sensitive_fields unless _has_dynamic_sensitive_fields?

          _sensitive_candidate_configs
            .select { |config| _resolve_sensitive_value(_config_sensitive(config), action_instance) }
            .flat_map { |c| _sensitive_field_keys(c) }
        end

        # A shape member's contract is duck-typed — ShapeValidator requires only #field/#validations,
        # and `shape: { members: [...] }` may be supplied raw with member objects that implement no
        # more than that. `#sensitive` is optional (absent on such a raw member), so read it defensively
        # and treat a missing reader as `false`, mirroring how the validator treats a missing
        # #method_call as not opted in. Read through Internal::ShapeGraph, so a member that DEFINES
        # `sensitive:` cannot opt out of redaction by denying the reader.
        #
        # That costs a Method allocation per read (~0.25µs, against ~0.04µs for `respond_to?` plus a
        # dispatch) and is spent deliberately: the reads here are per config on a derivation, and a
        # member hiding from redaction leaks a secret. `_sensitive_shape_paths` makes the opposite call for
        # the opposite reason — it reads axn's OWN configs, which cannot lie, so it takes the cheap
        # `shape_in` path. The tradeoff differs because the exposure does.
        def _config_sensitive(config)
          Internal::ShapeGraph.read(config, :sensitive) || false
        end

        # A sensitive `model:` field also redacts its generated `<field>_id` alias (the id is as
        # sensitive as the record). Non-model fields contribute only their own key.
        def _sensitive_field_keys(config)
          keys = [config.field]
          keys << Internal::FieldConfig.model_id_key(config.field) if config.validations[:model]
          keys
        end

        # The first three arms are the whole declared grammar (see Contract.validate_sensitive!); `!!` is what
        # turns a predicate's arbitrary return value into a decision. The `else` is now reachable only by `nil`
        # — which `_config_sensitive` already normalizes to `false` on every path that reads a config — and is
        # kept fail-SAFE rather than dropped: were an out-of-grammar value ever to arrive here, redacting a
        # truthy one is the direction that cannot leak. This is the branch whose truthiness test used to
        # disagree with the instanceless path about `sensitive: "yes"`, and closing the value space is what
        # removed the disagreement rather than a second predicate guarding it.
        def _resolve_sensitive_value(sensitive, action_instance)
          case sensitive
          when true, false
            sensitive
          when Symbol
            !!action_instance.send(sensitive)
          when Proc
            !!action_instance.instance_exec(&sensitive)
          else
            !!sensitive
          end
        end

        def _build_instance_filter(action_instance)
          ActiveSupport::ParameterFilter.new(_resolve_sensitive_fields(action_instance))
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

        # Internal method for filtering context data by direction
        # Used by instance methods (inputs_for_logging, outputs_for_logging) and async exception reporting
        # When action_instance is provided, dynamic sensitive fields are resolved against that instance.
        def _context_slice(data:, direction: nil, action_instance: nil)
          filter = if action_instance && _has_dynamic_sensitive_fields?
                     _build_instance_filter(action_instance)
                   else
                     inspection_filter
                   end
          sliced = _mask_unfilterable_shapes(data.slice(*_declared_fields(direction)), _sensitive_shape_paths(action_instance), action_instance)
          _filter_tolerating_cycles(filter, sliced)
        end

        # ActiveSupport::ParameterFilter has no cycle guard of its own, so a self-referential value blows
        # its stack — and since a filter is active for any action declaring `sensitive:`, that cost the
        # WHOLE slice: both auto_log lines dropped to warnings and the exception report degraded to empty
        # inputs/outputs, losing the fields that had nothing to do with the cycle.
        #
        # Retried on a decycled copy rather than decycling up front, so acyclic data (all of it, in
        # practice) pays nothing: no extra walk, no copy. The retry can only be reached by data that
        # already failed, where one wasted filter pass is irrelevant.
        def _filter_tolerating_cycles(filter, data)
          filter.filter(data)
        rescue SystemStackError
          filter.filter(Axn::Internal::CycleGuard.decycle(data))
        end

        # Per-element `sensitive:` redaction works by adding the member's key name to an
        # `ActiveSupport::ParameterFilter`, which redacts Hash keys at any depth — so a member inside a
        # Hash (or an Array of Hashes) is filtered precisely, siblings preserved. But the filter only
        # descends into Hashes: an object-backed shape value (a Data/Struct/PORO), or a malformed non-Hash
        # value where a Hash was expected (which reaches logging before inbound validation can reject it),
        # is opaque to it and would print whole. So for every field/subfield whose shape carries a
        # sensitive member, this walks to the shaped value and replaces a non-Hash value in a
        # member-bearing position with the mask — over-redacting the whole value (its non-sensitive
        # siblings included) rather than risk leaking the secret. Applied to logs, exception context,
        # and `inspect`.
        def _mask_unfilterable_shapes(data, shape_paths, action_instance)
          return data unless data.is_a?(Hash)

          shape_paths.reduce(data) do |acc, (wire_path, shape)|
            _mask_value_at_path(acc, wire_path, shape, action_instance)
          end
        end

        # Single-field entry — inspect renders one field at a time. Reuses the whole-hash pass on a
        # one-key hash so a subfield shape rooted under `field` is masked at its nested position too.
        def _mask_unfilterable_shape_value(field, value, action_instance)
          _mask_unfilterable_shapes({ field => value }, _sensitive_shape_paths(action_instance), action_instance)[field]
        end

        # `[(wire_path, shape)]` for every field/subfield whose shape carries a sensitive member. A
        # top-level field's path is `[field]`; a subfield's is its resolved wire path (from the
        # SubfieldTree cache), so a shape declared on a subfield — `expects :person, on: :payload, …
        # do … end` — is masked at `payload[:person]`, not just where a top-level shape lives.
        # Memoized unless a `sensitive:` resolves against the action (`_has_dynamic_sensitive_fields?`), which
        # is what keeps a logged call from paying for the whole stored graph. A contract that DOES need the
        # instance still derives per call — correctness requires it, and a memo ignoring the instance would
        # over-redact a `sensitive: :flag` member whose flag is false, which looks safe and is a behavior
        # change.
        def _sensitive_shape_paths(action_instance)
          return _derive_sensitive_shape_paths(action_instance) if _has_dynamic_sensitive_fields?

          memo = _contract_redaction
          memo.static_shape_paths ||= _derive_sensitive_shape_paths(nil)
        end

        # Over the arrays the memo is keyed on, for the reason `_sensitive_candidate_configs` gives.
        def _derive_sensitive_shape_paths(action_instance)
          memo = _contract_redaction
          (memo.internals + memo.externals + memo.subfields).filter_map do |config|
            shape = Internal::ShapeGraph.shape_in(config.validations)
            next unless shape && _shape_has_sensitive_member?(shape, action_instance)

            wire_path = config.subfield? ? _resolved_subfields.index[config]&.wire_path : [config.field]
            next unless wire_path

            [wire_path, shape]
          end
        end

        # The ambient analog of `_sensitive_shape_paths`: `[(wire_path_within_ambient, shape)]` for
        # every ambient subfield whose shape carries a sensitive member. Ambient shapes are leaf nodes
        # (`_check_ambient_shape_placement!`), so their value is copied whole and may be a non-Hash the
        # ParameterFilter can't descend into — this feeds `_mask_unfilterable_shapes` to mask it. The
        # ambient tree's wire paths are rooted at the synthetic `:ambient_context` segment; drop it,
        # since the mask applies to the ambient VALUE the reader returns, not a hash wrapped under an
        # `:ambient_context` key.
        def _sensitive_ambient_shape_paths(action_instance)
          return _derive_sensitive_ambient_shape_paths(action_instance) if _has_dynamic_sensitive_fields?

          memo = _contract_redaction
          memo.static_ambient_shape_paths ||= _derive_sensitive_ambient_shape_paths(nil)
        end

        def _derive_sensitive_ambient_shape_paths(action_instance)
          _ambient_subfield_tree.index.filter_map do |config, path|
            shape = Internal::ShapeGraph.shape_in(config.validations)
            next unless shape && _shape_has_sensitive_member?(shape, action_instance)

            [path.wire_path.drop(1), shape]
          end
        end

        # Walk `wire_path` through `value` — Hash keys in either symbol or string form (extraction
        # accepts both), mapping across arrays — and mask the shaped value at the leaf. Every present
        # key form is masked (see `_present_key_variants`); an absent key is left alone. A non-Hash,
        # non-Array intermediate with path still remaining is an object-backed parent (a `method_call:`
        # subfield reads the sensitive shape off it) that ParameterFilter can't descend into — mask it
        # wholesale rather than leak the sensitive member nested inside; a nil/scalar intermediate is
        # preserved (nothing to reach or leak).
        # The Hash branch consumes a path segment per level so it always terminates; the Array branch
        # maps with the path UNCHANGED, so a self-referential array would recurse until the stack
        # blows. A revisited array masks wholesale (not the `[...]` placeholder, which would be a
        # placeholder String masquerading as data) — the same over-redact-rather-than-leak call as
        # `_mask_opaque_or_preserve`, since we cannot descend to redact the sensitive member inside.
        def _mask_value_at_path(value, wire_path, shape, action_instance, seen = nil)
          return _mask_shape_value(value, shape, action_instance) if wire_path.empty?

          if value.is_a?(Array)
            return Axn::Internal::CycleGuard.guard(value, seen, on_cycle: SENSITIVE_FILTERED_MASK) do |nested|
              value.map { |element| _mask_value_at_path(element, wire_path, shape, action_instance, nested) }
            end
          end
          return _mask_opaque_or_preserve(value) unless value.is_a?(Hash)

          _present_key_variants(value, wire_path.first).reduce(value) do |acc, key|
            acc.merge(key => _mask_value_at_path(acc[key], wire_path.drop(1), shape, action_instance, seen))
          end
        end

        # A non-Hash/Array value in a member-bearing position. `nil` is preserved — it is valid absent
        # data (a nil-tolerant shape) with nothing to leak, and masking it would make absent data look
        # redacted. Anything else is malformed for a shaped field (which expects a Hash/object with
        # members) and ParameterFilter can't redact into it: a structured object could expose the member
        # via `inspect`, and a bare scalar could itself BE the sensitive value the caller mis-supplied
        # (`items: ["111-11-1111"]`). Both reach logging before validation rejects them, so mask.
        def _mask_opaque_or_preserve(value)
          value.nil? ? value : SENSITIVE_FILTERED_MASK
        end

        # Every form of `key` present in `hash` — the key as-is, its string form, and its symbol form.
        # Extraction accepts symbol and string keys (reading symbol-first) and a member/wire-path name
        # may be declared in either form, so a single logical key can appear under more than one form in
        # the same Hash; mask them all, since every form is logged and any could hold the secret.
        def _present_key_variants(hash, key)
          [key, key.to_s, key.to_s.to_sym].uniq.select { |variant| hash.key?(variant) }
        end

        # Whether a shape tree carries a `sensitive:` member anywhere (direct, or in a nested shape).
        # A nil action_instance (async reporting, no instance to resolve a dynamic predicate against)
        # counts only static `sensitive: true`, matching the static `inspection_filter` used there.
        # Bounded for the same reasons as `_flatten_sensitive_candidates`. The cycle answer is exact rather than
        # defensive: a cyclic branch re-reaches the very members the enclosing frame is already testing, so
        # answering `false` for it decides nothing on its own and no `sensitive:` member can hide in one. The
        # depth answer cannot be exact, so it is fail-safe instead (see below).
        def _shape_has_sensitive_member?(shape, action_instance, seen = nil, depth = 0)
          # Past the depth bound the answer is TRUE, not false: a graph that deep is one minting fresh nested
          # shapes on every read, so nothing can enumerate what is inside it — and the fail-safe answer for
          # redaction is "assume a secret", which masks the value wholesale rather than logging it in the clear.
          # Unreachable for a declared graph, since the declaration walk rejects one this deep.
          return true if depth > Internal::ShapeGraph::MAX_NESTING

          Axn::Internal::CycleGuard.guard(shape, seen, on_cycle: false) do |open|
            Internal::ShapeGraph.members(shape).any? do |member|
              _member_sensitive?(member, action_instance) ||
                (_member_shape(member) && _shape_has_sensitive_member?(_member_shape(member), action_instance, open, depth + 1))
            end
          end
        end

        def _member_sensitive?(member, action_instance)
          sensitive = _config_sensitive(member)
          return sensitive == true if action_instance.nil?

          _resolve_sensitive_value(sensitive, action_instance)
        end

        # The shape a config or member carries, or nil when it carries none — read without dispatching
        # anything a raw `shape:` kwarg's objects can define (see Internal::ShapeGraph), so a member
        # lying about its type or its readers cannot hide a nested shape from a walk that reflection,
        # validation and redaction all still descend into.
        def _member_shape(member) = Internal::ShapeGraph.nested_shape(member)

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

        # How a message names a shape member: its declared name when it has one, else its class. Never
        # its `inspect` — that is the member's own code running while the failure is being reported, and
        # an exception from it would replace the declaration error (escaping every rescue when it is
        # outside StandardError). A member with no `#field` has no name to print, and its class is the
        # only thing left that identifies it.
        #
        # `name` is passed in rather than read here, and every caller reads it on the way DOWN, before it
        # has a failure to report. Re-reading it here would be the same hazard as `inspect` one step
        # removed: a reader that raises (or answers differently) on a second read replaces the declaration
        # error with the caller's exception — verified against a member whose `field` raises the second time
        # it is called.
        def _describe_shape_member(member, name)
          return "of class #{Axn::Internal::ClassName.of(member)}" if Internal::ShapeGraph.missing?(name)

          "`#{_shape_member_label(name)}`"
        end

        # A shape member's name is an object property in the reflected schema on exactly the same terms as a
        # field's, so it carries the same promise. Walks RESOLVED members rather than checking inside
        # ShapeBuilder because the `do…end` form routes through `_build_shape_member` but a raw `shape:`
        # kwarg supplies pre-built members that never do — the same reason
        # `_reject_outbound_shape_user_facing!` walks. Recursion covers a member's own nested block.
        #
        # A member that answers to no `#field` is rejected rather than skipped. The documented member contract
        # is `#field` PLUS `#validations`, and runtime validation reads `member.field` for every member it
        # validates — so a nameless member declared cleanly, reflected as nothing at all, and then raised
        # NoMethodError on the first call. Skipping it in the guard while the consumer dispatches it anyway is
        # the guard/consumer divergence this walk exists to eliminate. What the tolerance was ever for is the
        # opposite direction: a member that DEFINES `field` cannot escape the check by denying the reader,
        # decided from the real method table (see Internal::ShapeGraph), because reflection reads that name
        # regardless and the two must agree.
        #
        # This is the first shape walk on every declaration path, so it is where an untraversable graph is
        # rejected on behalf of all of them: a graph reaching validation, reflection or redaction has
        # already been rejected here if it is untraversable AS READ. What no declaration-time walk can
        # promise is a graph that answers a LATER read differently — a `[]` or a reader giving two answers
        # is a caller contradicting itself, not a guard missing something (see Internal::ShapeGraph).
        #
        # `via`/`via_name` name the member whose nested shape is being entered — the name captured on the
        # way down, never re-read while a failure is being reported.
        #
        # Two ways a graph can be untraversable, and each needs its own answer. A graph that CONTAINS
        # itself repeats an object, which `CycleGuard` detects by identity. A graph that GENERATES itself —
        # a shape Hash whose `[]` builds a fresh nested shape on every read — never repeats an object, so
        # no identity guard can see it; it is infinitely deep rather than cyclic, and only a depth cap
        # stops it. Both otherwise end in SystemStackError, outside StandardError, escaping every rescue.
        # THE declaration walk over a caller-supplied shape graph, and the only one: it rejects what cannot be
        # declared and copies what can, in a single pass. Returns the copy, which the caller stores as the
        # declared shape.
        #
        # Fused rather than a check pass followed by a copy pass, because the two have to agree about what the
        # members ARE: a list that answers a second `each` differently would leave the class holding members no
        # check ever saw.
        #
        # It also bounds the graph's SIZE, in member paths (see ShapeGraph::MAX_MEMBER_PATHS) — deliberately not
        # in emitted JSON properties, which is a different limit belonging to reflection, derived from what the
        # emitter emits, and applied at projection. This one is about the graph itself: the walks that read a
        # stored graph on a live call have no per-reference memo, so a graph that multiplies out costs the CALL.
        # Counting it here is what keeps that knowable at declaration, where the author is present.
        #
        # So a caller's members list is read exactly ONCE per declaration, and the answer it gave is the
        # contract: a list that would answer a later read differently never gets that read. What it cannot do is
        # decline the first one — the declaration is not knowable without it — so a list that raises on being
        # read raises at declaration, which is the intended outcome and the right one: the author is standing
        # there, rather than the failure landing on whoever first reflects the class.
        def _validate_and_snapshot_shape!(shape, fields)
          _walk_shape_graph!(shape, nil, [Internal::ShapeGraph::MAX_MEMBER_PATHS, fields]).copy
        end

        # Stores the copy in place of the caller's shape, and only when there is one to copy: a field that
        # declared no `shape:` must not gain the key here, and a `shape:` that is not a Hash is left exactly as
        # it came for the container check to reject.
        def _snapshot_declared_shape!(validations, fields)
          shape = Internal::ShapeGraph.hash_or_nil(validations[:shape])
          return if nil.equal?(shape)

          validations[:shape] = _validate_and_snapshot_shape!(shape, fields)
        end

        # What one walked shape yields. The path count travels with the copy because a shape REUSED by two
        # members is walked (and copied) once but COUNTED twice: sharing is exactly how a graph multiplies out,
        # so the second reference charges the whole total its subtree expands to.
        WalkedShape = Data.define(:copy, :paths)
        private_constant :WalkedShape

        # The remaining allowance, and the fields to name if it runs out — a two-element Array rather than an
        # object, because it is threaded through every level of one walk and the label is only ever built on the
        # failure path.
        def _spend_paths!(allowance, paths)
          allowance[0] -= paths
          return unless allowance[0].negative?

          _raise_too_many_member_paths!(allowance[1])
        end

        def _raise_too_many_member_paths!(fields)
          raise ArgumentError,
                "the shape on #{_inspect_field_name(fields.first)} has more than " \
                "#{Internal::ShapeGraph::MAX_MEMBER_PATHS} member paths — a nested shape object reused by " \
                "sibling members multiplies out, so N levels of two-way sharing are 2^N distinct paths, and " \
                "every walk of the stored graph pays one step per path: runtime validation walks it on each " \
                "call, and redaction re-walks it per logged call whenever a `sensitive:` resolves against the " \
                "action (measured: 786,000 paths cost about 1.3 seconds per log line, and about two seconds " \
                "for the one derivation any contract makes on its first). Give each member its own nested " \
                "shape, or flatten the nesting. This is a bound on the graph, not on what a schema emits — an " \
                "oversized SCHEMA is reported separately, when a projection is first built."
        end

        def _walk_shape_graph!(shape, walk, allowance, via: nil, via_name: nil)
          hash = Internal::ShapeGraph.hash_or_nil(shape)
          # Not a shape, so it has no members to walk and nothing to copy — returned as it came, for the
          # container check downstream to reject.
          return WalkedShape.new(copy: shape, paths: 0) if nil.equal?(hash)

          walk ||= ShapeWalk.new(seen: nil, walked: {}.compare_by_identity, depth: 0)
          walked = walk.walked[hash]
          unless nil.equal?(walked)
            _spend_paths!(allowance, walked.paths)
            return walked
          end

          _raise_shape_too_deep!(via, via_name) if walk.depth > Internal::ShapeGraph::MAX_NESTING

          # Read as SUPPLIED, so a shape that names no members is told apart from one naming an empty list.
          members = Internal::ShapeGraph.declared_members(hash)
          _raise_missing_shape_members!(via, via_name) if nil.equal?(members)

          walked = Axn::Internal::CycleGuard.guard(hash, walk.seen, on_cycle: CYCLIC_SHAPE) do |nested|
            _check_and_copy_shape_members!(hash, members, walk.with(seen: nested), allowance)
          end
          _raise_cyclic_shape!(via, via_name) if CYCLIC_SHAPE.equal?(walked)

          walk.walked[hash] = walked
          walked
        end

        # The state one walk carries. `seen` is the ANCESTRY set `CycleGuard` pushes and pops, which is what
        # makes a diamond (one nested shape reused by two siblings) legal rather than a false cycle.
        # `walked` is the complement: shapes already walked to completion, which never need walking again —
        # without it, that same legal diamond costs 2^depth walks (measured: 18 levels took 1.4s, 22 took
        # 22s), so a generated-but-honest schema with shared sub-shapes hung at class definition. Keyed by
        # identity, per declaration, and populated only AFTER a shape has passed, so a memoized entry always
        # means "already verified" — and carries that shape's copy, so a shape reused by two members is read
        # from the caller once and both members store the one copy. A shape that answers a later read
        # differently is the inconsistent-reader limit above, not something re-walking would have caught.
        ShapeWalk = Data.define(:seen, :walked, :depth)
        private_constant :ShapeWalk

        # Sentinel for "this shape was already open on the path" — a private object rather than a value a
        # declaration could produce, so nothing a caller supplies can be mistaken for it, and identity is
        # asked of the sentinel so no caller's `equal?` is dispatched.
        CYCLIC_SHAPE = Object.new.freeze
        private_constant :CYCLIC_SHAPE

        # One node: its members checked, counted, and copied. Each member's name is read exactly ONCE, into a
        # (member, name) pair, and every later use of it — a collision message, a cycle or depth report against
        # a nested shape, the copy stored for it — reads that capture rather than the member again. Same reasoning
        # as the renderer's one-#to_s-per-key rule: a second read may disagree with the first or raise something
        # that is not even a StandardError, replacing the diagnosis with the escape these guards exist to prevent.
        #
        # Reading the name once is not enough on its own, because CANONICALIZING it is a second dispatch on the
        # same caller object: a String subclass whose `to_sym` answers `:alpha` and then `:collide` gave the
        # duplicate check one property name and `ShapeConfig`'s constructor another, so two declared members were
        # stored under one property, `member_properties` emitted one, and nothing raised. So the canonical Symbol
        # is computed once too, beside the check that judges it, and threaded to the snapshot — which is what
        # makes "the guard judged the property this member is stored under" true rather than probable.
        def _check_and_copy_shape_members!(hash, members, walk, allowance)
          named = members.map { |member| [member, Internal::ShapeGraph.fetch(member, :field)] }
          named.each { |member, name| _raise_nameless_member!(member, name) if Internal::ShapeGraph.missing?(name) }
          names = named.map { |_member, name| name }
          # Ahead of every other name check: a name that is not a String or a Symbol has two independent
          # renderings rather than one property (see Contract.validate_shape_member_name!), so asking whether
          # it is renderable, or whether it collides, would be asking about only one of them. A ShapeConfig
          # was already held to this in its constructor; a duck-typed member reaches it only here.
          names.each { |name| Contract.validate_shape_member_name!(name) }

          # Only the SAME key declared twice in one block is judged here — keyed by `to_sym`, which is exactly
          # what `Schema#member_properties` keys a member's property by, so the two agree about what "the same
          # member" is. Two members whose names merely CANONICALIZE alike are two distinct keys at one node,
          # which is a property collapse rather than a repeat declaration, and the one claim space judges every
          # such collapse (`_reject_colliding_property_claims!`) so no mechanism pair can slip between checks.
          # This one cannot move there: two identical claims are a legal MERGE by that rule, while two
          # identical members of one block are a genuine duplicate.
          #
          # The key each member is judged under is CAPTURED here (into a (member, name, key) triple) and stored
          # as that member's `field`, rather than converted again downstream — see the note above. Computed
          # inside this loop rather than in a pass of its own so the order of failures is unchanged: a name whose
          # `to_sym` raises (bytes with no Symbol, say) is still reached after every earlier member has been
          # judged, so a duplicate declared ahead of it is still reported as the duplicate it is.
          claimed = {}
          keyed = named.map do |member, name|
            key = name.to_sym
            _raise_duplicate_member!(name) if claimed.key?(key)

            claimed[key] = name
            [member, name, key]
          end

          child = walk.with(depth: walk.depth + 1)
          paths = 0
          copied = keyed.map do |member, name, key|
            # Charged BEFORE this member is snapshotted, and before its nested shape is walked, so a graph that
            # multiplies out is rejected while the work done on it is still bounded by the allowance.
            _spend_paths!(allowance, 1)
            paths += 1
            # `validations` is read ONCE and threaded to every use — the nested shape to walk, and the snapshot
            # of this member. A second read is a second answer the caller can give.
            validations = _symbol_keyed_member_validations(member, name)
            _raise_member_without_validations!(member, name) if nil.equal?(validations)
            # Every other attribute read (and grammar-checked) BEFORE the nested walk, so a member carrying both
            # a bad `sensitive:` and an untraversable nested shape is reported as the value defect it is.
            attributes = _snapshot_member_attributes!(member, name, key, validations)
            nested = Internal::ShapeGraph.hash_or_nil(validations[:shape])
            unless nil.equal?(nested)
              inner = _walk_shape_graph!(nested, child, allowance, via: member, via_name: name)
              paths += inner.paths
              validations[:shape] = inner.copy
            end
            ShapeConfig.new(**attributes)
          end

          WalkedShape.new(copy: Internal::ShapeGraph.snapshot_node(hash, copied), paths:)
        end

        # Everything a stored member carries, read off the caller's object exactly ONCE and held to its grammar
        # on the way — so what the class stores is axn's own `ShapeConfig` and the caller keeps nothing live in a
        # declared contract. Read through `ShapeGraph`, so a member that denies a reader it defines is still held
        # to the rules, and the value snapshotted is the one that reader gives.
        #
        # Snapshotting rather than storing the object is what makes "the contract is what you declared" true for
        # a member too: a retained member's `sensitive:` could be flipped after the class was declared (changing
        # what redaction masked, or not, depending only on whether anything had asked yet), its canonicalized
        # `validations` were computed and then thrown away (so a String-keyed `type:` bag validated nothing and
        # reflected nothing), its option containers stayed aliased where a field's were detached, and the nested
        # shape it carried could gain members or be pointed at itself afterwards.
        #
        # The grammars for `sensitive:`/`user_facing:` are checked HERE, ahead of `ShapeConfig`'s constructor,
        # only so the error keeps its place in this walk's order; the constructor enforces the same rules for the
        # block form, where it is the first thing to see them. A falsey `user_facing:` is "not opted in" and has
        # no grammar to meet — `nil` is what an absent reader answers.
        #
        # `description` is read directly rather than taken from `metadata`, because that is where reflection
        # reads it from (`Schema.declared_attribute`) and a duck-typed member may define the reader without any
        # metadata at all; folding it into the metadata Hash is what `ShapeConfig#description` then answers with.
        #
        # `name` and `key` are the same name in its two roles: `name` is what a message about this member RENDERS
        # (a raw String keeps the spelling the caller wrote, and an unrenderable one its escaped form), while
        # `key` is the canonical Symbol the duplicate check already judged — and so the property this member is
        # stored, validated and emitted under. Both come from the one read; nothing here converts either again.
        def _snapshot_member_attributes!(member, name, key, validations)
          sensitive = Internal::ShapeGraph.read(member, :sensitive)
          Contract.validate_sensitive!(sensitive)
          user_facing = Internal::ShapeGraph.read(member, :user_facing)
          Contract.validate_user_facing!(user_facing) if user_facing

          metadata = _symbol_keyed_member_metadata(member, name) || {}
          description = Internal::ShapeGraph.read(member, :description)
          metadata[:description] = description unless nil.equal?(description)

          { field: key, validations:, metadata:, sensitive: sensitive || false, user_facing: user_facing || false,
            method_call: Internal::ShapeGraph.read(member, :method_call) || false }
        end

        # A shape graph that contains itself has no traversal at all: every walk over it — this one, the
        # runtime validator's, the schema's — recurses until the stack overflows, and SystemStackError is
        # outside StandardError, so it escapes every rescue in the framework rather than settling into a
        # reported failure. Rejected at declaration, where it is knowable and where the author is present.
        def _raise_cyclic_shape!(member, name)
          via = nil.equal?(member) ? "" : " reached from shape member #{_describe_shape_member(member, name)}"
          raise ArgumentError,
                "a `shape:` graph cannot contain itself — the nested shape#{via} is the same shape it is nested " \
                "inside, so validating or reflecting it would recurse until the stack overflows. Give the nested " \
                "shape its own members rather than reusing the shape (or the member) that encloses it."
        end

        # The generative counterpart: no object repeats, so nothing identifies a loop, and the graph is
        # simply endless. Capped rather than walked to exhaustion, for the same reason a cycle is rejected
        # — the alternative outcome is a SystemStackError raised while the class is being defined, which
        # no rescue in the framework can settle.
        def _raise_shape_too_deep!(member, name)
          via = nil.equal?(member) ? "" : " at shape member #{_describe_shape_member(member, name)}"
          raise ArgumentError,
                "a `shape:` graph nested more than #{Internal::ShapeGraph::MAX_NESTING} levels deep#{via} is almost certainly " \
                "generated rather than declared — no hand-written shape block reaches that depth, while a shape " \
                "object that builds a fresh nested shape on every read is endless and would recurse until the " \
                "stack overflows. Have the shape return the same finite nested shape each time it is read, or " \
                "flatten the nesting."
        end

        # A member's declared validations, symbol-canonical at BOTH levels its grammar has: the validator names,
        # and each validator's own option bag (see _symbolize_option_bags!, which does the same for a field).
        # A raw `shape:` member bypasses `expects`' option handling entirely, so this is the one place its
        # grammar gets canonicalized — and it must, because what the snapshot stores is a plain Hash: a member
        # declared with String keys otherwise validated nothing at all, silently, and reflected an empty
        # constraint beside it.
        def _symbol_keyed_member_validations(member, name)
          validations = Internal::ShapeGraph.hash_or_nil(Internal::ShapeGraph.read(member, :validations))
          return nil if nil.equal?(validations)

          # A Hash axn owns, ALWAYS — canonicalized and copied in one pass. "Needs no key change" and "needs no
          # copy" are different questions, and answering only the first left a member's options aliased to the
          # objects the caller still held while a top-level field's were detached: mutating an `inclusion:` list
          # afterwards widened a declared member's enum. The copy is also what the snapshot stores, so it is one
          # allocation rather than two.
          copy = {}
          Internal::ShapeGraph.each_entry(validations) do |key, value|
            canonical = case key
                        when ::String then key.to_sym
                        else key
                        end
            _raise_ambiguous_option_key!("the validations of #{_member_owner_label(member, name)}", canonical) if copy.key?(canonical)

            copy[canonical] = value
          end
          # Each bag's own keys, then the containers themselves — through the same two helpers a field's options
          # go through, in the same order, so a member is held to exactly what a field is held to: an
          # `inclusion:` list keeps its class, and a container that answers with code of its own is refused
          # unless it is frozen.
          _symbolize_option_bags!(copy)
          _detach_option_containers!(copy)
          copy
        end

        def _member_owner_label(member, name) = "shape member #{_describe_shape_member(member, name)}"

        # Metadata is one level of grammar (`description:` and whatever an extension registered), read as
        # Symbols — `ShapeConfig#description` is `metadata[:description]` — so a String-keyed metadata Hash
        # silently loses every entry it holds.
        def _symbol_keyed_member_metadata(member, name)
          metadata = Internal::ShapeGraph.hash_or_nil(Internal::ShapeGraph.read(member, :metadata))
          return nil if nil.equal?(metadata)

          # Canonicalized WHILE being copied, in one pass: metadata is copied either way (what is stored IS the
          # contract — see `_snapshot_member_attributes!`), so asking about its keys separately would be a second
          # pass over every member for nothing.
          copy = {}
          Internal::ShapeGraph.each_entry(metadata) do |key, value|
            canonical = case key
                        when ::String then key.to_sym
                        else key
                        end
            _raise_ambiguous_option_key!("the metadata of #{_member_owner_label(member, name)}", canonical) if copy.key?(canonical)

            copy[canonical] = value
          end
          copy
        end

        # Named by class, since it has no name — through `_describe_shape_member`, so nothing of the member's
        # own runs while the declaration error is being built.
        def _raise_nameless_member!(member, name)
          raise ArgumentError,
                "a shape member must answer to `field`, naming the key it validates — the member " \
                "#{_describe_shape_member(member, name)} answers to none. Runtime validation reads " \
                "`member.field` for every member, so such a member would validate nothing, be omitted from " \
                "the reflected schema entirely, and raise NoMethodError on the first call. Give it a `field` " \
                "reader (with `validations`, the rest of the member contract), or declare it with " \
                "`field :name` inside a `shape` block."
        end

        # A shape is a container plus the members that describe what is inside it, so a raw one that names no
        # members list at all is malformed — it declares a shaped field nothing describes. It used to be caught
        # on the first CALL (`ShapeValidator#check_validity!` refuses a nil members list); rejecting it here is
        # strictly earlier and is where every other malformed declaration is answered.
        #
        # An empty list is NOT this: `members: []` is a real declaration (the container type still constrains the
        # value), pointless rather than wrong, and axn's business is not to refuse it.
        def _raise_missing_shape_members!(member, name)
          via = nil.equal?(member) ? "" : " at shape member #{_describe_shape_member(member, name)}"
          raise ArgumentError,
                "a raw `shape:`#{via} must supply `members:` — a shape describes what is inside a container, so " \
                "one with no members list constrains nothing beyond the container type, and runtime validation " \
                "has nothing to validate against. Supply `members: [...]` (an empty list is accepted, if " \
                "pointless), or declare the shape with a `do … end` block, which builds the members list for you."
        end

        # The other half of the documented member contract (see _raise_nameless_member!): runtime validation
        # reads `member.validations` for every member it validates — repeatedly, and dispatched directly — so a
        # member that answers to `field` but not `validations` declared cleanly and then raised NoMethodError on
        # the first call. `validations: {}` is the honest spelling of "constrains nothing".
        def _raise_member_without_validations!(member, name)
          raise ArgumentError,
                "a shape member must answer to `validations` as well as `field` — the member " \
                "#{_describe_shape_member(member, name)} answers to `field` only. Runtime validation reads " \
                "`member.validations` for every member, so such a member would raise NoMethodError on the first " \
                "call. Give it a `validations` reader (`{}` when it constrains nothing), or declare the member " \
                "with `field :name` inside a `shape` block."
        end

        # The same member key declared twice in one block. No comparison of the two names is needed — and so
        # none is made: they arrived under one `to_sym` key, which is the identity the schema itself uses, so
        # nothing a name's class can define (an `==` that raises) is dispatched to reach this conclusion.
        def _raise_duplicate_member!(offending)
          raise Axn::DuplicateFieldError,
                "Duplicate shape member declared: #{_inspect_field_name(offending)} — two members of one shape would " \
                "validate the same key, and the reflected schema would keep only the last. Declare each member once."
        end

        # Whether two colliding names are the same SPELLING — decided while a failure is already being
        # reported, so without dispatching `==` (or anything else) on a name. A member name may be a
        # caller-supplied String subclass, and its `==` can raise in place of the duplicate error being
        # built, escaping every rescue when what it raises is outside StandardError.
        #
        # Dispatch on the shape's container — the value must match it, or it's malformed (and reaches
        # logging before validation rejects it, so its arbitrary contents could leak). An `Array` shape
        # maps each element (member-bearing); a `Hash` shape filters the Hash's member keys; a class
        # (Data/Struct/PORO) shape reads members off an object ParameterFilter can't descend into. Any
        # value whose type doesn't match the container is masked wholesale rather than treated as a lone
        # valid element/Hash — only declared member keys would be filtered, leaking arbitrary siblings.
        # `nil` (valid absent data) is preserved throughout via `_mask_opaque_or_preserve`.
        #
        # The container is compared by IDENTITY rather than with `==`: a raw `shape:` kwarg may supply any
        # object there, and `container == Array` dispatches that object's own `==` — one answering true for
        # both arms, or raising, would decide which redaction path a secret takes. `Array`/`Hash` are the
        # receivers, so only their own `equal?` runs.
        def _mask_shape_value(value, shape, action_instance)
          container = shape[:container]
          if ::Array.equal?(container)
            return value.map { |element| _mask_shape_element(element, shape, action_instance) } if value.is_a?(Array)

            return _mask_opaque_or_preserve(value)
          end
          return _mask_shape_element(value, shape, action_instance) if ::Hash.equal?(container)

          _mask_opaque_or_preserve(value)
        end

        # A non-Hash value where members are expected is opaque to ParameterFilter → mask it whole. A Hash
        # keeps its own keys (ParameterFilter redacts the sensitive ones); only recurse into a nested-shape
        # member's value when that nested shape actually carries a sensitive member, to avoid needless
        # masking of an unrelated non-Hash deeper down. The member key is matched in either symbol or
        # string form, since extraction accepts both.
        def _mask_shape_element(element, shape, action_instance)
          return _mask_opaque_or_preserve(element) unless element.is_a?(Hash)

          _sensitive_nested_members(shape, action_instance).each_with_object(element.dup) do |(member, nested), masked|
            _present_key_variants(masked, member.field).each do |key|
              masked[key] = _mask_shape_value(masked[key], nested, action_instance)
            end
          end
        end

        # The `[(member, nested_shape)]` pairs a mask has to descend into: the members of `shape` whose OWN
        # nested shape carries a sensitive member. Memoized per shape (by identity) on the same condition as
        # `_sensitive_shape_paths` — no `sensitive:` resolving against the action — because for the ordinary
        # flat shape the answer is EMPTY, and finding that out cost a `nested_shape` read (a bound-Method
        # allocation each) for every member of the shape, on every value masked.
        def _sensitive_nested_members(shape, action_instance)
          return _derive_sensitive_nested_members(shape, action_instance) if _has_dynamic_sensitive_fields?

          _contract_redaction.nested_members_for(shape) { _derive_sensitive_nested_members(shape, nil) }
        end

        def _derive_sensitive_nested_members(shape, action_instance)
          Internal::ShapeGraph.members(shape).filter_map do |member|
            nested = _member_shape(member)
            next unless nested && _shape_has_sensitive_member?(nested, action_instance)

            [member, nested]
          end
        end

        # The names of the `sensitive:` members reachable inside one shape-bearing config's value — the flat
        # key set `inspect` hands to a `ParameterFilter`, since a member redacts by NAME wherever it appears
        # (every array element, any nesting depth), unlike the precise wire path a subfield contributes.
        # Memoized on the same condition as `_sensitive_shape_paths` — no `sensitive:` resolving against the
        # action — since `inspect` asks it once per displayed field, and the walk covers the whole stored graph.
        #
        # Lives here rather than with the inspector because it is a question about the CONTRACT, and because
        # sensitivity is read through `_config_sensitive` — the same seam logging reads — so a member that
        # defines `sensitive:` cannot escape redaction in `inspect` by denying the reader while logging
        # redacts it anyway.
        def _sensitive_member_names(config, action_instance)
          return _derive_sensitive_member_names(config, action_instance) if _has_dynamic_sensitive_fields?

          _contract_redaction.member_names_for(config) { _derive_sensitive_member_names(config, nil) }
        end

        # Bounded both ways, exactly as `_flatten_sensitive_candidates` is, and for its reason: a config assigned
        # onto a class rather than declared carries a shape no walk has traversed, which can be pointed at itself
        # (which `CycleGuard` sees) or mint a fresh one on every read (which nothing but depth sees). `inspect` is
        # reachable directly, not only from a side channel, so an unbounded walk here raises SystemStackError at
        # the caller rather than degrading a log line.
        #
        # A cycle re-reaches members an enclosing frame is already collecting, so stopping loses nothing.
        # Past the depth bound nothing can enumerate a graph that mints its members on demand — and the
        # value it describes is masked wholesale by then anyway (`_shape_has_sensitive_member?` answers true
        # past the same bound), so `inspect` shows a redacted value rather than a leaked one.
        def _derive_sensitive_member_names(config, action_instance, seen = nil, depth = 0)
          shape = Internal::ShapeGraph.shape_in(config.validations)
          return [] if nil.equal?(shape) || depth > Internal::ShapeGraph::MAX_NESTING

          Axn::Internal::CycleGuard.guard(shape, seen, on_cycle: []) do |open|
            # Through the shared seam, for the reason _flatten_sensitive_candidates gives: a list hiding
            # itself from `flat_map` would drop a sensitive member from the redaction set.
            Internal::ShapeGraph.members(shape).flat_map do |member|
              names = _derive_sensitive_member_names(member, action_instance, open, depth + 1)
              names << member.field if _member_sensitive?(member, action_instance)
              names
            end
          end
        end

        # Private, though declared next to their definitions rather than relocated below: these are
        # declaration-time internals of the shape-member walk, called only with an implicit receiver (from here
        # and from ContractForSubfields, which is extended onto the same class). Kept in place so each stays
        # beside the walk it belongs to, with its comment.
        #
        # Only these — the ones this PR added. The other leading-underscore public class methods are
        # `class_attribute` accessors and long-standing declaration hooks the framework and downstream gems
        # already reach; narrowing those is a separate, breaking question.
        private :_spend_paths!, :_raise_too_many_member_paths!, :_symbol_keyed_member_validations,
                :_symbol_keyed_member_metadata, :_snapshot_member_attributes!,
                :_member_owner_label, :_describe_shape_member,
                :_snapshot_declared_shape!, :_validate_and_snapshot_shape!, :_walk_shape_graph!,
                :_check_and_copy_shape_members!, :_raise_cyclic_shape!, :_raise_shape_too_deep!,
                :_raise_duplicate_member!, :_raise_nameless_member!,
                :_raise_missing_shape_members!, :_raise_member_without_validations!

        private

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
          key_for = ->(c) { [c.on.to_s, Axn::Reflection::Values.canonical_wire_key(c.field)] }

          claimed = existing.reject { |c| key_for.call(c).last.nil? }.to_h { |c| [key_for.call(c), c.field] }
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
        def _reject_duplicate_fields!(existing, new_configs)
          collisions = _duplicate_fields(existing, new_configs)
          return if collisions.empty?

          identical, collapsed = collisions.partition { |claimed, offending| claimed == offending }
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

        # The mask a sensitive value is replaced with — matches `ActiveSupport::ParameterFilter`'s default
        # so wholesale-masked values read identically to per-key-filtered ones.
        SENSITIVE_FILTERED_MASK = "[FILTERED]"

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

          # `model:` resolves a record from an id and exposes a `<field>_id` companion reader — both live
          # in the reader/facade layer a reader-less member never routes through, so on a member it would
          # only type-check the element in place (what `type: Klass` already does) while implying
          # resolution/companion behavior that never happens. Reject it loudly rather than accept the
          # degenerate form, pointing at the plain-type-check alternative.
          if opts.key?(:model)
            # The companion reader is named off the message-safe label too, so the `_id` name it reports is
            # derived from the same rendering of the member name the sentence already used.
            label = _shape_member_label(name)
            raise ArgumentError,
                  "shape member `#{label}` does not support model: — a model field resolves a record from an id " \
                  "and exposes a `#{Internal::FieldConfig.model_id_key(label)}` reader, but a shape member is " \
                  "reader-less and validates the element in place (use `type: Klass` for a plain instance check)."
          end

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
        # A contract must not change after the class is declared, and an option value the caller still holds is
        # aliased into it: mutating a `validate:` bag swapped the validator a declared field runs, a mutated `of:`
        # bag changed a declared element type, and appending to an `inclusion:` list widened a declared enum —
        # each after the fact, on a class already defined.
        #
        # Detached one level deep, which is exactly the boundary that matters: the plain Hash/Array CONTAINERS
        # axn stores are copied, while the values inside them stay the caller's objects — a `validate:` callable,
        # a `model:` class, an `inclusion:` member. Those are meant to be the caller's, and copying them would
        # change what a declaration means rather than protect it. `shape:` is excluded because it needs a deep
        # copy of its own (see _validate_and_snapshot_shape!) and gets one downstream.
        # Nothing an option container can define decides whether it is detached, or what the detached copy holds.
        # The type tests are `case`/`when` (`Module#===`, a C-level check) rather than `is_a?`, and the copies are
        # taken through bound primitives (see ShapeGraph) rather than the container's own `transform_values`/`dup`.
        # A subclass answering `is_a?(Array)` with false, or whose `dup` returned `self`, or whose
        # `transform_values` handed back the receiver, otherwise stayed aliased into the declared contract while
        # the plain-Array case beside it was correctly copied. An ARRAY that owns any of those is now refused
        # before the copy is attempted (see _detached_option_array), so the bound `dup` is belt-and-braces there;
        # a BAG is not, since it is copied entry-wise whatever its class, which is what the bound `Hash#each`
        # holds.
        #
        # An Array keeps its CLASS (a same-class `dup`, or the caller's own object when it is already frozen —
        # see _detached_option_array) because its own class is part of what a declaration means — a frozen
        # `inclusion:` set answers membership with its own `include?`, and reflection withholds an enum for
        # anything but an exact Array. A bag becomes a plain Hash — which is what it already became, and axn
        # reads bags with `[]`/`dig` only.
        def _detach_option_containers!(validations)
          validations.each do |key, value|
            next if key == :shape

            case value
            when ::Hash then validations[key] = _detached_option_bag(key, value)
            when ::Array then validations[key] = _detached_option_array(value, "`#{key}:`")
            end
          end
        end

        def _detached_option_bag(key, bag)
          copy = Internal::ShapeGraph.copy_entries(bag)
          copy.each do |option_key, option|
            case option
            when ::Array then copy[option_key] = _detached_option_array(option, "`#{key}: { #{option_key}: … }`")
            end
          end
          copy
        end

        # Three outcomes, and which one a container gets is decided WITHOUT running any of its code.
        #
        # A container axn can copy faithfully by construction is copied, and the copy is the contract. That
        # condition is that the container answers NOTHING with code of its own (`NativeMethods.own_array_methods`
        # is empty): `Kernel#dup` copies the elements, so the copy answers as the original exactly where every
        # answer is a pure function of the elements, which is exactly where every answer is Ruby's own. Every
        # plain Array passes, as does a subclass that adds no methods. A FROZEN container is stored as it is,
        # whatever it owns: the copy exists so that mutating what the caller still holds cannot change a declared
        # contract, and a frozen container cannot be mutated, so there is nothing to detach it from. Anything
        # else is REFUSED at declaration.
        #
        # The refusal is deliberate over-rejection, and it replaces two rounds of verifying the copy and one of
        # gating on the duplication hooks. Comparing the copy's ELEMENTS missed a hook that dropped a derived
        # lookup index the container's own `include?` reads: the elements survived and the copy rejected every one
        # of them. Asking the copy `include?` about each element then missed a hook that dropped only the index of
        # accepted NON-elements — a set holding `"canon"` and aliasing `"alias"` to it accepted both, its copy
        # accepted only `"canon"`, and no element-based probe can see a difference outside the elements. Gating on
        # the duplication HOOKS then missed the copy's other two differences from the original: `dup` shares the
        # instance variables and drops the singleton class, so a membership derived from `self`, from an ivar, or
        # from a singleton method diverges with entirely native duplication (and an ivar-derived one is still the
        # caller's to mutate afterwards, which is the aliasing the copy exists to prevent). Ownership of
        # everything the container answers with is a fact rather than a prediction (see Internal::NativeMethods),
        # and a container that would copy faithfully is over-rejected by it with a bounded way to stay legal:
        # freeze it.
        #
        # Two residues, stated rather than papered over, and both are the same one-level depth the copy promises.
        # A FROZEN container's elements — and whatever its ivars point at — are still the caller's objects, so a
        # frozen container deriving membership from a mutable index can still be widened after the class is
        # declared: freezing promises that axn stores what you froze, and how deep that goes is the author's.
        # And a membership container that is not an Array (a `Set`, a `Range`, an object answering `include?`) is
        # not reached here at all: it is stored as the caller's object, so nothing of axn's answers membership and
        # there is nothing to diverge — but nothing detaches it either. A `Range` is frozen by construction; a
        # `Set` is mutable. Both residues are recorded in `property_name_collision_spec.rb`.
        #
        # The container is named by class and its methods by the method table, never by `inspect` — its own code
        # must not run while the declaration error it caused is being built, and a method name is rendered like
        # any other name reaching prose (a non-UTF-8 one would otherwise raise while the error is built).
        def _detached_option_array(value, label)
          return value if Internal::NativeMethods.frozen?(value)

          own = Internal::NativeMethods.own_array_methods(value)
          return Internal::ShapeGraph.detached_dup(value) if own.empty?

          raise ArgumentError,
                "the #{label} container (of class #{Axn::Internal::ClassName.of(value)}) defines methods of its " \
                "own (#{_describe_own_methods(own)}), so axn cannot copy it. A declared contract is copied at " \
                "declaration so that mutating what you still hold cannot change it — and `dup` copies the " \
                "elements while sharing the instance variables and dropping the singleton class, so the copy " \
                "answers as you declared only where the answer is Ruby's own. What your code answers in the copy " \
                "cannot be established without running it, so a copy that silently rejects the values you " \
                "declared is indistinguishable from a faithful one. Supply a plain Array, or freeze this " \
                "container (a frozen one is stored as-is, since nothing can mutate it afterwards)."
        end

        # The first few offending names, so the author is pointed at the method to move or the object to freeze
        # rather than at a rule. Sorted for a stable message, and capped because a rich subclass has dozens.
        def _describe_own_methods(names)
          shown = names.uniq.sort
          rendered = shown.first(3).map { |name| "`#{_inspect_field_name(name)}`" }.join(", ")
          shown.size > 3 ? "#{rendered}, and #{shown.size - 3} more" : rendered
        end

        def _derive_raw_shape_container!(validations)
          shape = Internal::ShapeGraph.hash_or_nil(validations[:shape])
          return if nil.equal?(shape)

          # Detached ALWAYS, not only when a container has to be derived: deriving one is a write, and what is
          # stored IS the contract, so writing into the caller's own Hash would change a shape they still hold.
          # One level is all this needs — the deep copy, and the bound on how much there is to copy, belong to
          # the single declaration walk (see _validate_and_snapshot_shape!), which is also what captures the
          # members list carried forward here. A shape nested inside a `do…end` block reaches this before that
          # walk, which is exactly why the write must not land on the caller's object.
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

        # This method applies any top-level options to each of the individual validations given.
        # It also allows our custom validators to accept a direct value rather than a hash of options.
        def _parse_field_validations(
          *fields,
          allow_nil: false,
          allow_blank: false,
          **validations
        )
          _detach_option_containers!(validations)
          _canonicalize_blank_gates!(validations)

          # `coerce: <Type>` sugar → a coerce flag inside the type bag (coercion binds to the type;
          # it is meaningless without one). Runs before the type: sugar so the resulting `{ klass: }`
          # hash flows through the normal path.
          _expand_coerce_sugar!(validations)

          # Apply syntactic sugar for our custom validators (convert shorthand to full hash of options)
          validations[:type] = Axn::Validators::TypeValidator.apply_syntactic_sugar(validations[:type], fields) if validations.key?(:type)
          validations[:model] = Axn::Validators::ModelValidator.apply_syntactic_sugar(validations[:model], fields) if validations.key?(:model)
          validations[:validate] = Axn::Validators::ValidateValidator.apply_syntactic_sugar(validations[:validate], fields) if validations.key?(:validate)

          # Validate the coerce target set (covers BOTH the sugar above and an explicit
          # `type: { klass:, coerce: true }`) once the type bag is canonical.
          _validate_coercion!(validations[:type]) if validations[:type].is_a?(Hash) && validations[:type].key?(:coerce)

          if validations.key?(:of)
            declared_klasses = Array(validations.dig(:type, :klass))
            raise ArgumentError, "of: requires type: Array (got #{declared_klasses.inspect})" unless declared_klasses == [Array]

            validations[:of] = Axn::Validators::OfValidator.apply_syntactic_sugar(validations[:of], fields)
            raise ArgumentError, "of: must supply :klass" if validations[:of][:klass].nil?
          end

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
