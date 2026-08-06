# frozen_string_literal: true

require "date"

require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"

require "axn/core/contract/redaction"
require "axn/core/contract/validator_class_cache"
require "axn/core/contract/shape_declaration"
require "axn/core/validation/fields"
require "axn/core/flow/handlers/invoker"
require "axn/internal/coercion"
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

      # Optionality is shared by FieldConfig and ShapeConfig: a field is optional exactly when its
      # validators accept nil. Keyed on the validators rather than on the presence of a `presence: true`
      # entry, so a field that rejects nil by type alone (`allow_empty: true`, `presence: false`) reads as
      # required here and in the schema.
      #
      # This is the same NIL-TOLERANCE question schema reflection asks, and the only requiredness signal
      # here — but schema requiredness ALSO admits a usable `default:` (schema.rb#optional_for_schema?), so
      # a field carrying a literal default no presence check would reject (`default: 1`) is omittable there
      # while reporting non-optional here. Narrowly that one shape: a Proc default is unknowable at
      # declaration and reflects as required, and a blank literal default is rejected by the default
      # `presence: true`, so both of those agree.
      module FieldOptionality
        def optional?
          Axn::Validation::Base.nil_accepted?(validations)
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
      #
      # The three literal arms are decided by `case`/`when` (`Module#===`, a C-level check) rather than by `is_a?`,
      # and the offender is named by CLASS rather than by `inspect`, exactly as the `sensitive:` guard beside it —
      # a declaration guard must not let the value being judged raise INSTEAD of the verdict, and outside
      # StandardError that exception escapes every rescue above. It also closes a divergence: the executor picks
      # the String arm with `case`/`when` too (`_resolve_user_facing_override`), so a value whose own `is_a?`
      # claimed String passed this check and was then rendered as a literal — the failure the guard exists to
      # prevent.
      #
      # The CALLABLE arm cannot be decided that way, and deliberately is not narrowed to `when ::Proc, ::Method`.
      # What may be declared here is what `Handlers::Invoker` will actually invoke, decided by the invoker's own
      # `callable?` so there is no second, divergent predicate — and that set is open-ended duck typing
      # (`to_proc` + `arity`). A `case`/`when` list would reject a custom callable that works today, and asking
      # the method table instead would ACCEPT one whose `respond_to?` answers false, which the invoker would then
      # treat as a literal value and render as the caller's error message. So the dispatch stays and is GUARDED
      # instead: an object that raises while being asked cannot be established as invokable, so it is refused by
      # axn's own error naming its class (see `_invokable_user_facing?`).
      def self.validate_user_facing!(user_facing)
        case user_facing
        when true, false, ::String, ::Symbol then return
        end
        return if _invokable_user_facing?(user_facing)

        raise ArgumentError,
              "user_facing: must be true, a String, a Symbol, or a Proc (got a value of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(user_facing)})"
      end

      # Whether the invoker would run this value as a handler — asked of the invoker itself, so the declaration
      # check and the call-time dispatch can never disagree, with the caller's exception kept from replacing the
      # verdict.
      #
      # `respond_to?` is the caller's to override, and it consults `respond_to_missing?`, which is the caller's
      # too; either raising would surface as the object's own exception in place of the ArgumentError. Refusing is
      # the honest fallback: a value that cannot answer whether it is invokable has not been shown to be a
      # resolution rule, and axn's error names its class safely rather than reporting the object's.
      #
      # The rescue is pinned to the same boundary as everything else axn absorbs
      # (`Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR`), so a signal or another library's control-flow
      # exception still passes through untouched — and it is written as a `rescue` clause rather than
      # `Extensions.swallowable?` because `rescue` matches through `Module#===` while that predicate would ask
      # the exception's own `is_a?`, reintroducing the dispatch one layer down.
      def self._invokable_user_facing?(value)
        Axn::Core::Flow::Handlers::Invoker.callable?(value)
      rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
        false
      end
      private_class_method :_invokable_user_facing?

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
              "class #{Axn::Internal::Reflection::PropertyNames.renderable_class_name(sensitive)}) — any other value is not a redaction rule, and " \
              "a truthy one would silently leave the value logged in the clear rather than raise. Use " \
              "`sensitive: true` to always redact, or a Symbol/Proc predicate to decide per call."
      end

      # A shape member's name has to serve as TWO things: the JSON property it renders as (via `to_s`, which
      # the declaration guard canonicalizes) and the schema property key (via `to_sym`, which
      # Internal::Reflection::Schema#member_properties emits). A String and a Symbol are the only types for which those
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
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(name)}) — a member name is both the JSON " \
              "property it renders as " \
              "and the schema property key it is emitted under, and any other object converts to those two " \
              "independently. Declare the member under a String or Symbol name."
      end

      # An option whose value NAMES something (`Axn::Factory.build`'s `expose_return_as:`, a subfield's `on:`)
      # is canonicalized to a Symbol the moment it is read, so the only values it can carry are the two that
      # have a Symbol as their canonical spelling: a String and a Symbol. Anything else used to be left to the
      # caller's own `to_sym`, and was therefore diagnosed as whatever that happened to raise —
      # `NoMethodError: undefined method 'to_sym' for an instance of Array`, which names neither the option nor
      # what was wrong with the value — the same non-diagnosis as a mistyped option key surfacing at call time
      # as `Unknown validator: 'TpyeValidator'`, and rejected for the same reason.
      #
      # Worse, an exotic object that merely ANSWERS `to_sym` was not diagnosed at all: it silently
      # named whatever its `to_sym` invented, independently of what the object renders as — the
      # two-independent-conversions defect `validate_shape_member_name!` rejects for a member name.
      #
      # Runs AFTER the absent check at each call site, so every spelling of "not supplied"
      # (`nil`, `false`, an empty or whitespace-only String, the empty Symbol) still means the option was
      # omitted rather than hitting a type error — see `Internal::NativeMethods.absent_value?`.
      #
      # `case`/`when` decides the type through `Module#===` (a C-level check) rather than `is_a?`, which a
      # value can override to route around a guard, and the offender is named by CLASS through the renderer
      # rather than by its own `inspect`, exactly as the `sensitive:`/`user_facing:` guards above — a
      # declaration guard must not let the value it is judging raise INSTEAD of the verdict.
      def self.validate_name_option!(value, option:, names:, fix:)
        case value
        when ::String, ::Symbol then return
        end

        raise ArgumentError,
              "#{option} must be a String or Symbol naming #{names} (got a value of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(value)}) — any other object has no single " \
              "name to canonicalize to. #{fix}"
      end

      # A name of the right TYPE can still be written in bytes no declaration can work with. Runs immediately
      # after the type rule above, at every site that takes a name, and BEFORE anything compares the name to
      # anything: the questions a declaration asks — is this path dotted, is this reader reserved — are asked
      # against axn's own ASCII patterns, and a wide encoding (UTF-16, UTF-32) makes the comparison itself
      # raise `Encoding::CompatibilityError` instead of answering. That was the whole diagnosis such a name got:
      # an encoding error from `"a.b".include?(".")`, naming neither the option nor what was wrong with it.
      #
      # Rejected rather than accommodated, because there is no working declaration behind it. The name interns
      # to a Symbol DISTINCT from its UTF-8 twin (`"ab".encode("UTF-16LE").to_sym != :ab`) while canonicalizing
      # to the same JSON property, so the schema advertises `"ab"` and no caller can satisfy it: supplying that
      # property, its Symbol, or the wide Symbol itself each raise from the read path. An ASCII-COMPATIBLE
      # non-UTF-8 name (Latin-N) is a different case entirely and stays legal — it compares, it reads, and it
      # renders as the property it canonicalizes to.
      #
      # The encoding is read from bound base implementations (`NativeMethods.ascii_compatible_name?`) for the same
      # reason the rest of this layer does — a dispatch inside a verdict is a dispatch the verdict did not need —
      # and the encoding is named in the message from `Encoding`'s own object rather than from anything the caller
      # supplied.
      def self.validate_name_encoding!(value, kind:, fix:)
        return if Axn::Internal::NativeMethods.ascii_compatible_name?(value)

        raise ArgumentError,
              "#{kind} must be written in an ASCII-compatible encoding (got one encoded as " \
              "#{Axn::Internal::NativeMethods.name_encoding(value).name}) — a name in a wide encoding interns to a " \
              "different Symbol than the UTF-8 property it renders as, so nothing a caller sends can match it, and " \
              "every check the declaration makes against it raises rather than answering. #{fix}"
      end

      # Canonicalize a declared name to the Symbol every consumer downstream reads, holding both rules first. THE
      # single place a name becomes a Symbol, so the rules and the conversion cannot drift apart — a site that
      # canonicalized on its own is how `as:`, `prefix:` and the field names each ended up with a different answer
      # for the same bad value.
      #
      # Scope, deliberately: these rules serve a name a developer actually WROTE — a Symbol, a String, or the
      # `nil`/`[]`/`123` that a variable holding the wrong thing produces. They do not try to survive a String
      # subclass whose `to_sym` lies (answering with a wide Symbol, a non-Symbol, or by raising). Verifying that a
      # caller's object BEHAVES is unbounded — every round of verification is defeated by the next case — and the
      # honest boundary is that such a class is not a contract axn can be asked to hold. What IS guaranteed is that
      # nothing here consults the value's own `is_a?`, `inspect` or `encoding` to reach a verdict, so an ordinary
      # mistake is always diagnosed as one.
      def self.canonical_name!(value, option:, names:, fix:, encoding_fix:)
        validate_name_option!(value, option:, names:, fix:)
        validate_name_encoding!(value, kind: option, fix: encoding_fix)

        value.to_sym
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
        include ValidatorClassCache

        # rubocop:disable Metrics/ParameterLists
        def expects(
          *fields,
          on: nil,
          allow_blank: false,
          allow_nil: false,
          allow_empty: nil,
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
          fields = _canonical_field_names!(fields, kind: "a field name", names: "an inbound field")

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
          # Absent stays absent — `nil`, `false`, an empty or whitespace-only String and the empty Symbol all
          # mean "no route", which is the whole of what the `present?` this replaced answered — and that verdict
          # is reached WITHOUT running the route's own code, because `present?`/`blank?` are ActiveSupport
          # methods on Object that a String subclass overrides: one answering "blank" here and "present" to a
          # later reader skipped this line entirely and was stored raw, reinstating the split this
          # canonicalization exists to close. Absent canonicalizes to `nil` rather than being left as written,
          # so that every reader below is asking nil-or-Symbol — otherwise the SAME split reopens one line
          # down, with this deciding "absent" and a `present?` on the caller's own value deciding to route.
          #
          # A supplied route that is not a name at all is rejected here rather than left to `to_sym` (see
          # Contract.validate_name_option!): the option and the offending class are what the author needs, and
          # `NoMethodError` named neither.
          on = if Internal::NativeMethods.absent_value?(on)
                 nil
               else
                 # Canonicalized through the shared rule, which also holds the encoding of what `to_sym` ANSWERS —
                 # this is the value every consumer then splits on `.`, and a wide one raised from the split.
                 Contract.canonical_name!(on, option: "on:", names: "a parent reader",
                                              fix: "Pass the parent's name (dotted for a nested path), or omit `on:` " \
                                                   "to declare a top-level field.",
                                              encoding_fix: "Name the parent in UTF-8 (or any other ASCII-compatible " \
                                                            "encoding).")
               end

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
          if method_call && on.nil?
            raise ArgumentError,
                  "`method_call: true` is only meaningful on a subfield (declared with `on:`) — a top-level field " \
                  "reads its wire key and never invokes a method. Add `on:` to name the parent, or drop `method_call:`."
          end

          reader_names = _resolve_reader_names(fields, as:, prefix:)
          _validate_reader_names!(reader_names)

          validations, metadata = _partition_field_options(fields, **)
          validations[:shape] = _build_shape(fields, validations:, &block) if block
          _snapshot_declared_shape!(validations, fields)

          # `on` is nil-or-Symbol by construction here (canonicalized above), so routing asks the canonical
          # value rather than re-deciding presence on whatever the caller passed.
          if on
            return _expects_subfields(*fields, on:, allow_blank:, allow_nil:, allow_empty:, optional:, default:, preprocess:, sensitive:, metadata:,
                                               reader_names:, user_facing:, method_call:, **validations)
          end

          _parse_field_configs(*fields, allow_blank:, allow_nil:, allow_empty:, optional:, default:, preprocess:, sensitive:, metadata:,
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
          allow_empty: nil,
          optional: false,
          default: nil,
          sensitive: false,
          **,
          &block
        )
          # Symbolize the wire key (see `expects`) so exposes shares the same symbol-keyed contract.
          fields = _canonical_field_names!(fields, kind: "an exposure name", names: "an outbound field")

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

          # `exposes` takes no `on:` parameter, so the key arrives in the validations bag and would then be
          # absorbed by `_parse_field_configs`' subfield-parent parameter — stored as `config.on` on an outbound
          # config, where nothing reads it. Neither meaning is available: an exposure has no subfield parent
          # (see `_reject_dotted_field_name!` above, which refuses a dotted name for the same reason), and axn
          # has no ActiveModel validation contexts. Rejected on the key's presence, whatever the value, matching
          # how `exposes` refuses `user_facing:`.
          if validations.key?(:on)
            raise ArgumentError,
                  "exposes does not support `on:` on #{fields.map(&:to_s).inspect} — an exposure has no subfield " \
                  "parent to reach into, and axn has no ActiveModel validation contexts. Drop `on:`; to gate the " \
                  "outbound checks, use `if:`/`unless:`."
          end

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

          _parse_field_configs(*fields, allow_blank:, allow_nil:, allow_empty:, optional:, default:, preprocess: nil, sensitive:, metadata:,
                                        **validations).tap do |configs|
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

        DeclaredFieldsCacheEntry = Data.define(:internal_field_configs, :external_field_configs, :fields)

        # `configs.map(&:field)` was a fresh Array on every call — `Redaction#_context_slice` alone
        # calls this twice per logged line (inbound + outbound), and the context facade calls it twice
        # per action call. Cached per direction, invalidated by the identity of BOTH config arrays
        # (rather than only the one a given direction reads) for simplicity: an outbound-only
        # redeclaration then occasionally invalidates the (unaffected) :inbound slot too, which is
        # never a wrong answer, only an avoidable rebuild.
        #
        # The cached Array is FROZEN before it's stored: `ContextFacade` exposes this exact object
        # publicly as `Result#declared_fields`, so a fresh Array per call used to confine any caller
        # mutation to that one facade — reusing the same object across every future call turns that
        # mutation into permanent cache corruption (a caller-appended field name would start defining
        # readers/passing `expose` for undeclared output on every subsequent call of the class) unless
        # the shared object refuses to be mutated at all.
        def _declared_fields(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless direction.nil? || %i[inbound outbound].include?(direction)

          internals = internal_field_configs
          externals = external_field_configs
          cache = (@_axn_declared_fields_cache ||= {})
          cached = cache[direction]
          return cached.fields if cached && cached.internal_field_configs.equal?(internals) && cached.external_field_configs.equal?(externals)

          configs = case direction
                    when :inbound then internals
                    when :outbound then externals
                    else (internals + externals)
                    end

          cache[direction] = DeclaredFieldsCacheEntry.new(internal_field_configs: internals, external_field_configs: externals,
                                                          fields: configs.map(&:field).freeze)
          cache[direction].fields
        end

        ModelFieldsCacheEntry = Data.define(:internal_field_configs, :value)

        # Field => model options for every internal field carrying `model:`, cached per class: a pure
        # function of `internal_field_configs`, rebuilt only when that array's identity changes (any
        # redeclaration, subclass, or Mountable/Factory rebuild — see Redaction's doctrine comment).
        # Moved here from the context facade instance (was rebuilt from scratch on every reader
        # definition — O(fields defined × contract size) per action instance, since both the outbound
        # Result facade and the inbound InternalContext facade instantiate one per call).
        #
        # Frozen before caching, same reasoning as `_declared_fields`: this is a public class method
        # (so any caller can hold the live Hash), and the old per-call rebuild used to confine a
        # caller mutation to that one read — reusing the same Hash across every future call would
        # otherwise turn a mutation into permanent cross-call cache corruption.
        def _model_fields
          fields = internal_field_configs
          cached = @_axn_model_fields
          return cached.value if cached && cached.internal_field_configs.equal?(fields)

          value = fields.each_with_object({}) { |config, hash| hash[config.field] = config.validations[:model] if config.validations.key?(:model) }
          @_axn_model_fields = ModelFieldsCacheEntry.new(internal_field_configs: fields, value: value.freeze)
          value
        end

        # Everything below is reached only with an implicit receiver, from here and from the other declaration
        # modules extended onto the same class. It is private because an `_`-prefixed name in a module extended
        # onto every action class otherwise lands there as a PUBLIC singleton method, so the convention and the
        # surface disagree. `_declared_fields` stays public above: the context facade, the redaction slice and
        # `Mountable`'s step passthrough call it on the action class from other files. `_model_fields` stays
        # public for the same reason: the context facade reads it from `facade.rb`.
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
          key_for = ->(c) { [c.on.to_s, Axn::Internal::Reflection::Values.canonical_wire_key(c.field)] }

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
        def _shape_member_label(name) = Axn::Internal::Reflection::PropertyNames.renderable_label(name)

        # The two property-name rules are judged on the projection they would appear in, so they run when one is
        # first demanded rather than here (see Axn::Internal::Reflection::PropertyNames). What the contract still asks of
        # that layer eagerly is name RENDERING — `exposes` field names, whose bytes reach the serialized body
        # regardless of any schema, and the escaping every declaration message uses.
        def _reject_unrenderable_field_names!(names, kind: "a field name")
          Axn::Internal::Reflection::PropertyNames.reject_unrenderable_field_names!(names, kind:)
        end

        # How a declared name is written into a message, shared with the rules above so every message that
        # names a field or member escapes it the same way.
        def _inspect_field_name(name) = Axn::Internal::Reflection::PropertyNames.inspect_field_name(name)

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

          identical, collapsed = collisions.partition { |claimed, offending| Axn::Internal::Reflection::PropertyNames.same_declared_name?(claimed, offending) }
          if identical.any?
            names = identical.map { |_claimed, offending| Axn::Internal::Reflection::Values.canonical_wire_key(offending) }
            raise Axn::ContractViolation::DuplicateFieldError, "Duplicate field(s) declared: #{names.join(', ')}"
          end

          claimed, offending = collapsed.first
          raise Axn::ContractViolation::DuplicateFieldError,
                "Duplicate field(s) declared: #{_inspect_field_name(claimed)} and #{_inspect_field_name(offending)} " \
                "both render as the JSON property #{Axn::Internal::Reflection::Values.canonical_wire_key(offending).inspect} — a " \
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
        # `as:` renames a single field, `prefix:` prepends to each. The dotted constraint left is on the
        # VALUES themselves — a reader name still can't be dotted, whichever option composed it.
        #
        # Both options are OPTIONAL, so both get the absent set every other optional name option has
        # (`NativeMethods.absent_value?`: `nil`, `false`, an empty or whitespace-only String in any encoding,
        # the empty Symbol) and are canonicalized to `nil` when they carry one. Previously only `nil` meant
        # absent to the identity check while `if as` treated `false` as absent too, so the two options
        # disagreed about the same value — `as: false` meant "no rename" while `prefix: false` prepended the
        # literal text "false" — and the spellings in between were neither absent nor names: `as: ""` and
        # `as: "  "` generated readers called `:""` and `:"  "`.
        #
        # Beyond the absent set each must be a name, checked on the same terms as `on:`. `as:` was left to its
        # own `to_sym` (`NoMethodError` for an Array); `prefix:` was never even a `to_sym` site — it is
        # interpolated, so `to_s` accepted EVERY object silently and generated a reader from whatever it
        # rendered as (`prefix: []` → `:"[]a"`, `prefix: {x: 1}` → `:"{:x=>1}a"`), which no caller can invoke
        # and nothing later rejects.
        def _resolve_reader_names(fields, as:, prefix:)
          as = nil if Internal::NativeMethods.absent_value?(as)
          prefix = nil if Internal::NativeMethods.absent_value?(prefix)

          return fields.to_h { |f| [f, f] } if as.nil? && prefix.nil?

          raise ArgumentError, "`as:` and `prefix:` cannot be combined" if as && prefix

          if as
            raise ArgumentError, "`as:` can only be provided when declaring a single field (use prefix: for several)" if fields.size > 1

            # Canonicalized before the dotted check rather than after it, so the name the check JUDGES is the
            # name the reader is defined under — `to_s` and `to_sym` are two dispatches on the same caller
            # object, and a String subclass answering them differently had the guard clearing one spelling
            # while another was generated. A Symbol's `to_s`/`inspect` are Ruby's own, so both the check and
            # the message it may raise are now decided by axn. The shared rule holds the CANONICAL name's
            # encoding too, so the dotted question below is asked of bytes that can answer it.
            reader = Contract.canonical_name!(as, option: "`as:`", names: "the generated reader",
                                                  fix: "Pass the reader's name, or omit `as:` to name the reader for the wire key.",
                                                  encoding_fix: "Name it in UTF-8 (or any other ASCII-compatible encoding).")
            raise ArgumentError, "`as:` reader name may not be dotted (#{reader.inspect} would not name a method)" if reader.to_s.include?(".")

            { fields.first => reader }
          else
            # The same dotted rule as `as:`, on the same grounds and closed at the same time: a dotted prefix
            # composes a dotted reader (`prefix: "a."` → `:"a.field"`) that no caller can invoke, which is
            # exactly what the `as:` check above refuses. Asked of the canonicalized prefix, so the value
            # judged is the one interpolated below.
            segment = Contract.canonical_name!(prefix, option: "`prefix:`", names: "a prefix for each generated reader",
                                                       fix: "Pass the prefix as a String or Symbol, or omit `prefix:` to name " \
                                                            "each reader for its wire key.",
                                                       encoding_fix: "Name it in UTF-8 (or any other ASCII-compatible encoding).")
            if segment.to_s.include?(".")
              raise ArgumentError,
                    "`prefix:` may not be dotted (#{segment.inspect} would compose a reader that does not name a method)"
            end

            fields.to_h { |f| [f, :"#{segment}#{f}"] }
          end
        end

        # Every declared field name passes here, at both DSLs, BEFORE `to_sym` canonicalizes it and before any
        # check compares it to anything. A value that is not a name at all used to be diagnosed as whatever
        # `to_sym` happened to raise — `NoMethodError: undefined method 'to_sym' for an instance of Array`, which
        # named neither the DSL nor what was wrong with the value — and a name in a wide encoding as whatever the
        # first ASCII comparison raised (`Encoding::CompatibilityError`, from the dotted check below).
        #
        # Called WITHOUT the absent check that PRECEDES the same type guard at the option-shaped name sites.
        # `on:`, `as:`, `prefix:` and `expose_return_as:` are all optional, so every spelling of "not supplied"
        # legitimately means the option was omitted there. A field NAME is never optional: `expects nil` and
        # `expects false` name no field, so they are errors rather than absences, and running an absent check
        # here would silently accept them as declaring nothing.
        def _canonical_field_names!(fields, kind:, names:)
          fields.map do |field|
            Contract.canonical_name!(field, option: kind, names:,
                                            fix: "Declare the field under a String or Symbol name.",
                                            encoding_fix: "Declare it under a UTF-8 name (or any other " \
                                                          "ASCII-compatible encoding).")
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
          fail! forward! ok?
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
          __exposed_keys__
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
        SHAPE_MEMBER_FIELD_OPTIONS = %i[allow_blank allow_nil allow_empty optional method_call sensitive user_facing].freeze
        SHAPE_MEMBER_UNSUPPORTED_OPTIONS = %i[default preprocess].freeze

        # Reader-renaming options (`as:`/`prefix:`) rename the reader a field generates. A shape member is
        # reader-less, so they have nothing to rename — but they are legitimate keys elsewhere, so a bare
        # validations parse would reject them as "Unknown key(s)" (wrongly implying they are never valid).
        # `_build_shape_member` rejects them explicitly with the reader-less reason instead.
        SHAPE_MEMBER_READER_OPTIONS = %i[as prefix].freeze

        # `on:` on a member has neither of its two meanings available: axn has no ActiveModel validation
        # contexts (a bag-level one reaches `validates` verbatim on the raw route and silences every validator
        # in the bag on every call), and a member has no subfield parent for it to name either. Refused with
        # that reason rather than as an unrecognized key — `:on` IS a recognized option, which is why it stays
        # in KNOWN_MEMBER_VALIDATION_KEYS — and separately from the reader options, because an author who
        # wrote `on:` has a different problem from one who wrote `as:`.
        SHAPE_MEMBER_CONTEXT_OPTIONS = %i[on].freeze

        # The keys a shape member's VALIDATIONS bag may hold — derived from the two sets that already decide
        # it, never listed again beside them. `KNOWN_VALIDATION_KEYS` is the field path's own recognized set
        # (what `_partition_field_options` holds a field's bag to), and a member's bag is the same kind of
        # thing: the options `validates` is called with. ActiveModel's own shared options are unioned in
        # because a RAW member's bag reaches `validates` verbatim — nothing pushes a tolerance down into it,
        # as `_parse_field_validations` does for a field — and four of the six (`if:`/`unless:`/`on:`/
        # `strict:`) are in the field set already. The two the union adds are `allow_blank:`/`allow_nil:`,
        # which are exactly the tolerance the block form takes as a member kwarg (SHAPE_MEMBER_FIELD_OPTIONS)
        # and compiles into this bag for a field, and which already WORK on the raw route — so allowing them
        # is the parity rather than a widening, and rejecting them would be an over-rejection of a legal
        # declaration. Both sources are read rather than copied, so the member set cannot drift from either.
        KNOWN_MEMBER_VALIDATION_KEYS = (KNOWN_VALIDATION_KEYS | Axn::Validation::Base.shared_validation_option_keys).freeze

        # A raw `shape:` member's bag never passes `_partition_field_options`, so nothing had ever held its
        # KEYS to a grammar: a typo declared cleanly and then raised `Unknown validator: 'TpyeValidator'` on
        # EVERY call — naming a class the author never wrote, and neither the member nor the option — where the
        # same typo on a field is refused at declaration. Same for the field-level options someone naturally
        # reaches for inside a member bag (`optional:`, `default:`, `sensitive:`, `as:`). This is the field
        # path's own check applied where a raw member arrives, so one grammar decides both routes.
        #
        # Order mirrors `_build_shape_member`'s: an option a member may never carry is named for what it is,
        # and only what is left over is an unrecognized key. That is the split worth keeping — an author who
        # wrote `default:` has a different problem from one who wrote `tpye:`, and the first has a message
        # already, explaining WHY a reader-less member cannot carry it. A recognized key that a member still
        # cannot carry (`on:`) is excluded from the short circuit below, or it would be skipped before it
        # could be classified.
        #
        # Nothing a caller's key defines decides the verdict. A key that is not a Symbol is unknown by
        # construction (String keys were canonicalized on the way in), tested with `case`/`when` rather than
        # `is_a?` — so a key answering `hash`/`eql?` as `:type` cannot pass itself off as a recognized option,
        # and the keys the two specific messages RENDER are axn's own Symbols (a `Symbol#==` match is
        # identity), never the caller's object.
        #
        # One pass, classifying rather than raising as it goes, so the order above holds whatever order the
        # bag was written in — and so an ordinary member (every key recognized) allocates nothing here beyond
        # the Set lookups themselves.
        def _check_member_option_keys!(name, validations)
          unsupported = reader_opts = context_opts = unknown = nil
          validations.each_key do |key|
            case key
            when ::Symbol
              next if KNOWN_MEMBER_VALIDATION_KEYS.include?(key) && SHAPE_MEMBER_CONTEXT_OPTIONS.exclude?(key)
            end

            if SHAPE_MEMBER_UNSUPPORTED_OPTIONS.include?(key)
              (unsupported ||= []) << key
            elsif SHAPE_MEMBER_READER_OPTIONS.include?(key)
              (reader_opts ||= []) << key
            elsif SHAPE_MEMBER_CONTEXT_OPTIONS.include?(key)
              (context_opts ||= []) << key
            else
              (unknown ||= []) << key
            end
          end

          _raise_member_unsupported_options!(name, unsupported) if unsupported
          _raise_member_reader_options!(name, reader_opts) if reader_opts
          _raise_member_context_option!(name, context_opts) if context_opts
          return if unknown.nil?

          raise ArgumentError,
                "Unknown key(s) #{unknown.map { |key| _inspect_field_name(key) }.join(', ')} in the validations of " \
                "shape member `#{_shape_member_label(name)}`. Not a recognized validation — ActiveModel reads the " \
                "bag as validators, so it fails every call with `Unknown validator`. A member's other options are " \
                "attributes of the member ITSELF rather than entries in its validations bag: " \
                "`sensitive:`/`user_facing:`/`method_call:` are read from the member, `description:` and any " \
                "registered metadata from its `metadata`, and the tolerance the block form spells `optional:` is " \
                "`allow_blank:`/`allow_nil:` here."
        end

        # Shared by the block form (which passes the keys it was handed, in the order they were declared) and by
        # the declaration walk, so both routes give one reason for one option.
        def _raise_member_unsupported_options!(name, unsupported)
          return if unsupported.empty?

          raise ArgumentError,
                "shape member `#{_shape_member_label(name)}` does not support #{unsupported.map { |k| "#{k}:" }.join('/')} " \
                "(shape blocks declare validation/schema only)"
        end

        def _raise_member_reader_options!(name, reader_opts)
          return if reader_opts.empty?

          raise ArgumentError,
                "shape member `#{_shape_member_label(name)}` does not support #{reader_opts.map { |k| "#{k}:" }.join('/')} " \
                "(they rename a field's generated reader, but a shape member is reader-less; " \
                "use them on a top-level `expects` field or an `on:` subfield)."
        end

        def _raise_member_context_option!(name, context_opts)
          return if context_opts.empty?

          raise ArgumentError,
                "shape member `#{_shape_member_label(name)}` does not support " \
                "#{context_opts.map { |k| "#{k}:" }.join('/')} — it names an ActiveModel validation context, and " \
                "axn validates with no context, so every validator in the member's bag would be skipped on " \
                "every call. A member has no subfield parent for it to name either. Gate the checks with " \
                "`if:`/`unless:`, which axn does support."
        end

        # `coerce:` is field-only: it resolves a coerced value onto a reader, which a member has not got (see
        # `_parse_field_validations`, which deliberately keeps the coercible-set check out of the shared
        # canonicalization seam for the same reason). Read the same way whichever route declared it — the
        # block form arrives after `_expand_coerce_sugar!` has folded a top-level `coerce:` into the type bag,
        # a raw member arrives with whatever it was spelled as, and nothing expands it — so both spellings are
        # refused on both routes. `coerce: false` inside a type bag stays a legal no-op, as it is on a field.
        def _reject_member_coerce!(validations)
          type_bag = Internal::ShapeGraph.hash_or_nil(validations[:type])
          return unless validations.key?(:coerce) || (!nil.equal?(type_bag) && type_bag[:coerce])

          raise ArgumentError,
                "coerce: is not supported on a shape member (it has no reader for a coerced value to resolve " \
                "onto; use it on a top-level `expects` field or an `on:` subfield)."
        end

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
          _raise_member_unsupported_options!(name, opts.keys & SHAPE_MEMBER_UNSUPPORTED_OPTIONS)
          _raise_member_reader_options!(name, opts.keys & SHAPE_MEMBER_READER_OPTIONS)
          # Ahead of `_parse_field_configs` below, whose `on:` parameter would otherwise absorb the key as a
          # subfield parent — which `ShapeConfig` then drops, leaving the option silently gone.
          _raise_member_context_option!(name, opts.keys & SHAPE_MEMBER_CONTEXT_OPTIONS)

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
          _reject_member_coerce!(config.validations)

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
        #
        # And it declines to REPLACE a bag that answers from a Hash default, which is the same obligation seen
        # from the other end: canonicalizing is a copy, entries only, so the plain Hash written back here holds
        # no default — and the checks that own that rule (`ShapeGraph.detach_option_containers!` for an option
        # bag, the declaration walk for a `shape:` node) read what is written back. A Symbol-keyed defaulting
        # bag was refused while the same bag spelled with Strings declared silently, and an indifferent-access
        # one — every key a String however it is written — escaped under both spellings. The bag is left exactly
        # as it came so those checks judge what the author wrote; canonical keys are of no use to a declaration
        # that is about to be refused anyway.
        def _symbolize_option_bags!(validations)
          Internal::ShapeGraph.each_entry(validations) do |key, value|
            bag = Internal::ShapeGraph.hash_or_nil(value)
            next if nil.equal?(bag)

            symbolized = _symbol_keyed_bag(bag) { "the `#{key}:` option bag" }
            next if nil.equal?(symbolized) || Internal::ShapeGraph.supplies_default?(bag)

            validations[key] = symbolized
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
                "#{label} declares #{Axn::Internal::Reflection::PropertyNames.inspect_field_name(canonical)} twice — once " \
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
          allow_empty: nil,
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

          _parse_field_validations(*fields, allow_nil:, allow_blank:, allow_empty:, **validations).map do |field, parsed_validations|
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

        # A coerce target must be in the v1 coercible set (Axn::Internal::Coercion::SUPPORTED); an
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
          coercible = Axn::Internal::Coercion.coercible_klasses(type_hash)
          unsupported = klasses - coercible - [String]

          unless unsupported.empty?
            raise ArgumentError,
                  "coerce: does not yet support #{unsupported.map(&:inspect).join(', ')} " \
                  "(supported: #{Axn::Internal::Coercion::SUPPORTED.join(', ')}). " \
                  "String may accompany a coercible type as a passthrough."
          end

          return unless coercible.empty?

          raise ArgumentError,
                "coerce: needs at least one coercible type (#{Axn::Internal::Coercion::SUPPORTED.join(', ')}); " \
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

        # `on:` inside a validator's own option bag is ActiveModel's validation CONTEXT option, and axn has no
        # validation contexts: `Validation::Fields` calls `valid?` with no context, while `validate` installs a
        # gate of `!(Array(options[:on]) & Array(validation_context)).empty?` whenever `options.key?(:on)` — an
        # intersection that is empty on every call. So the entry runs on no call and whatever it declared is
        # unenforced, which is the strongest form of a silently ignored option: the author wrote a check, the
        # class defines cleanly, and every value passes.
        #
        # Only real validator ENTRIES are scanned. A BAG-level `on:` is a different declaration needing a
        # different fix — a shape member has no validation context and no subfield parent either, and neither
        # has an exposure — so it is reported where it arrives (`_check_member_option_keys!` /
        # `_build_shape_member` for a member, `exposes` for an exposure) and is out of this check's remit.
        #
        # Every offender is named at once: an author who wrote two of them has one declaration to fix, not two
        # rounds of the same error.
        def _reject_validator_context_scope!(validations, where:)
          offenders = Axn::Validation::Base.validator_entries(validations).filter_map do |key, entry|
            "#{key}:" if Axn::Validation::Base.entry_context_scoped?(entry)
          end
          return if offenders.empty?

          runs = offenders.size == 1 ? "that check runs" : "those checks run"
          raise ArgumentError,
                "`on:` inside #{offenders.join(' / ')} on #{where} names an ActiveModel validation context, and " \
                "axn validates with no context — so #{runs} on no call and the declaration is left unenforced. " \
                "Axn has no validation contexts: drop `on:`, or gate the check with `if:`/`unless:`, which axn " \
                "does support. (A DECLARATION-level `on:` is axn's subfield parent — `expects :zip, on: :address` " \
                "— and is unaffected.)"
        end

        # Pseudo-types (Symbol type names) whose values can be empty. `:params` is Hash-backed; `:boolean`
        # and `:uuid` have no empty state.
        EMPTIABLE_PSEUDO_TYPES = %i[params].freeze

        # Whether a declared type has an empty state for `allow_empty:` to talk about. Asked of the type's METHOD
        # TABLE rather than of an allowlist: it covers a custom container with its own `empty?`, and it avoids
        # naming `Set`, which may not be loaded outside Rails. Asked of any MODULE, matching what a declared type
        # may be: TypeValidator matches with `is_a?`, so a bare module is a supported `type:` and its values have
        # whatever empty state it defines (a `Class` is a `Module`, so every class is still asked).
        #
        # Nothing here runs a line the type wrote. The type test is a `case` (`Module#===`/`Symbol#===` are
        # C-level), and the capability read is bound (`NativeMethods.public_instance_method?`) — a class or module
        # defining `is_a?` or `public_method_defined?` would otherwise decide this guard's verdict for it, and a
        # declaration guard that a caller can invert is not a guard. Symbol membership is compared against axn's
        # own frozen list, where `==` is Symbol's (a Symbol takes no subclass).
        def _emptiable_type?(klass)
          case klass
          when ::Symbol then EMPTIABLE_PSEUDO_TYPES.include?(klass)
          when ::Module then Internal::NativeMethods.public_instance_method?(klass, :empty?)
          else false
          end
        end

        # How a declared type is written into a message: a pseudo-type by its own name, a class or module by the
        # seam that reads its name natively and renders the bytes, and anything else by its class. Nothing here
        # dispatches to the type — a class or module can define `inspect`/`to_s`/`name`, and one that raises while
        # a declaration error is being built replaces it with the caller's exception, which outside StandardError
        # escapes every rescue meant to settle it.
        def _declared_type_label(klass)
          case klass
          when ::Symbol then Axn::Internal::Reflection::PropertyNames.inspect_field_name(klass)
          when ::Module then Axn::Internal::Reflection::PropertyNames.renderable_module_name(klass)
          else "a value of class #{Axn::Internal::Reflection::PropertyNames.renderable_class_name(klass)}"
          end
        end

        # The grammar of an `allow_empty:` value: the option's three states — `true` (an empty value is
        # acceptable), `false` (it is not), and `nil` (unspecified, which is the option absent). Everything
        # downstream reads the flag by truthiness, so any other value would silently land on one of the two
        # poles — `allow_empty: "false"` on `true`, meaning the exact opposite of what it spells. A value
        # outside the grammar is a programmer error, rejected at declaration. Asked ahead of the empty-able
        # type guard so a bad VALUE is reported as one, rather than as a problem with the type it was
        # declared on. Membership is tested against the three literals, so nothing of the value's own is
        # invoked.
        def _validate_allow_empty_value!(fields, allow_empty)
          return if [nil, true, false].include?(allow_empty)

          # The offender is described by CLASS through the seam that reads it natively and renders the result:
          # its own `inspect` would run caller code while this failure is being reported, and one that raises
          # replaces the declaration error with the caller's exception — outside StandardError, escaping every
          # rescue meant to settle it.
          raise ArgumentError,
                "allow_empty: must be true, false, or nil on #{fields.map(&:to_s).inspect} " \
                "(got a value of class #{Axn::Internal::Reflection::PropertyNames.renderable_class_name(allow_empty)}). " \
                "`true` accepts an empty value, `false` rejects one, and omitting the option leaves the " \
                "field's other rules to decide."
        end

        # `allow_empty:` permits (or forbids) an empty value of a declared type. With no `type:` there is
        # nothing to reject a nil, so the flag would silently widen the field to accept anything; on a type
        # with no empty state there is nothing to permit. Both are declaration errors rather than silently
        # inert options.
        def _validate_allow_empty!(fields, validations)
          klasses = Array(validations.dig(:type, :klass))
          where = fields.map(&:to_s).inspect

          if klasses.empty?
            raise ArgumentError,
                  "allow_empty: requires a `type:` on #{where} — without one nothing rejects a nil, so the " \
                  "flag would widen the field to accept any value. Declare the container type (e.g. `type: Array`)."
          end

          offending = klasses.reject { |k| _emptiable_type?(k) }
          return if offending.empty?

          raise ArgumentError,
                "allow_empty: is not supported for #{offending.map { |k| _declared_type_label(k) }.join('/')} on " \
                "#{where} — those values cannot be empty, so there is no empty state to permit or forbid. " \
                "Drop allow_empty:."
        end

        # This method applies any top-level options to each of the individual validations given.
        # It also allows our custom validators to accept a direct value rather than a hash of options.
        def _parse_field_validations(
          *fields,
          allow_nil: false,
          allow_blank: false,
          allow_empty: nil,
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

          # Ahead of every consumer of this bag — `_validate_allow_empty!`, `_reconcile_emptiness_axis!`, the
          # tolerance push-down, `_apply_nil_skip_to_non_type_validators!` — so none of them ever judges an entry
          # that cannot run. Ahead of the push-down specifically so the message quotes the author's own spelling
          # rather than one carrying merged tolerance keys, and ahead of `_derive_raw_shape_container!` because
          # that rebuilds a raw `shape:` node and drops the very key being reported.
          #
          # After `ShapeGraph.detach_option_containers!` (`:1651`), which is what makes the verdict the caller's
          # to state and not to decide: every Hash-valued entry is axn's own plain Hash by now. `:shape` is the
          # one entry that seam skips, which is why the predicate classifies and reads its key without
          # dispatching to the bag.
          _reject_validator_context_scope!(validations, where: fields.map(&:to_s).inspect)

          _derive_raw_shape_container!(validations)

          _validate_allow_empty_value!(fields, allow_empty)
          _validate_allow_empty!(fields, validations) unless allow_empty.nil?

          tolerant = allow_blank || allow_nil

          # A truthy explicit presence: can never fire under a tolerance flag — the pushed-down
          # allow_blank/allow_nil would make the presence validator accept exactly the values it
          # exists to reject — so the combination is dead machinery, rejected at declaration.
          # (`presence: false` is coherent: explicit suppression, same intent as the flag.)
          if tolerant && validations[:presence]
            raise ArgumentError,
                  "optional:/allow_blank:/allow_nil: cannot be combined with an explicit `presence:` — " \
                  "the tolerance is pushed into every validator, so the presence check could never fail. " \
                  "For \"may be nil, but not empty\", declare `allow_empty: false` alongside the tolerance; " \
                  "otherwise declare one requiredness signal (drop the flag, or drop presence:)."
          end

          # Settle the emptiness axis before the push-down, while the `presence:`/`length:` entries are
          # still exactly as the author wrote them.
          _reconcile_emptiness_axis!(fields, validations, allow_empty:, tolerant:) unless allow_empty.nil?

          # Push allow_blank and allow_nil to the individual validations
          if tolerant
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
            _apply_default_presence!(validations, allow_empty:, tolerant:)
          end

          # Asked once the validations hash is final (both tolerance branches above have run), since the
          # answer depends on what they left behind.
          _apply_nil_skip_to_non_type_validators!(validations)

          fields.map { |field| [field, validations] }
        end

        # A field whose `type:` rejects nil has already reported that nil completely; running the other
        # validators against it only adds derivative messages (a custom `validate:` written for a real value
        # raises, and its crash is surfaced as a second failure on the same field). Give every non-type
        # validator nil-tolerance so the type error stands alone. Only the type validator's own nil verdict
        # is authoritative, so it is left untouched, as are validators that already carry explicit tolerance.
        # Mutates `validations`.
        def _apply_nil_skip_to_non_type_validators!(validations)
          return unless _type_rejects_nil?(validations)

          shared_option_keys = Axn::Validation::Base.shared_validation_option_keys
          declaration_options = validations.slice(*shared_option_keys)

          # Iterate a snapshot of the keys: the loop reassigns entries as it goes, and Ruby forbids
          # mutating a Hash mid-iteration.
          validations.keys.each do |key|
            opt = validations[key]
            next if key == :type || !opt || shared_option_keys.include?(key)

            normalized = Axn::Validation::Base.normalize_validator_options(opt)
            next if normalized.key?(:allow_nil) || normalized.key?(:allow_blank)

            # A strict entry RAISES instead of recording an error, and EachValidator's allow_nil skip
            # happens BEFORE validate_each — so relaxing it would swallow the raise rather than merely
            # drop a duplicate message. Standing down here preserves baseline behavior rather than being
            # lossless: none of axn's own custom validators (type/of/validate/model/shape) forward
            # `**options` to `errors.add`, so a `strict:` entry among them never raises regardless — it
            # keeps recording its own derivative message alongside the type error exactly as it did
            # before this guard runs. Only a validator that DOES forward `strict:` into `errors.add`
            # (an ActiveModel built-in such as presence) actually raises and so benefits from being left
            # untouched here.
            # Strictness is per ENTRY, so the effective value is asked (an entry's own `strict:` wins
            # over the declaration's), and the test is truthiness — the one AM applies — not blankness:
            # `strict: ""` is blank yet still raises.
            next if Axn::Validation::Base.entry_effective_option(normalized, declaration_options, :strict)

            validations[key] = normalized.merge(allow_nil: true)
          end
        end

        # Whether this field's declared type rules out nil on EVERY call, all by itself — the only
        # condition under which the type error is the field's complete account of a nil. Three ways it
        # isn't:
        #   * nil-tolerance pushed into the type bag — TypeValidator then skips nil outright;
        #   * a declared klass nil is an instance of (`type: [Array, NilClass]`, `type: Object`) — the nil
        #     is no type defect at all, so whatever else rejects it is the authoritative report. Asked
        #     through TypeValidator's own matcher so the two can't disagree about one declaration;
        #   * an effective if:/unless: gate on the type entry — a closed gate skips the type check, and
        #     then the OTHER validators' nil rejections are the only thing standing between the field and
        #     an accepted nil. Judged structurally (no condition is ever evaluated) by the same per-key
        #     merge model schema reflection uses.
        def _type_rejects_nil?(validations)
          raw = validations[:type]
          return false unless raw.is_a?(Hash) && raw[:klass]

          # The options the type check will run under, the declaration's included — a shared tolerance
          # governs it exactly as one inside the bag does.
          type = Axn::Validation::Base.effective_entry_options(raw, _shared_validation_options(validations))
          return false if type[:allow_nil] || type[:allow_blank]

          decl_gates = validations.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
          return false if Axn::Validation::Base.entry_effective_gate_keys(type, decl_gates).any?

          !Axn::Validation::Base.type_admits_nil?(type)
        end

        # Whether the automatic presence check covers this declaration — THE definition of "is an empty
        # value already forbidden by default here", asked both when installing the check and when
        # reconciling `allow_empty:` against the rest of the declaration. It does not apply when the
        # field is nil-tolerant (the tolerance is pushed into every validator, so presence could never
        # fire), when the field opted into emptiness (an empty value is exactly what presence would
        # reject, while the type check still rejects nil), when the author declared their own
        # `presence:`, or when the declared type is `:boolean`/`:params` (their own validation logic
        # stands in for it).
        def _default_presence_applies?(validations, allow_empty:, tolerant:)
          return false if tolerant || allow_empty || validations.key?(:presence)

          type_values = Array(validations.dig(:type, :klass))
          !(type_values.include?(:boolean) || type_values.include?(:params))
        end

        def _apply_default_presence!(validations, allow_empty:, tolerant:)
          validations[:presence] = true if _default_presence_applies?(validations, allow_empty:, tolerant:)
        end

        # Whatever enforces the emptiness axis talks about emptiness only, so it skips nil (the nil axis is
        # `optional:`/`allow_nil:` and the type check's business) and refuses the blank-tolerance a
        # nil-tolerance would otherwise push into it — which is what keeps it able to fire on the empty
        # value it exists to reject. Carried by axn's own check and by an author's deferred-to `length:`
        # floor alike, since either may be the one holding the axis.
        EMPTINESS_AXIS_TOLERANCE = { allow_nil: true, allow_blank: false }.freeze

        # `allow_empty:` is not the only thing in a declaration that can answer whether an empty value is
        # admissible, so one question decides the axis: does anything else here already answer it, and if
        # so does that answer agree? Two spellings can:
        #
        #   * an explicit `presence:` — it occupies the very check `allow_empty:` governs, so the two
        #     answer the same question and must agree in both directions;
        #   * an author-declared `length:` — their own size constraint, which may forbid size 0, admit it
        #     explicitly, or say nothing about it.
        #
        # Standing the flag's own check down in favor of one of them settles the axis only if that spelling
        # is GUARANTEED TO RUN, so every deferral asks that too (`_entry_guaranteed_to_run?`) — an entry a
        # closed gate can skip enforces nothing on the call where it is skipped.
        #
        # The asymmetry between the polarities is real, not an oversight: `allow_empty: false` is a
        # promise that must be ENFORCED, so any other spelling that would defeat it has to be resolved
        # here; `allow_empty: true` only suppresses the presence check axn would otherwise add, so a
        # `length:` the author wrote for their own reasons is no contradiction of it. Mutates
        # `validations`.
        def _reconcile_emptiness_axis!(fields, validations, allow_empty:, tolerant:)
          presence_answer = _presence_emptiness_answer(validations, tolerant:)

          if allow_empty
            if presence_answer == :rejected
              _raise_emptiness_conflict!(fields, allow_empty:, spelling: "presence:",
                                                 says: "that presence check rejects every empty value")
            end
            return
          end

          length_answer = _length_emptiness_answer(validations)
          authored_length = _authored_length_options(validations)

          # An author-declared floor of 1 or more is a stronger statement than the flag, not a
          # contradiction — defer to it, so long as it is guaranteed to run. Under a nil-tolerance it needs
          # the axis's own tolerance keys, or the pushed blank-tolerance would stand it down on exactly the
          # value it is being trusted to reject.
          if length_answer == :rejected && _entry_guaranteed_to_run?(validations[:length])
            validations[:length] = EMPTINESS_AXIS_TOLERANCE.merge(authored_length) if tolerant
            return
          end

          return if presence_answer == :rejected && _entry_guaranteed_to_run?(validations[:presence])

          # A `length:` that explicitly ADMITS an empty value is settled before asking what would enforce the
          # axis: the inferred presence check would honor the flag, but the declaration would still answer the
          # question two ways, so the pair reads the same in every arrangement rather than only under a
          # tolerance. An UNVERIFIABLE floor is a different thing — not a contradiction but a floor nothing
          # here can read — so where the inferred check carries the axis there is nothing to reconcile.
          if length_answer == :permitted
            _raise_emptiness_conflict!(fields, allow_empty:, spelling: "length:",
                                               says: "that length constraint admits an empty value")
          end

          return if _default_presence_applies?(validations, allow_empty:, tolerant:)

          _raise_unverifiable_length_floor!(fields) if length_answer == :unverifiable
          if presence_answer == :permitted
            _raise_emptiness_conflict!(fields, allow_empty:, spelling: "presence:",
                                               says: "that presence spelling drops the only check that would reject an empty value")
          end

          # Nothing else settles the question, so the flag carries the axis on its own — with its own check
          # (NonEmptinessValidator), which asks the value `empty?` rather than measuring its size. Installed
          # alongside an author's `length:` rather than merged into it, so their entry keeps naming only the
          # constraint they wrote, under only the gate they gave it; their `message:` still governs both
          # violations, being the one wording they asked for on the size axis.
          # The entry carries the declared klasses so the check can tell a value that IS of the declared type
          # yet cannot answer `empty?` — an unverifiable contract — from a wrong-typed one, whose single error
          # belongs to the type check. The declaration guard has already established a `type:` is present.
          key = Internal::FieldConfig::NON_EMPTINESS_KEY
          validations[key] = EMPTINESS_AXIS_TOLERANCE
                             .merge(klass: Array(validations.dig(:type, :klass)))
                             .merge(authored_length.slice(:message))
        end

        # Whether a validator ENTRY runs on every call, and so can be trusted with the emptiness axis in place
        # of the flag's own check. What withdraws that guarantee is a gate of its OWN — a closed condition skips
        # that one validator, leaving nothing to reject the empty value while the rest of the contract still
        # applies. Judged structurally; no condition is ever evaluated.
        #
        # A DECLARATION-level gate is deliberately not one: it skips EVERY validator in the declaration, the
        # emptiness check included, so relative to the check that would replace this entry there is nothing to
        # withdraw.
        def _entry_guaranteed_to_run?(entry) = !Axn::Validation::Base.entry_self_gated?(entry)

        # What an explicit `presence:` says about emptiness: `presence` is `!blank?`, so a live one rejects
        # every empty value, while a disabled (`presence: false`) or blank-tolerant one admits it. Nothing
        # is read out of it under a nil-tolerance — there the pushed tolerance means the check can never
        # fire, however it is spelled (a truthy one is already rejected outright). The AUTOMATIC presence
        # check is deliberately not an answer here either: it is inferred rather than authored, and
        # `allow_empty:` governs whether it is installed at all, so it can never contradict the flag.
        def _presence_emptiness_answer(validations, tolerant:)
          return nil if tolerant || !validations.key?(:presence)

          return :permitted unless validations[:presence]

          entry = Axn::Validation::Base.effective_entry_options(validations[:presence], _shared_validation_options(validations))
          entry[:allow_blank] ? :permitted : :rejected
        end

        # What an author-declared `length:` says about emptiness, judged from the floor it names:
        # `:rejected` for a floor the axis can lean on, `:permitted` when it names a floor that admits size 0
        # or carries its own blank-tolerance (which stands the whole entry aside for an empty value),
        # `:unverifiable` for a floor ActiveModel resolves per call, and nil when the entry answers nothing.
        #
        # Two shapes answer nothing. An entry that says nothing about the floor at all (a `maximum:` of 1 or
        # more, an unrecognized shape, a disabled entry); and a floor that forbids the empty value yet is not
        # one a schema floor can carry (`emittable_length_floor?`) — the flag then installs its own check,
        # which IS carryable, while the author's floor goes on rejecting whatever it rejects. Both the floor
        # and the test of what counts are the definitions schema reflection emits from, so the two layers
        # honor exactly the same set of floors.
        def _length_emptiness_answer(validations)
          opts = _effective_length_options(validations)
          return nil if opts.empty?
          return :permitted if opts[:allow_blank]

          floor = Axn::Validation::Base.declared_length_floor(opts)
          return nil if floor.nil?
          return :unverifiable if floor == :unverifiable
          return :rejected if Axn::Validation::Base.emittable_length_floor?(floor)

          floor.positive? ? nil : :permitted
        end

        # The author's `length:` entry as ActiveModel will act on it — read through the shared entry reader,
        # so a bare shorthand (`length: 2..5`) is judged in its expanded form and a falsy (disabled) entry
        # names nothing.
        def _authored_length_options(validations)
          Axn::Validation::Base.validator_entry_options(validations[:length])
        end

        # The same entry as the options it will RUN under. Read where the question is what the entry enforces;
        # `_authored_length_options` stays the author's own, because that is what is written back into the
        # declaration and the declaration's shared options must not be baked into an entry.
        def _effective_length_options(validations)
          Axn::Validation::Base.effective_entry_options(validations[:length], _shared_validation_options(validations))
        end

        # The declaration-wide options every entry of this declaration rides alongside — the tier each per-entry
        # judgment resolves against.
        def _shared_validation_options(validations)
          validations.slice(*Axn::Validation::Base.shared_validation_option_keys)
        end

        def _raise_emptiness_conflict!(fields, allow_empty:, spelling:, says:)
          verdict = allow_empty ? "acceptable" : "not acceptable"
          raise ArgumentError,
                "`#{spelling}` and `allow_empty: #{allow_empty}` answer the same question two ways on " \
                "#{fields.map(&:to_s).inspect} — #{says}, while `allow_empty: #{allow_empty}` says an empty value is " \
                "#{verdict}. Declare the emptiness axis once: keep `allow_empty: #{allow_empty}` and drop `#{spelling}`, " \
                "or drop `allow_empty:` and let `#{spelling}` stand."
        end

        def _raise_unverifiable_length_floor!(fields)
          raise ArgumentError,
                "`allow_empty: false` cannot be enforced on #{fields.map(&:to_s).inspect} alongside a `length:` " \
                "minimum that is not a literal number — ActiveModel resolves it per call, so nothing here can tell " \
                "whether it forbids an empty value, and one `length:` entry cannot carry two floors. Declare a " \
                "literal `minimum:` of 1 or more (which forbids empty on its own), or drop `allow_empty:`."
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
        # declared exposures. Safe on a failed source: it forwards whatever the source managed to
        # expose and never inspects error or calls fail!.
        #
        # An empty intersection is a wiring mistake worth raising over when BOTH the source SUCCEEDED
        # and the caller wants that check (`require_overlap: true`, the default for a direct
        # `expose(result)`, where forwarding is the entire point of the call). On a failed source the
        # raise would replace the source's own error with a contract violation and downgrade a clean
        # failure to an exception, which is strictly less information than forwarding nothing. A
        # caller for whom forwarding is a secondary effect of running the sub-action (`forward!`)
        # passes `require_overlap: false` so a side-effect-only or under-declared child forwards
        # cleanly instead of raising.
        def _expose_from_result(source_result, require_overlap: true)
          forwardable = source_result.declared_fields & self.class._declared_fields(:outbound)

          if forwardable.empty? && source_result.ok? && require_overlap
            raise Axn::ContractViolation::NoMatchingExposures.new(
              declared: self.class._declared_fields(:outbound),
              exposed: source_result.declared_fields,
            )
          end

          _absorb_result_exposures!(source_result, fields: forwardable)
        end

        # Write a source result's values onto this action's exposed_data, skipping any field the
        # source declared but never actually set: writing those would put nil over a value this action
        # had already exposed under the same name. An explicitly exposed nil IS set, so it still
        # forwards.
        #
        # Iterates the caller's `fields` rather than the source's own exposed keys, and the two are not
        # interchangeable. The step orchestrator merges a child's fields into a parent that may not
        # declare them, so a step-chain parent's exposed_data accumulates keys it has no reader for;
        # reading those back off such a result one level up would raise NoMethodError. Every entry in
        # `fields` is a declared field of the source, so `public_send` always resolves.
        def _absorb_result_exposures!(source_result, fields:)
          exposed = source_result.__exposed_keys__

          fields.each do |field|
            next unless exposed.include?(field)

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
