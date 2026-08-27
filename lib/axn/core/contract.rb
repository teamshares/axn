# frozen_string_literal: true

require "date"

require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"

require "axn/core/contract/redaction"
require "axn/core/contract/validator_class_cache"
require "axn/core/contract/shape_declaration"
require "axn/core/contract/subfield_contradictions"
require "axn/core/validation/fields"
require "axn/core/validation/container_contents"
require "axn/core/flow/handlers/invoker"
require "axn/internal/coercion"
require "axn/internal/shape_graph"
require "axn/internal/subfield_tree"
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
          class_attribute :internal_field_configs, :external_field_configs, instance_accessor: false, default: [].freeze

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

      # Holds the readers axn INFERS from another declaration — today the `<field>_confirmation`
      # companion a `confirmation:` field declares. A `Module` subclass rather than a bare module so a
      # reader's OWNER answers "did axn infer this?" as a fact of the method table, with no parallel
      # record to keep in step: an inferred reader may be withdrawn when the declaration behind it is
      # superseded, and nothing else may. Included below the class, so a same-named method the AUTHOR
      # wrote — or one an EXPLICIT declaration generated over the top — wins dispatch outright.
      InferredReaders = Class.new(Module)

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
        when true, false, nil, ::Symbol then return
        when ::Proc
          return unless _sensitive_proc_requires_argument?(sensitive)

          raise ArgumentError,
                "sensitive: Proc is instance_exec'd against the action instance with no arguments — it reads " \
                "other fields by name, the value is never passed to it — so it cannot declare a required " \
                "parameter (positional or keyword). Use `sensitive: -> { !include_pii }`, reading the field " \
                "it depends on by name, rather than `sensitive: ->(v) { ... }`."
        end

        raise ArgumentError,
              "sensitive: must be true, false, a Symbol naming an action method, or a Proc (got a value of " \
              "class #{Axn::Internal::Reflection::PropertyNames.renderable_class_name(sensitive)}) — any other value is not a redaction rule, and " \
              "a truthy one would silently leave the value logged in the clear rather than raise. Use " \
              "`sensitive: true` to always redact, or a Symbol/Proc predicate to decide per call."
      end

      # Read through Proc's OWN `#parameters` (`bind_call`, never dispatched) rather than the declared
      # object's: this guard exists to reject a Proc that lies about being callable with zero arguments, so
      # letting the Proc itself answer "how many arguments do I take" would let a singleton `parameters`
      # override falsify that answer and sail a required-argument Proc straight past the check it exists to
      # enforce — the same failure mode `case`/`when` above avoids for the class test itself.
      PROC_PARAMETERS = ::Proc.instance_method(:parameters)
      private_constant :PROC_PARAMETERS

      # Whether `proc` cannot be `instance_exec`'d with zero arguments — the one thing the resolver actually
      # does with it (`Redaction#_resolve_sensitive_value`). Read from `#parameters` rather than `#arity`:
      # arity goes negative (looks safe) the moment ANY optional/rest param joins a required one, e.g.
      # `->(a, k: nil) { true }` is arity -2 despite `a` still being required, and a non-lambda proc with a
      # required keyword (`proc { |k:| true }`) still raises on zero args despite `lambda?` being false — two
      # shapes `lambda? && arity.positive?` alone would wave through. `:req`/`:keyreq` are exactly Ruby's own
      # names for "would raise ArgumentError if not supplied", for a lambda or a proc alike.
      def self._sensitive_proc_requires_argument?(proc)
        PROC_PARAMETERS.bind_call(proc).any? { |(type, _name)| %i[req keyreq].include?(type) }
      end
      private_class_method :_sensitive_proc_requires_argument?

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

      # The option names the core field DSL owns. `_partition_field_options` routes a declaration's keys by
      # the field-metadata registry (`metadata = options.slice(*metadata_keys)`), so a gem registering one of
      # these would move the key out of the validations bag and change what it MEANS — leaving the DSL's
      # behaviour a function of which extensions happened to initialize. `register_field_metadata_key` refuses
      # the collision against this set, at the point the mistake is made rather than at each declaration that
      # trips over it.
      #
      # Every name is READ from the place that defines it, never copied beside it, so the set cannot drift
      # from the DSL it reserves — and drift here is precisely the defect, a core option becoming claimable
      # again with nothing to notice. That is why the kwarg names come from the signatures themselves: an
      # option added to `expects` tomorrow is reserved the moment it is added.
      #
      # Scoped to what the DSL OWNS, not to what a registration can currently misroute. A kwarg Ruby binds
      # before `**` collects it (`optional:`, `default:`) cannot be rerouted today, but registering one is
      # silently inert for the extension — it asks for a metadata key no declaration ever routes to — and a
      # kwarg that later moves into the splat would otherwise be unreserved.
      def self.reserved_field_option_names
        @reserved_field_option_names ||= (
          ClassMethods::KNOWN_VALIDATION_KEYS |
            Axn::Validation::Base.shared_validation_option_keys |
            _field_option_kwarg_names(:expects) |
            _field_option_kwarg_names(:exposes) |
            ClassMethods::SHAPE_MEMBER_FIELD_OPTIONS
        ).freeze
      end

      def self._field_option_kwarg_names(method_name)
        ClassMethods.instance_method(method_name).parameters.filter_map { |type, name| name if %i[key keyreq].include?(type) }
      end
      private_class_method :_field_option_kwarg_names

      # The one config type for every declared inbound/outbound field, top-level or subfield — a
      # top-level field is just the depth-0 case (`on: nil`). `reader_as` is the name of the
      # generated accessor method; it defaults to `field` (the wire key), but `expects ..., as:`/
      # `prefix:` decouple them so the caller-facing contract stays `field` while the in-action
      # reader gets its own name. `on:` names the parent reader a subfield is extracted from;
      # `user_facing:` reclassifies a violation of the field into a user-facing failure.
      # `method_call:` opts a subfield into the sharp path — resolving a segment by INVOKING it as a
      # method (Array methods, PORO readers, Data behavioral methods) rather than reading declared
      # data; it is threaded to the resolver as `permit_method_call:` (PRO-2898).
      #
      # `confirmation_for` names the field whose `confirmation:` DECLARED this config implicitly (nil on
      # every config an author wrote). It is the one thing that cannot be recovered from the config's
      # contents: an author who declares `<field>_confirmation` themselves must WIN over the implicit
      # companion whichever order the two lines are written in, and that means the later explicit
      # declaration replaces the stored companion instead of tripping the duplicate-field guard — while a
      # second EXPLICIT declaration of the same name stays the duplicate it has always been. Only
      # provenance separates those two, so it is recorded rather than re-derived.
      FieldConfig = Data.define(:field, :validations, :default, :preprocess, :sensitive, :metadata, :reader_as, :user_facing, :on, :method_call,
                                :confirmation_for) do
        def initialize(field:, validations:, reader_as:, default: nil, preprocess: nil, sensitive: false, metadata: {}, user_facing: false, on: nil,
                       method_call: false, confirmation_for: nil)
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

          # Two names, two receivers, judged separately — because `as:`/`prefix:` can pull them apart.
          # The RESOLVED reader is the method the declaration defines on the action class, so it is
          # judged there; that is what makes `as:` a real escape hatch, letting a contract whose wire key
          # happens to be `format` keep its public API and rename only what it puts on the class.
          # The WIRE KEY is judged at the inbound facade, which builds a reader per declared field and
          # is the only place the caller's value can be read back from (below).
          reader_names = _resolve_reader_names(fields, as:, prefix:)
          reader_names.each_value { |reader| _reject_shadowed_name!(reader) }
          # A subfield's wire key is a segment read out of its parent's value, not a field on the facade
          # (its configs live in `subfield_configs`, which `_declared_fields` never reports), so only a
          # top-level key lands there.
          fields.each { |field| _reject_shadowed_wire_key!(field) } if on.nil?
          _validate_reader_names!(reader_names)

          validations, metadata = _partition_field_options(fields, **)
          # Ahead of the block form's own write to this slot (a block legitimately builds a distributing
          # shape; a raw kwarg no longer may) — reads the caller's own `shape:`, not what a block would replace
          # it with, so a field declaring BOTH no longer has the raw one silently discarded (see PRO-3191).
          _reject_distributing_shape!(validations, "`shape:` on #{_declared_fields_label(fields)}")
          validations[:shape] = _build_shape(fields, validations:, &block) if block
          # Minted here, after the block form's per-member pre-pass, and threaded to BOTH of this declaration's
          # edges — the snapshot below and the `of:` chain `_parse_field_configs` descends (see
          # `_new_path_allowance`).
          path_allowance = _new_path_allowance(fields)
          _snapshot_declared_shape!(validations, path_allowance, fields)

          # `on` is nil-or-Symbol by construction here (canonicalized above), so routing asks the canonical
          # value rather than re-deciding presence on whatever the caller passed.
          if on
            return _expects_subfields(*fields, on:, allow_blank:, allow_nil:, allow_empty:, optional:, default:, preprocess:, sensitive:, metadata:,
                                               reader_names:, user_facing:, method_call:, path_allowance:, **validations)
          end

          # A `confirmation:` field declares its `<field>_confirmation` companion here, before any check
          # runs, so the companion is an ordinary member of the batch from that point on: it is judged by
          # the duplicate guard, committed with the rest, and gets its reader from the same pass.
          declared = _parse_field_configs(*fields, allow_blank:, allow_nil:, allow_empty:, optional:, default:, preprocess:, sensitive:, metadata:,
                                                   reader_names:, user_facing:, path_allowance:, **validations)
          companions = _confirmation_companion_configs(declared, existing: internal_field_configs)

          (declared + companions).tap do |configs|
            # A companion's reader clears no collision bar of its own: it is INFERRED, so it defers to
            # whatever already holds the name (`_define_field_readers!`) rather than raising or clobbering.
            # No reserved name ends in `_confirmation`, so the reserved-name half of that bar can't bind on
            # a companion either.
            #
            # An explicit declaration of a name an earlier `confirmation:` generated implicitly REPLACES that
            # companion (the author's own line is authoritative) rather than colliding with it.
            retained, superseded = _partition_superseded_confirmation_companions(internal_field_configs, configs)

            _reject_duplicate_fields!(retained, configs)
            # A top-level declaration carries no `on:`, so it looks like it can contradict no subfield. It
            # can: an explicit top-level config OUTRANKS an explicit subfield of the same name
            # (SubfieldTree.reader_rank), so it takes that reader over and every subfield anchored on the
            # name RE-ANCHORS onto the new root — stranding it under a parent that cannot answer it, under
            # a map, or under a tolerance nothing rescues. So the FULL check is asked here, over the same
            # candidate tree the subfield seam judges (`check!` builds it), rather than only the map slice
            # (PRO-3169). What a re-anchor can reach is what fires: `check_ambiguous_crossings!` is asked
            # for symmetry but cannot newly fire from here, since a top-level config's root node holds
            # exactly one config and a re-anchor SPLITS routes apart rather than merging them onto one node.
            #
            # A repeated top-level name is a duplicate (rejected above), so the takeover is always
            # top-level-over-subfield. Skipped outright where no subfield exists: with an empty tree every
            # top-level tolerance is exercisable and no segment is read, so a subfield-free contract sees
            # none of this — which is also what keeps the per-declaration tree build off that path.
            SubfieldContradictions.check!(retained + configs, subfield_configs) unless subfield_configs.empty?

            # Every declaration check has passed; NOW mutate the class (matching _expects_subfields'
            # validate-before-commit ordering), so a rescued declaration error never leaves the class
            # carrying an orphaned config or generated reader. Copy-on-write + freeze: `<<` would
            # mutate the superclass's contract, and identity-keyed caching relies on replacement.
            self.internal_field_configs = (retained + configs).freeze
            # Before the new readers, so a name the replacement reclaims is redefined rather than dropped.
            superseded.each { |c| _withdraw_inferred_reader!(c.reader_as) }
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

          fields.each { |field| _reject_shadowed_exposure_name!(field) }

          # exposes has no `on:`/subfields, so a dotted name has no valid meaning at all (see expects).
          _reject_dotted_field_name!(fields, on: nil, kind: "exposes")

          validations, metadata = _partition_field_options(fields, **)

          # `exposes` takes no `on:` parameter, so the key arrives in the validations bag and would then be
          # absorbed by `_parse_field_configs`' subfield-parent parameter — stored as `config.on` on an outbound
          # config, where nothing reads it. Neither meaning is available: an exposure has no subfield parent
          # (see `_reject_dotted_field_name!` above, which refuses a dotted name for the same reason), and axn
          # has no ActiveModel validation contexts. Rejected on the key's presence, whatever the value, matching
          # how `exposes` refuses `user_facing:`.
          #
          # BOTH partitions are asked, because `_partition_field_options` routes a key by whether an extension
          # registered it as field metadata — so a gem calling `register_field_metadata_key(:on)` would otherwise
          # move the key out of `validations` and take this declaration past the guard, leaving what `on:` means
          # here dependent on which extensions happen to be loaded. A core DSL option's meaning is not an
          # extension's to reassign; the registration is refused its collision at the point it would matter.
          if validations.key?(:on) || metadata.key?(:on)
            raise ArgumentError,
                  "exposes does not support `on:` on #{fields.map(&:to_s).inspect} — an exposure has no subfield " \
                  "parent to reach into, and axn has no ActiveModel validation contexts. Drop `on:`; to gate the " \
                  "outbound checks, use `if:`/`unless:`."
          end

          # A confirmation pair is an inbound form contract: the caller supplies both halves (the field and
          # its `<field>_confirmation`) and they are compared. An exposure has neither — it is a RESULT
          # property, set by the action's own code rather than read from caller input — so its companion
          # would be an exposed property the action never sets, resolving nil on every call. ActiveModel's
          # confirmation validator adds no error when the companion is nil (see
          # Validation::Base.nil_tolerant_validation?), so the option would decorate the field while never
          # once comparing anything — the exact defect this option exists to fix. Truthy, not key presence:
          # `confirmation: false` is the same disabled-validator no-op it is everywhere else.
          if validations[:confirmation]
            raise ArgumentError,
                  "`exposes` does not support confirmation: — a confirmation compares a caller-supplied value " \
                  "against a caller-supplied companion, and an exposure has neither. Declare the pair with " \
                  "`expects` if the confirmation is an input."
          end

          # Same refusal as `expects`, and for the same ordering reason: reads the caller's own `shape:` ahead
          # of the block form's write to the slot (see PRO-3191).
          _reject_distributing_shape!(validations, "`shape:` on #{_declared_fields_label(fields)}")
          validations[:shape] = _build_shape(fields, validations:, outbound: true, &block) if block

          # Ahead of the `user_facing:` walk below so a member carrying both an unusable name and a rejected
          # option is reported as the naming defect it is. That ordering only governs these two walks over
          # resolved members: in the block form the option error surfaces first, raised inside
          # `_build_shape_member` while `_build_shape` above is still assembling the members.
          # One allowance across both of this declaration's edges, minted after the block form's per-member
          # pre-pass (see `_new_path_allowance`).
          path_allowance = _new_path_allowance(fields)
          _snapshot_declared_shape!(validations, path_allowance, fields)

          # The block form rejects a `user_facing:` member inside `_build_shape_member` (above), but a
          # raw `shape:` kwarg supplies pre-built member objects that never route through it — so walk
          # the resolved members here to close that path too (see _reject_outbound_shape_user_facing!).
          _reject_outbound_shape_user_facing!(validations[:shape])

          _parse_field_configs(*fields, allow_blank:, allow_nil:, allow_empty:, optional:, default:, preprocess: nil, sensitive:, metadata:,
                                        path_allowance:, **validations).tap do |configs|
            # The field's own `of:` chain, walked HERE rather than beside the `shape:` walk above because only
            # now is it canonical: `_parse_field_configs` is what expands and descends it, and what replaces
            # every bag's caller-supplied `shape:` with the snapshot this walk is safe to read.
            configs.each { |c| _reject_outbound_shape_user_facing_in!(c.validations) }

            if configs.any? { |c| c.validations.dig(:type, :coerce) }
              raise ArgumentError, "coerce: is not supported on exposes (outbound fields are serialized, not coerced)."
            end

            configs.each { |c| _reject_shadowed_predicate_name!(c) }

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
            # Read ONCE and used for both of this member's edges — the nested `shape:` and the `of:` chain,
            # whose bags may carry shapes of their own (PRO-3166).
            validations = Internal::ShapeGraph.hash_or_nil(Internal::ShapeGraph.read(member, :validations))
            next if nil.equal?(validations)

            _reject_outbound_shape_user_facing!(Internal::ShapeGraph.shape_in(validations))
            _reject_outbound_shape_user_facing_in!(validations)
          end
        end

        # The same refusal at the OTHER position a shape can sit at: inside an `of:` bag, where its members
        # describe an unnamed position (PRO-3166). A member there is held to exactly what its named twin is
        # held to, so the option is refused at every rung rather than only at the ones that have a name — it
        # was accepted-and-inert here, which is the silent no-op every `of:` guard exists to prevent, and
        # before `:shape` joined the bag's grammar it was refused as an unknown key.
        #
        # `inner_contracts` is the one enumerator for this edge, so this walk descends exactly what the
        # declaration walk, redaction and reflection descend. Bounded for the reason the shape walk above is:
        # it runs over the SNAPSHOT, and the declaration walk has already refused a cyclic or over-deep graph
        # across both edges before anything reaches here.
        def _reject_outbound_shape_user_facing_in!(validations)
          Internal::ShapeGraph.inner_contracts(validations).each do |(_position, bag)|
            _reject_outbound_shape_user_facing!(Internal::ShapeGraph.shape_in(bag))
            _reject_outbound_shape_user_facing_in!(bag)
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

        # Which config answers to each reader name already declared on this class, across both tiers —
        # THE index of that question (Internal::SubfieldTree.reader_owners), asked here of the committed
        # configs. Two configs can share a name only when an inferred confirmation companion yields it to
        # a declaration, and the index resolves that to the declaration whichever order the two were
        # written in.
        def _reader_owners = Axn::Internal::SubfieldTree.reader_owners(internal_field_configs, subfield_configs)

        # Refuse a reader name a declaration would take over from something that is not axn's to
        # surrender. Judged on the action class, where the reader is defined: axn's own sugar is
        # surrenderable there — the user loses the helper and nothing else, since internals bind rather
        # than dispatch — while Ruby's, ActiveSupport's and the user's own names are not.
        #
        # A name axn itself put on the class is left alone: a redeclaration is a duplicate field,
        # reported downstream with the clearer DuplicateFieldError, and a reader DERIVED from another
        # declaration (a confirmation companion, a `model:` field's `<field>_id`) yields to an explicit
        # declaration of its name — which is already the behaviour in the other declaration order, where
        # `_reader_name_available?` declines to generate over the explicit reader.
        def _reject_shadowed_name!(name)
          return if _reader_owners.key?(name.to_sym) || _inferred_reader?(name) || _axn_generated_reader?(name)

          conflict = Axn::Internal::NameOwnership.conflict_for(self, name)
          return unless conflict

          raise ContractViolation::ReservedAttributeError.new(name, owner: Axn::Internal::NameOwnership.describe(conflict, name:))
        end

        # Refuse a top-level inbound WIRE KEY that the inbound facade already answers to. The key is
        # what the caller passes and what `Axn::Core::InternalContext` builds a reader for, and that
        # facade declines to define over its own methods (`ContextFacade#initialize`) — so a key naming
        # one of them is read back as the facade's own method result rather than as the caller's value.
        # Nothing on the facade is sugar: every method there is machinery some other reader depends on,
        # so nothing it owns is surrenderable, whatever the reader ends up being called.
        #
        # This is a separate question from the reader's, and `as:`/`prefix:` is what separates them:
        # they rename the method the declaration defines and leave the wire key exactly as written, so
        # the only way past this one is a different key. Only the facade's OWN surface is asked
        # (owner_within): Ruby's universal methods are judged once, on the action class, where a
        # legitimately-named key like `format` or `warn` also lands as a reader.
        def _reject_shadowed_wire_key!(name)
          conflict = Axn::Internal::NameOwnership.owner_within(Axn::Core::InternalContext, name)
          return unless conflict

          raise ContractViolation::ReservedAttributeError.new(
            name, owner: Axn::Internal::NameOwnership.describe(conflict, name:), kind: :wire_key
          )
        end

        # Refuse an exposure name that a reader would take over. Nothing an exposure lands on is
        # surrenderable, so both the receivers it lands on are asked and neither offers anything:
        #
        # - Axn::Result, where the exposure's own reader is defined — on the INSTANCE's singleton class,
        #   which outranks Result's own API, Ruby's and ActiveSupport's alike. Unlike the action class, a
        #   Result carries no user-facing sugar a declaration could take over harmlessly: every name it
        #   answers to is either machinery Result dispatches on itself (`ok?`, `exception`,
        #   `deconstruct_keys`, `_fail_standalone?`) or a universal method its callers dispatch on it
        #   (`hash` puts it in a Set, `class` reports its type, `inspect` logs it). So the whole method
        #   table is asked — public and private, inherited included — via `owner_of`.
        # - Axn::Core::InternalContext, which builds a reader for every OUTBOUND field too (they are the
        #   inbound facade's implicitly-allowed fields, so an action body can read back what it exposed).
        #   That reader reads `provided_data`, so an exposure named after one of the facade's own methods
        #   answers nil in the action body instead of running it — `default_error`/`default_success` are
        #   the two names that reach only this way. Only its OWN surface is asked (owner_within); Ruby's
        #   universal methods are judged once, above.
        #
        # Two more names a reader never touches, and that ownership therefore cannot see. Both are places
        # an exposure and axn's own machinery share a KEY rather than a method, and in both the machinery
        # wins silently — the wrong answer this rule exists to prevent:
        #
        # - a key `deconstruct_keys` reports (`ok`, `finalized`; the other four are method-owned too).
        #   The exposed data is merged OVER the outcome hash, so `case result in {ok:}` binds the
        #   exposure while `result.ok?` still reports the outcome — a destructuring that contradicts the
        #   result it came from.
        # - a control keyword of `fail!`/`done!` (`standalone`), which binds ahead of their `**exposures`
        #   splat: `fail!("boom", standalone: value)` sets the control and leaves the exposure nil.
        #
        # Both are read from what the consumer actually emits (Result::PATTERN_MATCH_KEYS, which
        # `deconstruct_keys` builds its hash from; the `fail!`/`done!` signatures), so neither is a
        # second hand-maintained list.
        #
        # `exposes` has no `as:`/`prefix:`, so the wire key IS the reader: unlike an expectation, the only
        # way past this is a different name, and the message says so.
        def _reject_shadowed_exposure_name!(name)
          conflict = Axn::Internal::NameOwnership.owner_of(Axn::Result, name) ||
                     Axn::Internal::NameOwnership.owner_within(Axn::Core::InternalContext, name) ||
                     _exposure_key_conflict(name)
          return unless conflict

          raise ContractViolation::ReservedAttributeError.new(
            name, owner: Axn::Internal::NameOwnership.describe(conflict, name:), kind: :exposure
          )
        end

        def _exposure_key_conflict(name)
          name = name.to_sym
          return :pattern_match_key if Axn::Result::PATTERN_MATCH_KEYS.key?(name)
          return :settlement_control_kwarg if Axn::Core::SETTLEMENT_CONTROL_KWARGS.include?(name)

          nil
        end

        # A boolean exposure lands a SECOND name on the Result — `<field>?`, aliased onto the same
        # singleton — so that name clears the same bar. Mirrors the conditions at the definition site
        # (Result#_define_boolean_predicate_reader): only boolean fields get a predicate, and a field
        # already spelled with a `?` gets none.
        def _reject_shadowed_predicate_name!(config)
          return unless config.boolean?
          return if config.field.to_s.end_with?("?")

          _reject_shadowed_exposure_name!(:"#{config.field}?")
        end

        # No two declarations may resolve to the same reader name. (The shadowing bar every reader clears
        # is applied by the caller, over the same resolved names.)
        def _validate_reader_names!(reader_names)
          # A collision is a *new* reader name already claimed by an existing config under a different
          # wire key. A same-wire-key clash is a genuine duplicate field, reported downstream with a
          # clearer DuplicateFieldError, so it's excluded here. Checking every new reader (not just
          # aliases) catches alias-vs-plain clashes in either declaration order — e.g.
          # `expects :bar, as: :foo` then `expects :foo`, which would otherwise silently clobber the
          # `bar` reader. Intra-call duplicates (distinct fields → same reader) are caught too.
          # The wire key behind each name is the OWNER's (_reader_owners), so a name a companion merely
          # spells cannot stand in for the declaration that holds it — which is what makes a same-wire-key
          # redeclaration report the clearer DuplicateFieldError in either declaration order.
          # Only names an actually-generated reader answers to can be collided with. A dotted-key subfield
          # defines no method, so its name stays free; consult the method table rather than every
          # config so those readerless declarations don't manufacture phantom collisions. A name held by
          # an INFERRED reader is free too: it is not a declaration, so the explicit one takes the name
          # and the inferred reader yields (_inferred_reader?).
          existing = _reader_owners
                     .select do |reader, _config|
                       Internal::NativeMethods.declared_instance_method(self, reader) && !_inferred_reader?(reader)
                     end
                     .transform_values(&:field)
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

        KNOWN_VALIDATION_KEYS = Set.new(%i[
                                          absence acceptance comparison confirmation exclusion format
                                          inclusion length numericality presence uniqueness
                                          type model validate of shape coerce
                                          if unless on message strict
                                        ]).freeze

        # What a bag says about the POSITION rather than about the value at it, read from the lists
        # `Internal::ShapeGraph` owns rather than restated here — the validator set below is DERIVED by
        # subtracting it, so a key added to the grammar cannot be mistaken for a validator, and a validator
        # cannot be mistaken for grammar, because neither list is written twice.
        BAG_GRAMMAR_KEYS =
          (Internal::ShapeGraph::POSITION_DESCRIPTION_KEYS + Internal::ShapeGraph::INNER_CONTRACT_EDGES).freeze

        # The validators that have a reading at an unnamed position, derived rather than listed (PRO-3193).
        #
        # A position offers a VALUE and nothing else — no name, no sibling readers, no record — so what is
        # refused is exactly what reads something a position has not got. `type:` because the bag already
        # spells that `klass:`, and two spellings for one thing is what PRO-3191 retired for `shape:`;
        # `model:` because it resolves against a `<field>_id` reader; `confirmation:` because it reads a
        # sibling `<field>_confirmation` reader; `coerce:` because it is a transform rather than a constraint,
        # and where a coerced element LIVES has to settle against the read-path doctrine first (PRO-2903);
        # `uniqueness:` because it needs a record and a relation, and its disposal at every position is
        # PRO-3219's rather than decided here.
        #
        # `on:` needs no entry: it leaves with the shared options, and `_reject_inner_contract_context_scope!`
        # already refuses it by naming the real problem (axn has no validation contexts).
        NEEDS_A_NAMED_SLOT = %i[type model confirmation coerce uniqueness].freeze

        POSITIONAL_VALIDATOR_KEYS =
          (KNOWN_VALIDATION_KEYS - NEEDS_A_NAMED_SLOT - BAG_GRAMMAR_KEYS -
            Axn::Validation::Base.shared_validation_option_keys.to_a).freeze

        # What an `of:` bag may carry. `of:` and `shape:` are the recursion (PRO-3166): a bag describes one
        # unnamed position, and a position may hold a container of its own or be described by its members.
        # Everything else is refused rather than ignored — the bag reaches `OfValidator` as an EachValidator
        # options hash, which reads the keys it knows and drops the rest, so an unrecognized key declares
        # cleanly, constrains nothing, and every value passes.
        #
        # `on:` and `strict:` are admitted here and refused by `_reject_inner_contract_context_scope!` /
        # `_reject_inner_contract_strict!` — the bag-level twins of the field's own scans, and the ones that reach
        # a bag at every position — which name the actual problem (axn has no validation contexts, and no
        # strict-raising mode) instead of reporting the key as unknown. `except_on:` rides along admitted with
        # the rest of the shared options and has no bag-level guard of its own yet.
        #
        # `allow_nil:`/`allow_blank:`/`optional:` are the position's TOLERANCE: the same three spellings a named
        # shape member takes, meaning the same three things about the value at this position. A bag also
        # receives `allow_blank:`/`allow_nil:` from the field-level tolerance push-down, which merges them into
        # every validator entry including this one — so a whitelist without them would refuse
        # `of: Integer, optional: true` on the FIELD. `_canonicalize_bag_tolerance!` folds the `optional:` sugar
        # into the pair before any of them is read, so the pair is the only form stored. Whether `if:`/`unless:`
        # then do anything depends on the position, which is `AXIS_INERT_OPTION_KEYS` below.
        #
        # `optional` itself is never seen by the check below — `_canonicalize_bag_tolerance!` always deletes it
        # first — so its entry here is not a gate. It exists because `_reject_unknown_of_keys!` renders `allowed
        # - UNADVERTISED_OF_KEYS` as the "(supported: …)" list on an unknown-key refusal; without this entry
        # that list would advertise a grammar a typo'd sibling key could not actually match.
        #
        # `POSITIONAL_VALIDATOR_KEYS` is the value-constraint half (PRO-3193): a bag is a validator SET for
        # the position it describes, not only a type check, which is what makes the remedy PRO-3192's refusal
        # messages point at actually exist.
        OF_OPTION_KEYS = (Set.new(%i[klass of shape message optional]) | POSITIONAL_VALIDATOR_KEYS |
                          Axn::Validation::Base.shared_validation_option_keys).freeze

        # The same set for the other container. A Hash's insides are two axes rather than one element position,
        # so `klass:` has no reading here and is absent: which axis it named would be a convention rather than
        # something the declaration says. `message:` is absent for the neighbouring reason — one message cannot
        # say which axis failed. It is the AXIS bag that takes one (`OF_OPTION_KEYS` carries it), which is what
        # a per-axis message needed and why the bag had to exist first (PRO-3166).
        MAP_OF_OPTION_KEYS = (Set.new(%i[keys values]) | Axn::Validation::Base.shared_validation_option_keys).freeze

        # The two things inside a Hash, in the order a declaration reads them.
        MAP_OF_AXES = %i[keys values].freeze

        # Every way of failing to "name an axis": a bare `of: Integer` names none of them, a bag naming neither
        # constrains nothing at all, and an axis holding an empty union names nothing while looking like it does.
        # One message, since the fix is the same one every way.
        MAP_OF_REQUIRED_MESSAGE = "of: requires keys: and/or values: for a Hash — a Hash has two things inside it, " \
                                  "so name the axis you are constraining"

        # Types for which a shape block is meaningless — the block describes the members of a
        # structured value (Array elements, Hash keys, or a class's readers), not a scalar.
        SHAPE_INCOMPATIBLE_TYPES = [String, Integer, Float, Numeric, TrueClass, FalseClass, Symbol, NilClass,
                                    Date, Time, DateTime,
                                    :boolean, :uuid, :params].freeze

        # The classes whose `to_s` is a Ruby inspect form rather than a rendering of the value — so a validator
        # matching or coercing `value.to_s` reaches punctuation rather than data. Deliberately NOT "every
        # structured type": a `Data` class or a PORO may render itself meaningfully (`URI::HTTP#to_s`), and
        # refusing `format:` there would reject a legal declaration. `Set` is listed because its `to_s` is an
        # inspect form exactly as the other two are.
        CONTAINER_TYPE_TOKENS = [::Array, ::Hash, ::Set].freeze

        # Validators ActiveModel implements against `value.to_s` or a numeric coercion of it, so no container
        # value can satisfy them WHATEVER the options say: FormatValidator matches `value.to_s` (on an Array it
        # constrains `["a"].inspect` — measured: `format: { with: /\A\["a"\]\z/ }` really does accept `["a"]`),
        # and NumericalityValidator parses a numeric coercion, which no container has (measured against `["1"]`,
        # `[1]` and `{"a"=>1}`, with `only_integer:` and `greater_than:` alike).
        #
        # `comparison:` and `acceptance:` deliberately do NOT belong here, though an earlier draft had them:
        # their options can name a CONTAINER, and then they work. `comparison: { equal_to: ["a"] }` accepts
        # `["a"]`, `{ greater_than_or_equal_to: { "read" => true } }` accepts a Hash superset (Hash#>=),
        # `{ greater_than: Set["a"] }` accepts a Set superset (Set#>), and `acceptance: { accept: [["a"]] }`
        # accepts `["a"]` — all measured in bare ActiveModel. What is broken about them is a bound or set of the
        # WRONG type, which is the satisfiability question Task 3 answers with the runtime's own matcher, not a
        # blanket refusal by key.
        TO_S_TARGETED_VALIDATOR_KEYS = %i[format numericality].freeze

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
                "axn validates with no context, so on a raw `shape:` member every validator in the bag would be " \
                "skipped on every call, while on a block-form member the option is discarded outright. A member " \
                "has no subfield parent for it to name either. Drop `on:`, or gate the checks with " \
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
          # Truthy, not key presence: `confirmation: false` is the same disabled-validator no-op it is on a
          # field, so it is left alone rather than refused (see _raise_member_confirmation_unsupported!).
          _raise_member_confirmation_unsupported!(name) if opts[:confirmation]

          field_opts = opts.slice(*SHAPE_MEMBER_FIELD_OPTIONS)
          field_validations, metadata = _partition_field_options([name], **opts.except(*SHAPE_MEMBER_FIELD_OPTIONS))

          # Same refusal, same ordering reason, at the member's own slot: a `field :rows, type: Array, shape:
          # {...} do ... end` no longer has its raw `shape:` silently replaced by the subblock's (see PRO-3191).
          _reject_distributing_shape!(field_validations, "`shape:` on shape member `#{_shape_member_label(name)}`")
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
          _shape_compatible_klass!(_declared_type_klass(validations), requirement: "a shape block requires a single structured type:")
        end

        # The class a declaration's `type:` names, in either spelling: the shorthand (`type: Hash`) or the bag
        # the canonicalization expands it into (`type: { klass: Hash }`). ONE read, shared by every caller that
        # asks what a shape hangs off, so none of them has to know whether it runs before or after the
        # expansion. `case`/`when` (via ShapeGraph) rather than `is_a?`: `type:` is a caller-supplied bag, and a
        # Hash subclass denying its own class would have the whole bag read as the declared class.
        def _declared_type_klass(validations)
          type = validations&.dig(:type)
          type_bag = Internal::ShapeGraph.hash_or_nil(type)
          nil.equal?(type_bag) ? type : type_bag[:klass]
        end

        # The rule itself, over the declared class alone, because the two callers name that class with two
        # different keys: a FIELD names it in `type:`, an inner-contract bag in `klass:` (PRO-3166). `requirement:`
        # travels with it for the reason `_declared_of_container!`'s `option:` does — one rule, but a refusal
        # naming a key the declaration does not carry prescribes a fix with nowhere to land, and there is no
        # "shape block" to name when the shape was written inside a bag.
        #
        # Each declared class is named through the seam that reads its name natively rather than by rendering the
        # LIST: `Array#inspect` dispatches every element's own `inspect`, so a declared class defining one that
        # raises would replace this ArgumentError with the caller's exception — which outside StandardError
        # escapes every rescue meant to settle it. Byte-identical to the list's rendering for every class and
        # pseudo-type token.
        def _shape_compatible_klass!(klass, requirement:)
          klasses = Array(klass)
          return klasses.first if _shape_compatible_klass?(klass)

          raise ArgumentError,
                "#{requirement} (Array, Hash, or a class) — got [#{klasses.map { |k| _declared_type_label(k) }.join(', ')}]"
        end

        # The same rule as a question rather than a demand, for the one caller that must not refuse what it
        # cannot gate on (`_fold_distributing_shape!`). Split out rather than restated, so "a shape can be read
        # off this class" has one definition and the refusal above cannot drift from the fallback below.
        def _shape_compatible_klass?(klass)
          klasses = Array(klass)
          klasses.size == 1 && SHAPE_INCOMPATIBLE_TYPES.exclude?(klasses.first)
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

        # The same derivation for the OTHER position a `shape:` can sit at: inside an `of:` bag (PRO-3166), where
        # it names the members of the value AT THAT POSITION — never "each element of it", which is the
        # distributing reading `shape:` has only at a field under `type: Array`. So the container is the bag's
        # own `klass:`, which plays `type:`'s role inside a bag, held to the same "single structured class" bar
        # a field's `type:` is.
        #
        # A bag naming no class at all is the case a field never has: `of: { shape: … }` is "each element has
        # these members, class unconstrained". That gets the explicit `ANY_CONTAINER` sentinel rather than a nil
        # container, because ABSENCE already means something here — it is the bug signature
        # `_derive_raw_shape_container!` exists to catch, a shape that never got a container derived and fails
        # every call with a bare `TypeError: class or module required`.
        #
        # Detached before the write for the reason `_derive_raw_shape_container!` details, one step further: by
        # the time this runs the node is the declaration walk's own copy, SHARED by every position reusing that
        # shape, while the container belongs to the position — so writing in place would give one position the
        # container derived for another. Mutates `bag`.
        def _derive_inner_shape_container!(bag, fields)
          shape = Internal::ShapeGraph.hash_or_nil(bag[:shape])
          return if nil.equal?(shape)

          detached = Internal::ShapeGraph.detach_node(shape)
          if nil.equal?(detached[:container])
            detached[:container] =
              if Internal::ShapeGraph.carries_key?(bag, :klass)
                _shape_compatible_klass!(bag[:klass], requirement: "a shape inside an `of:` bag requires a single structured klass:")
              else
                Internal::ShapeGraph::ANY_CONTAINER
              end
          end
          _reject_distributing_inner_shape!(detached[:container], fields)
          _reject_non_class_container!(detached[:container])
          bag[:shape] = detached
        end

        # `::Array` is the one class a shape reads perfectly well off and still may not be stored at a BAG
        # position, because `container: Array` is not a gate at that key: `ShapeValidator` reads it as
        # "distribute over the elements" (see `_folded_element_container`, which sidesteps the same reading by
        # storing `ANY_CONTAINER`). So a bag arriving here with it declares one thing and means another, both
        # ways of arriving at it, and each produces a contract no reader of the declaration could predict —
        # `of: { klass: Array, shape: … }` validates the members against `rows[i][j]` while emitting
        # `items: { type: "array" }` and publishing none of them, and an explicit `container: Array` beside
        # `klass: Hash` enforces nothing at all (a Hash element distributes to no elements) while the schema
        # promises the members as `items.properties`. Refused rather than assigned a reading, because the
        # recursion this ticket adds already spells the level below (`of: { klass: Array, of: { shape: … } }`)
        # and emits it correctly — and because a spelling refused today can be granted a meaning later
        # (PRO-3192) without contradicting anything released.
        #
        # Identity on axn's side, as every other read of this key is: a shape may put any object in that slot.
        def _reject_distributing_inner_shape!(container, fields)
          return unless ::Array.equal?(container)

          raise ArgumentError,
                "a `shape:` inside an `of:` bag cannot sit at `container: Array` (on " \
                "#{_declared_fields_label(fields)}) — `ShapeValidator` reads that container as \"distribute " \
                "over the elements\" rather than as a gate, so the members describe what is inside each " \
                "element instead of the element itself, and the emitted schema and the runtime disagree about " \
                "which value carries them. Where the members belong to the level below, write it as the " \
                "nesting it is (`of: { klass: Array, of: { shape: ... } }`), which emits " \
                "`items.items.properties`; where they belong to this level, name the class they are read off " \
                "(`klass: Hash`, or the object's own class) and leave the shape's `container:` to be derived."
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
          path_allowance: nil,
          **validations
        )
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          if validations.key?(:model)
            _validate_model_batch!(fields, on:)
            _reject_model_transform!(fields, on:, preprocess:, validations:)
          end

          _parse_field_validations(*fields, allow_nil:, allow_blank:, allow_empty:, path_allowance:, **validations).map do |field, parsed_validations|
            reader = reader_names[field] || field
            FieldConfig.new(field:, validations: parsed_validations, on:, default:, preprocess:, sensitive:, metadata:,
                            reader_as: reader, user_facing:, method_call:)
          end
        end

        # The companion `FieldConfig`s a batch's `confirmation:` fields declare implicitly — the same
        # treatment a `model:` field's `<field>_id` gets, and for the same reason: the option names a SECOND
        # wire key, so the contract has to carry it or nothing downstream (redaction, the undeclared-input
        # gate, the emitted schema) can see it. The reader name is derived from the base's READER and the
        # wire key from the base's FIELD — the same split `_define_model_id_reader_from` makes — so an
        # `as:`-aliased `expects :password, as: :pw, confirmation: true` keeps `password_confirmation` on the
        # wire while user code reads `pw_confirmation`.
        #
        # What it inherits is what has to match for the comparison to mean anything, since both sides of a
        # comparison must live in the same space:
        #   * `type:` (which carries the parsed `coerce:` flag — `_expand_coerce_sugar!` folds the option into
        #     the type bag, so there is no separate key left to copy) keeps the emitted schema and the runtime
        #     agreeing about what the companion may be, and keeps a coerced pair comparable: a form post of
        #     `count: "5", count_confirmation: "5"` against `coerce: Integer` compares 5 to "5" and reports a
        #     mismatch the caller cannot act on unless the companion coerces too. The base's TOLERANCE is
        #     deliberately not inherited with it: a field's tolerance is recorded on its own declaration, not
        #     inside its type bag, and a companion that tolerated what the base tolerates would accept the
        #     omission the companion exists to reject. So a tolerant typed base reports its missing companion
        #     through the inherited type, exactly as a strict one does.
        #   * `preprocess:` for the same reason — a `->(s){ s.strip }` on the base alone compares "a" to " a ".
        #   * `sensitive:` because the failure mode is a LEAK: a confirmed secret whose companion logs in the
        #     clear is the whole password beside the redacted one.
        #   * `method_call:` as an ENABLER, not a requirement: it is never consulted on a Hash/Data/Parameters
        #     source (FieldResolvers::Extract reads those by key before reaching the gated dispatch branch),
        #     and on an object source the base field's own read already required it. Same reasoning as the
        #     undeclared `<field>_id` resolved off a possibly-object parent with `permit_method_call:
        #     config.method_call`.
        #   * `user_facing:` because a companion violation is the same caller-input defect the base's is.
        # `default:` must NOT carry: a defaulted companion would silently satisfy its own comparison, so it is
        # excluded rather than inherited. Nor does `metadata:` — a description written for the base field is
        # not a description of its companion.
        #
        # REQUIREDNESS is the companion's OWN `presence:`, declared here rather than left to whatever the
        # inherited `type:` happens to reject. Deriving it from the type — even indirectly, by letting the
        # builder's default presence stand down as it does for `type: :boolean`/`:params` — leaves the
        # confirmation unenforced on precisely the declarations that carry no nil-rejecting type (an untyped
        # base, `allow_nil:`, `optional:`, `:boolean`/`:params`), which is the defect this option exists to
        # fix, in a spelling the emitted schema agrees with. Stated explicitly, the property holds for every
        # base type by construction, with no per-type list to keep in step. It can never reject a MATCHING
        # companion: the gate below is open only when the base value is present, and a companion equal to a
        # present value is present too.
        #
        # Everything else about the build is the shared one — `_parse_field_configs`, the builder every
        # declared field goes through — so the companion carries the same canonicalized validators, emptiness
        # axis and nil-skip verdict a hand-written `expects :<field>_confirmation, type: <base type>,
        # if: <base reader>` does, down to its reported message (pinned by spec).
        #
        # GATED so that "required" means "required once there is something to confirm" — the question the
        # gate has to answer is whether the base HAS a value to confirm:
        #   * a base whose own contract rejects blank (the ordinary `presence:`-carrying declaration) can only
        #     hold values for which Ruby truthiness and presence are the same answer, so it is gated on the
        #     base's reader as a SYMBOL — the one spelling that emits an EXACT conditional requirement
        #     (Internal::Reflection::Schema.conditional_requiredness_clause);
        #   * a base that ADMITS a blank value (`optional:`/`allow_blank:`/`allow_nil:`, `allow_empty: true`,
        #     an explicit `presence: false`, or a `:boolean`/`:params` type whose own logic stands in for the
        #     presence check) can hold a blank-but-TRUTHY one — `""`, `[]`, `{}` — where the two answers
        #     diverge, and a truthiness gate would demand a non-blank companion for a value no non-blank
        #     companion can match: an unsatisfiable contract. Those are gated on the base's PRESENCE through a
        #     callable, which costs the exact clause (see below) and is worth it.
        #
        # A gate the COMPARISON answers to COMPOSES with that rule rather than overriding or refusing it — an
        # `if:` on the declaration, one on the `confirmation:` entry itself, or the two together, resolved as
        # ActiveModel resolves them (`_confirmation_entry_gates`). A closed gate suppresses the comparison but
        # does not blank the base's VALUE, so the base-reader rule alone stays open and would enforce a
        # companion for a comparison that never runs — rejecting input nothing then checks. An `if:` therefore
        # becomes the Array `[<comparison gates…>, <rule>]` (ActiveModel ANDs an Array of conditions) and an
        # `unless:` rides along as its own key, so the companion is required on exactly the calls the
        # comparison runs on, and only then.
        #
        # Both departures from the bare Symbol are paid for in the schema, not the runtime: a non-Symbol rule
        # (or both gate keys at once) makes `conditional_requiredness_clause` fall back to UNCONDITIONAL
        # `required` — stricter than the runtime, which is the direction that layer already treats as safe.
        #
        # A companion the author already declared — in this same batch or on the class already, on the same
        # route — is authoritative and suppresses the implicit one entirely, rather than colliding with it.
        # A CONTEXT-SCOPED `confirmation:` entry gets no companion at all (see below).
        def _confirmation_companion_configs(configs, existing:)
          claimed = (configs + existing).map { |c| _declaration_slot(c) }

          configs.filter_map do |config|
            next unless config.validations[:confirmation]

            companion = :"#{config.field}_confirmation"
            next if claimed.include?([companion, config.on.to_s])

            reader = :"#{config.reader_as}_confirmation"
            _parse_field_configs(
              companion,
              on: config.on,
              preprocess: config.preprocess,
              sensitive: config.sensitive,
              reader_names: { companion => reader },
              user_facing: config.user_facing,
              method_call: config.method_call,
              presence: true,
              **config.validations.slice(:type),
              **_confirmation_companion_gates(config),
            ).first.with(confirmation_for: config.field)
          end
        end

        # The gate keys the companion declares: the gates the COMPARISON runs under composed with the rule
        # below (see above). `Array()` flattens a base gate the author wrote as a list into one condition
        # list, so ActiveModel sees a list of conditions rather than a list containing a list — and the lone
        # rule is left UNWRAPPED so the ordinary case stays the bare Symbol the exact-clause emitter requires.
        def _confirmation_companion_gates(config)
          gates = _confirmation_entry_gates(config.validations)
          rule = _confirmation_companion_gate_rule(config)
          gates[:if] = gates.key?(:if) ? Array(gates[:if]) + [rule] : rule
          gates
        end

        # The gates the `confirmation:` ENTRY actually runs under — the tier pair resolved exactly as
        # ActiveModel resolves it, so the companion's requirement is open on precisely the calls the
        # comparison is. Both tiers matter and neither alone is the answer: a declaration-level gate opens
        # and closes every validator on the line together, while the entry's own `if:`/`unless:` OVERRIDES
        # the declaration's per key — including overriding it with a blank value, which un-gates the
        # comparison for that key. `entry_effective_option` carries that precedence and
        # `entry_effective_gate_keys` drops whatever AM would ignore as blank, so a gate the comparison does
        # not answer to never reaches the companion, and one it does can never be lost.
        #
        # Without this the companion would demand input for a comparison that never runs (a disabled
        # confirmation rejecting an omitted companion) or accept an omission the comparison would have
        # judged — either way, requiring something other than what the validator acts on.
        def _confirmation_entry_gates(validations)
          entry = Axn::Validation::Base.validator_entry_options(validations[:confirmation])
          declaration = validations.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)

          Axn::Validation::Base.entry_effective_gate_keys(entry, declaration).to_h do |key|
            [key, Axn::Validation::Base.entry_effective_option(entry, declaration, key)]
          end
        end

        # "The base has a value to confirm", in the strongest spelling this declaration allows: the base's
        # reader as a Symbol where truthiness answers it, else a callable asking presence directly. The
        # callable reads through the validator record, whose `method_missing` delegates to the action — the
        # same route a Symbol condition takes — so both spellings resolve the one settled value.
        #
        # Truthiness answers it only where the two can't diverge. It admits a blank-but-truthy base (`""`,
        # `[]`) that presence would refuse, so the Symbol needs BOTH a base whose own contract rejects those
        # and a comparison that does not excuse them: an `allow_blank:` on the `confirmation:` entry has
        # ActiveModel skip `validate_each` outright for a blank base, and the requirement feeding a
        # comparison must not outlive it. Then the callable, which is exactly the values the comparison is
        # reached with.
        def _confirmation_companion_gate_rule(config)
          return config.reader_as if _confirmation_base_rejects_blank?(config) && !_confirmation_entry_admits_blank?(config.validations)

          reader = config.reader_as
          ->(record) { record.public_send(reader).present? }
        end

        # Whether the COMPARISON itself stands down on a blank base — a truthy `allow_blank:` among the
        # options the `confirmation:` entry runs under. Resolved across both tiers through
        # `entry_effective_option`, the same per-key precedence `_confirmation_entry_gates` reads the gates
        # with, so an entry's own value overrides a declaration-wide one exactly as ActiveModel merges them
        # — including overriding it with `false`. Truthiness is AM's own test for the flag.
        #
        # `allow_nil:` needs no counterpart: the only value it excuses is a nil base, which the rule above
        # already closes on in either spelling.
        def _confirmation_entry_admits_blank?(validations)
          entry = Axn::Validation::Base.validator_entry_options(validations[:confirmation])
          !!Axn::Validation::Base.entry_effective_option(entry, _shared_validation_options(validations), :allow_blank)
        end

        # Whether the BASE's own contract guarantees a non-blank value on the calls its validators run — i.e.
        # whether truthiness of the base reader and "the base has something to confirm" are one question.
        # Decided by the same pair `_reconcile_emptiness_axis!` uses to decide whether a presence check can
        # carry the emptiness axis in place of the flag's own, so the two cannot drift about what a presence
        # entry promises. Asked with `tolerant: false` because the parsed bag no longer carries the
        # declaration flags and a tolerant declaration cannot carry a truthy `presence:` at all (the
        # combination is rejected at declaration), so there is no tolerance tier left to consult.
        def _confirmation_base_rejects_blank?(config)
          _presence_emptiness_answer(config.validations, tolerant: false) == :rejected &&
            _entry_guaranteed_to_run?(config.validations[:presence])
        end

        # Splits already-stored configs into the ones a new batch leaves alone and the IMPLICIT confirmation
        # companions it redeclares explicitly — which the author's own declaration replaces (see
        # FieldConfig#confirmation_for). Returns `[retained, superseded]`; both declaration routes commit
        # `retained + configs` and run their duplicate/collision checks against `retained`, so the author's
        # line lands as though the implicit companion had never been generated.
        #
        # A slot is (wire key, route): a confirmation pair is one route's contract, so a same-named subfield
        # on a DIFFERENT `on:` parent is a different field and is never superseded by this one.
        def _partition_superseded_confirmation_companions(existing, configs)
          redeclared = configs.map { |c| _declaration_slot(c) }
          existing.partition { |c| c.confirmation_for.nil? || !redeclared.include?(_declaration_slot(c)) }
        end

        # The (wire key, route) pair that identifies WHICH declared field a config is. `on:` is compared as
        # text because one route has two supported spellings (a Symbol and a dotted String), exactly as
        # `ContractForSubfields.sibling_confirmation_config` compares it.
        def _declaration_slot(config) = [config.field, config.on.to_s]

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
        # configs. Two passes, matching _define_subfield_readers!: every EXPLICIT declaration's primary
        # reader first, then everything INFERRED (an implicit confirmation companion's own reader, the
        # boolean `?` predicates, the model `<field>_id` readers), so an inferred reader defers to an
        # explicit same-named one regardless of declaration order.
        def _define_field_readers!(configs)
          explicit, inferred = configs.partition { |c| c.confirmation_for.nil? }
          explicit.each { |c| _define_field_reader(c.reader_as, c.field) }

          # An inferred companion yields WHOLE — its own reader and the predicate riding on it — to a
          # same-named method already present, so a deferred companion never leaves half a reader behind.
          # The config still stands and is validated, redacted and reflected exactly as it would be with a
          # reader of its own — validation resolves a reader-less config directly (_validation_reader_for).
          generated = inferred.filter_map do |config|
            next unless _reader_name_available?(config.reader_as, kind: "confirmation companion")

            _define_field_reader(config.reader_as, config.field, target: _inferred_reader_module)
            config
          end

          (explicit + generated).each do |c|
            _define_boolean_predicate_reader(c.reader_as, target: _reader_target_for(c)) if c.boolean?
            _define_model_id_reader(c.reader_as, c.field, c.validations[:model]) if c.validations.key?(:model)
          end
        end

        # An auto-generated companion reader (boolean predicate, model `<field>_id`) defers to any
        # pre-existing method of the same name rather than clobbering it — but, unlike a silent skip,
        # leaves a debug-level breadcrumb so a surprising shadow is discoverable. Returns true when
        # the name is free (caller should define it), false when it's taken (already logged).
        def _reader_name_available?(name, kind:)
          # Read natively here and in the two readers below: `self` is the author's own class, so a singleton
          # `method_defined?`/`instance_method` of its own would otherwise answer a question these guards
          # decide on, and one answering "free" is how a declaration slips past into a taken name.
          return true unless Internal::NativeMethods.declared_instance_method(self, name)

          Axn.config.logger.debug { "[Axn] #{self.name || 'Action'}: skipping auto-generated #{kind} reader `#{name}` (already defined)" }
          false
        end

        # Where a config's readers are defined: an implicit confirmation companion's into the inferred
        # module (withdrawable, and outranked by anything the author wrote), everything else onto the
        # class itself.
        def _reader_target_for(config) = config.confirmation_for ? _inferred_reader_module : self

        # The module this class's inferred readers live in, created — and included, so it sits directly
        # below the class — the first time one is generated. Per class, never inherited: a subclass's own
        # inferred readers land in its own module while a superclass's stay in the superclass's, so
        # withdrawing one never reaches across that boundary.
        def _inferred_reader_module
          @_inferred_reader_module ||= InferredReaders.new.tap { |mod| include mod }
        end

        # Whether the method currently answering to `name` is one axn INFERRED rather than one an explicit
        # declaration generated or the author wrote. An inferred reader is not a declaration, so a clash
        # with one is never the explicit-vs-explicit conflict the collision guards raise on: the explicit
        # name wins and the inferred reader yields.
        def _inferred_reader?(name)
          method = Internal::NativeMethods.declared_instance_method(self, name)
          return false unless method

          Internal::Identity.kind?(method.owner, InferredReaders)
        end

        # Whether the method answering to `name` is a reader axn GENERATED on the class from a
        # declaration — as opposed to one the author wrote. Identified by generation site, the same
        # signal schema reflection uses to tell the two apart (Reflection::Schema#framework_generated_reader?).
        # The owner must be a Class: every generated reader is defined onto the action class itself, while
        # axn's own sugar lives in MODULES that share the same source file.
        def _axn_generated_reader?(name)
          method = Internal::NativeMethods.declared_instance_method(self, name)
          return false unless method

          Axn::Internal::Identity.kind?(method.owner, ::Class) &&
            method.source_location&.first == GENERATED_READER_SOURCE_PATH
        end

        # Whether the method answering to a config's reader name belongs to something OTHER than the config:
        # an INFERRED reader that yielded (a confirmation companion deferring to a method the author wrote or
        # to an explicit declaration's reader). Such a config has no reader of its own, so dispatching the
        # name answers with the shadowing method's value rather than the declared input — every consumer must
        # resolve the config directly instead. THE single definition of that question, shared by inbound
        # validation (_validation_reader_for) and canonical parent resolution
        # (ContractForSubfields.resolve_parent), so no consumer can read a deferred companion through the
        # method shadowing it while another reads its wire value.
        def _reader_deferred?(config)
          !config.confirmation_for.nil? && !_inferred_reader?(config.reader_as)
        end

        # The reader inbound validation may read a config's value through, or nil when it must resolve the
        # config directly. A subfield's reader IS its value (memoized, model-resolving, default-applying),
        # so validation reads it — but only when it is the reader axn generated FOR THIS CONFIG. A DEFERRED
        # inferred companion is the exception: that name belongs to a method the author wrote, so reading it
        # would validate that method's answer instead of the declared input, and the comparison — which
        # resolves the config directly — would then judge the two halves of one pair by two different
        # values. A top-level field never reads through a reader at all (its source is the context facade).
        def _validation_reader_for(config)
          return nil unless config.subfield?
          return nil if _reader_deferred?(config)

          config.reader_as
        end

        # Withdraws the reader an implicit companion generated, once the author's own declaration has
        # superseded the config behind it — otherwise the memoized method survives its config and answers
        # with rules the explicit declaration replaced. The boolean `?` predicate goes with it: an alias is
        # an independent COPY of the body, so a predicate left behind keeps resolving through the superseded
        # config on its own, applying the base's rules under a name the explicit declaration now owns.
        def _withdraw_inferred_reader!(name)
          [name, :"#{name}?"].each { |method_name| _withdraw_inferred_method!(method_name) }
        end

        # Only a method an inferred module OWNS is touched, so a method the author wrote (one the companion
        # deferred to) or an explicit declaration's reader is left standing — the same ownership rule that
        # governs whether a reader is generated in the first place, asked per method name so a predicate that
        # deferred while its primary reader did not (or the reverse) is judged on its own. An owning module
        # further up the ancestry belongs to a SUPERCLASS whose own companion still stands there, so the name
        # is undefined on this class alone rather than removed from that module.
        def _withdraw_inferred_method!(name)
          return unless _inferred_reader?(name)

          owner = instance_method(name).owner
          owner.equal?(@_inferred_reader_module) ? owner.remove_method(name) : undef_method(name)
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

        # `target` is the module the method lands in — the class itself for a declared field, the inferred
        # module for a reader axn derived from another declaration. The block is written here either way,
        # so a generated reader still reports GENERATED_READER_SOURCE_PATH.
        def _define_field_reader(reader, source = reader, target: self)
          # Allow local access to explicitly-expected fields on the action instance.
          # NOTE: exposes fields are intentionally excluded — access those via result.field instead.
          # `reader` is the method name (may be aliased via as:/prefix:); `source` is the wire key
          # the value actually lives under in the inbound context.
          #
          # Bound rather than dispatched: this body runs on the USER's class, so a sibling declaration
          # (`expects :internal_context`) or a `def` would otherwise redirect EVERY field's read at the
          # user's own value — the shadow costing them every reader instead of the one helper.
          target.define_method(reader) { Axn::Internal::ActionState.internal_context(self).public_send(source) }
        end

        # Aliased in the same module as the reader it points at (an alias can only name a method its own
        # module holds), so a predicate riding on an inferred reader is withdrawn with it.
        def _define_boolean_predicate_reader(field, target: self)
          field_name = field.to_s
          return if field_name.end_with?("?")

          predicate_name = "#{field_name}?"
          return unless _reader_name_available?(predicate_name, kind: "boolean predicate")

          target.alias_method predicate_name, field
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

        # Whether a validator entry must be held OUT of the declaration's `optional:`/`allow_blank:`/
        # `allow_nil:` tolerance. Exactly one is. The pair is stated on the declaration, so `validates` applies
        # it to every validator; an exempt entry is given an explicit `allow_blank: false, allow_nil: false`,
        # which overrides the declaration tier per key exactly as ActiveModel's own merge order does.
        #
        # This is narrower than it looks: ActiveModel's ConfirmationValidator already returns without
        # comparing when the COMPANION is nil (measured against activemodel 7.2.2.2: `unless (confirmed =
        # record.public_send("#{attribute}_confirmation")).nil?`), so a tolerance would only ever reach the
        # case of a supplied, contradicting companion — never the "nothing to confirm" case its name suggests.
        #
        # This is the ONLY tolerance push-down `confirmation:` is exempt from. The separate nil-skip push-down
        # (`_apply_nil_skip_to_non_type_validators!`, below) does not check this predicate and so does relax a
        # `confirmation:` entry on a field whose `type:` rejects nil — `expects :password, type: String,
        # confirmation: true` stores `confirmation: { allow_nil: true }`. Harmless: a nil base has already
        # failed its own type check by the time the comparison would run, so the relaxed entry never gets
        # asked to wave through a real mismatch.
        def _tolerance_exempt_validator?(key) = key == :confirmation

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
        # The `of:` branch below is the same seam deliberately, not a guard that happens to sit here: it reads
        # the bag the expansion just produced (`type:`'s klass list, `of:`'s own bag), so its checks are the
        # ones canonicalizing MAKES possible, and splitting them from it is what let a member expand like a
        # field and validate like nothing. They are one rule with two halves — the option only means something
        # over a container, and it must name what is inside that container — and neither has any runtime
        # counterpart to fall back on: `OfValidator` returns before it inspects a value of the wrong shape, so
        # `of:` beside `type: String` never applies at all, while `of: nil` reached `check_validity!` and
        # raised on every call instead of at the author.
        def _canonicalize_validator_options!(validations, fields)
          validations[:type] = Axn::Validators::TypeValidator.apply_syntactic_sugar(validations[:type], fields) if validations.key?(:type)
          _reject_unsupported_type_klass!(validations)
          _reject_falsy_model_klass!(validations)
          validations[:model] = Axn::Validators::ModelValidator.apply_syntactic_sugar(validations[:model], fields) if validations.key?(:model)
          _reject_unsupported_model_klass!(validations)
          if validations.key?(:validate)
            validations[:validate] = Axn::Validators::ValidateValidator.apply_syntactic_sugar(validations[:validate], fields, nested: false)
          end
          return unless validations.key?(:of)

          container = _of_container!(validations)
          _drop_derived_of_container!(validations, container)
          validations[:of] = container.equal?(::Hash) ? _canonical_map_of!(validations, fields) : _canonical_array_of!(validations, fields)
        end

        # `of:` names what is INSIDE a container, so the declared type is what decides which grammar the bag is
        # held to: an Array has elements, a Hash has keys and values. Derived here and stored in the bag, so the
        # validator dispatches on what was DECLARED rather than on the value it is handed — a Hash arriving under
        # `type: Array` is a type error, not a map.
        #
        # A union names no single container, which is the same situation `shape:` refuses for the same reason.
        def _of_container!(validations) = _declared_of_container!(validations.dig(:type, :klass), option: "type:")

        # The derivation itself, over the declared class alone, because the two callers name that class with two
        # different keys: a FIELD names it in `type:`, an inner-contract bag in `klass:` (which plays `type:`'s
        # role inside a bag — see `_inner_of_container!`). Taking the class rather than a `validations`-shaped
        # Hash is what keeps the one rule one function: a bag carries no `:type` at all, so the alternative was
        # to fabricate a wrapper Hash here and have the shared code read a key that exists only to be read.
        #
        # `option:` travels with it for the same reason the derivation is shared: one rule, but the option an
        # author has to EDIT differs by where they wrote it, and a refusal naming a key the declaration does not
        # carry prescribes a fix with nowhere to land. Supplied by the caller rather than inferred, so the two
        # spellings cannot drift apart from the two call sites.
        def _declared_of_container!(declared_klass, option:)
          # `_declared_type_tokens`, not `Array(declared_klass)`: the latter tries the value's own `to_ary`
          # (then `to_a`) before wrapping it, so a caller-supplied klass defining either decided how it got
          # read here — a `to_ary` returning `[Array]` would wave a genuinely unsupported `type:` through as
          # though it named the container directly, and one that raises would replace this declaration error
          # with whatever it threw (PRO-3207, Codex review round 4).
          declared = _declared_type_tokens(declared_klass)
          container = declared.first if declared.size == 1
          # Identity, not `==`: the declared class is the caller's, and one answering `==` for its own
          # purposes would otherwise choose which grammar its bag is held to.
          return container if container.equal?(::Array) || container.equal?(::Hash)

          # Each declared class is named through the seam that reads its name natively, never by rendering the
          # LIST: `Array#inspect` dispatches every element's own `inspect`, so a declared class defining one
          # that raises would replace this ArgumentError with the caller's exception — which outside
          # StandardError escapes every rescue meant to settle it. The rendering is byte-identical to the list's
          # for every ordinary class.
          raise ArgumentError, "of: requires #{option} Array or Hash (got [#{declared.map { |k| _declared_type_label(k) }.join(', ')}])"
        end

        # This seam runs over a shape MEMBER's bag twice — once as the member is built like a field
        # (`_build_shape_member` → `_parse_field_configs`), and again as the declaration walk snapshots it
        # (`ShapeDeclaration#_symbol_keyed_member_validations`). What the second pass receives is neither the
        # same object as the first pass produced nor the same content: between them the tolerance push
        # (`_parse_field_validations`'s tolerant branch and `_apply_nil_skip_to_non_type_validators!`) rebuilds every
        # validator entry with the field's shared options merged in, so the bag arrives carrying `allow_nil:`/
        # `allow_blank:` that no author wrote. That is why `OF_OPTION_KEYS`/`MAP_OF_OPTION_KEYS` carry
        # `shared_validation_option_keys` — a correctness requirement rather than permissiveness, since a
        # whitelist without them would have the second pass refuse the very keys axn itself merged in.
        # `container:` is derived on the same terms, so without this the second pass reports axn's own key as
        # one the grammar does not support and fails a well-formed declaration. `shaped_keys:` (the map's
        # exempt set — see `_derive_shaped_keys!`) is derived later in the pass but stored in the same bag, so
        # it goes the same way: dropped here and derived again, never carried across.
        #
        # Dropped rather than returned early on, so every check runs on every pass and nothing rides in on the
        # second one. And dropped ONLY when it names the container just derived: a bag naming a DIFFERENT one
        # did not come from here, so it falls through to the whitelist and is refused there. What that leaves is
        # a hand-written `container:` agreeing with the declared `type:`, which nothing distinguishes from a
        # derived one — so it is discarded and derived again, redundant rather than authoritative. Mutates
        # `validations`.
        def _drop_derived_of_container!(validations, container)
          bag = Internal::ShapeGraph.hash_or_nil(validations[:of])
          return if nil.equal?(bag)
          return unless container.equal?(bag[:container])

          validations[:of] = bag.except(:container, :shaped_keys)
        end

        # An Array holds one kind of thing, so the bare form says everything there is to say and expands into the
        # bag `OfValidator` reads. A bag has to CONSTRAIN something: `klass:` names the element's class and `of:`
        # names what is inside it — a bag with neither is the silent no-op this option exists to refuse.
        #
        # ONE rung only. A bag's own `of:` is canonicalized by the declaration walk that descends onto it
        # (`_canonicalize_inner_contract!`, driven from `_walk_inner_contracts!`) rather than by recursing from
        # here, because recursing from here recurses over the CALLER's graph with no bound of any kind: `h[:of]
        # = h` is reachable by hand, and it ended this method in `SystemStackError` — outside StandardError,
        # raised while the class is being defined — before any guard could report it.
        def _canonical_array_of!(validations, fields)
          bag = Axn::Validators::OfValidator.apply_syntactic_sugar(validations[:of], fields)
          _check_inner_contract_bag!(bag, fields)

          bag.merge(container: ::Array)
        end

        # A bag's own keys are canonicalized where the bag is accepted (`_symbolize_inner_bag!`, and the field
        # path's `_symbolize_option_bags!` for the top-level one). Its VALIDATOR ENTRIES carry option bags of
        # their own — `format: { with: … }` — and ActiveModel reads those keys as Symbols too: a String-keyed
        # `"with"` arrives at `FormatValidator#check_validity!` as no `:with` at all and raises `ArgumentError`
        # on EVERY call, which is the declares-cleanly-then-always-raises shape the bag grammar exists to
        # remove. The field path already canonicalizes them one level down; this holds a bag to the same
        # grammar, through the same function rather than a second symbolizer.
        #
        # Restricted to the validator entries: `of:` and `shape:` are the recursion edges and are canonicalized
        # by the walk that descends them, and `klass:`/`message:` are not option bags at all. The symbolized
        # bag is a NEW Hash (`_symbol_keyed_bag` builds one), so the caller's own nested Hash is never mutated.
        def _canonicalize_positional_validator_options!(bag, fields)
          entries = bag.slice(*POSITIONAL_VALIDATOR_KEYS)
          return if entries.empty?

          _symbolize_option_bags!(entries)
          # DETACHED as well as symbolized, and unconditionally: `_symbolize_option_bags!` builds a new Hash only
          # when a key actually needs converting, so the ordinary Symbol-keyed spelling took its no-op path and
          # the caller's option bag stayed stored by reference — `opts[:in] << "b"` then widened an
          # already-declared contract. That is the aliasing rule exactly: "nothing needs changing" is a
          # different question from "nothing needs copying".
          #
          # The field path is safe because `detach_option_containers!` reaches ITS validator entries directly.
          # A bag's entries sit one level further down, where `detached_option_bag` copies a nested Hash by
          # reference — it detaches nested Arrays only — so the same seam is applied here, to the entries.
          Internal::ShapeGraph.detach_option_containers!(entries)
          entries.each { |key, value| bag[key] = value }
          # `validate:` is the one admitted validator carrying a DSL-misuse guard of its own, and it has to run
          # HERE as well as on the field path: without it `validate: { inclusion: … }` declared cleanly and then
          # raised a bare `must supply :with` out of `check_validity!` on EVERY call — the
          # declares-cleanly-then-always-raises shape this grammar exists to remove. The other three validators
          # with a sugar step need no equivalent: `type:` and `model:` are refused at a bag position outright,
          # and the bag's own `of:` is expanded where the bag is accepted.
          return unless Internal::ShapeGraph.carries_key?(bag, :validate)

          bag[:validate] = Axn::Validators::ValidateValidator.apply_syntactic_sugar(bag[:validate], fields, nested: true)
        end

        # `optional:` is the sugar a NAMED position takes, canonicalized here into the pair the runtime and the
        # emitter read — the same fold `_parse_field_configs` performs for a field (`allow_blank ||= optional`),
        # through the same meaning: "optional" is blank-tolerance, which subsumes nil.
        #
        # Runs ahead of every other check on the bag, so none of them ever judges a bag carrying two spellings
        # of one fact. Idempotent, which the walk requires: this seam runs over a shape member's bag twice, and
        # the second pass finds the key already folded away.
        #
        # A FALSY `optional:` is dropped rather than written as `allow_blank: false`. It is the absence of
        # tolerance, which is the default, and writing the negative would make an explicit `allow_nil: true`
        # beside it read as a contradiction the author did not declare.
        #
        # Both keys are then STATED explicitly on every bag, even one naming neither — the pair a field records
        # is on the DECLARATION now, not copied into each validator entry (PRO-3225), and `validates` still
        # merges that declaration tier into every validator it builds from the same call as its own defaults
        # (`defaults.merge(entry)`, ActiveModel's own build step), `of:` included. Left implicit, a bag with no
        # tolerance of its own would silently inherit whatever the FIELD's `allow_nil:`/`allow_blank:` says —
        # `optional: true` on the field would legalise a nil ELEMENT nothing at this position asked for. Writing
        # the pair here makes the bag's own (possibly false) answer the one AM's merge cannot override: an
        # entry's own key always wins over the tier it rides beside. The same explicit-override device
        # `_parse_field_validations` already uses to hold `confirmation:` out of that same tier.
        def _canonicalize_bag_tolerance!(bag)
          if Internal::ShapeGraph.carries_key?(bag, :optional)
            optional = bag.delete(:optional)
            bag[:allow_blank] = true if optional
          end

          bag[:allow_nil] = !!bag[:allow_nil]
          bag[:allow_blank] = !!bag[:allow_blank]
        end

        # The grammar EVERY inner-contract bag is held to, asked once wherever one is accepted: at an Array's
        # element position and at each of a map's two axes. One function rather than three call sequences,
        # because a bag means the same thing in all three and a check missing from one of them is a hole the
        # other two hide.
        #
        # A non-Hash `shape:` is refused for the same reason and is deliberately NOT here: it can be written at
        # two positions this function never sees (a field's own `shape:`, a shape MEMBER's), so it is one
        # refusal at the walk that reaches all four (`ShapeDeclaration#_reject_unshaped_shape!`).
        def _check_inner_contract_bag!(bag, fields)
          _canonicalize_bag_tolerance!(bag)
          _canonicalize_positional_validator_options!(bag, fields)
          _reject_unknown_of_keys!(bag, OF_OPTION_KEYS)
          _reject_unconstraining_of_bag!(bag)
          _reject_unsupported_of_klass!(bag)
          _reject_inner_contract_context_scope!(bag, fields)
          _reject_inner_contract_strict!(bag, fields)
          _reject_unusable_of_message!(bag, fields)
          _reject_positional_bag_validators!(bag, fields)
        end

        # A bag's `klass:` is held to exactly the grammar a map's BARE axis is, by the same predicate: it plays
        # `type:`'s role inside a bag, so a token outside that grammar reaches `value.is_a?(token)` and raises a
        # bare `TypeError: class or module required` on every call, naming neither the field nor the option.
        # Asked here rather than beside each of the positions a bag sits at, because the bare-axis refusal
        # deliberately SKIPS a Hash-valued axis (that axis is a bag, judged by this function) — so without this
        # every bag spelling of the defect the axis guard exists to refuse declared cleanly: at an Array's
        # element, at either axis of a map, inside a bag nested in either, and inside a shape member's own `of:`.
        #
        # Emptiness is NOT asked here. An absent `klass:`, a nil one and an empty union are one case for
        # `_reject_unconstraining_of_bag!` a line earlier, which owns the message that names it — and the other
        # two axes constrain without naming a class at all, so a guard keyed on "no usable token" rather than on
        # one the author SUPPLIED would refuse `of: { shape: … }`.
        #
        # A bag naming its own `of:` is skipped, and deferred to rather than preempted: `_inner_of_container!`
        # holds that `klass:` to the strictly narrower rule (Array or Hash, since the class it names is what
        # decides how the nested bag reads), so it refuses every token this would AND names the two classes that
        # are legal there. Firing first would prescribe the weaker fix and cost the author a second edit. Keyed
        # on `_of_axis_constrains?` rather than on the key's presence, so a bag carrying `of: nil` — which that
        # rule reaches by a path of its own — is still judged here.
        def _reject_unsupported_of_klass!(bag)
          return if _of_axis_constrains?(bag, :of)
          return unless Internal::ShapeGraph.carries_key?(bag, :klass)

          _reject_unsupported_type_token!(_declared_type_tokens(bag[:klass]), "of: klass:")
        end

        # The field-level half of the rule `_reject_unsupported_of_klass!` holds a bag's `klass:` to (PRO-3207):
        # a `type:` naming a token the runtime cannot hold a value to reaches `value.is_a?(token)` and raises a
        # bare `TypeError: class or module required` on every call, naming neither the field nor the option.
        # This is the last position of the defect PRO-3165/PRO-3166 closed everywhere else — it isn't an `of:`
        # bag position, so neither of those guards ever saw it.
        #
        # Emptiness IS asked here, unlike the bag's `klass:` — a field's `type:` has no second option left to
        # constrain it (a bag also has `of:`/`shape:`), so `type: nil` / `type: []` are the bare-axis situation,
        # not the bag one, and fold into this guard exactly as `_reject_unsupported_map_axis!` folds them into
        # itself rather than deferring.
        #
        # Deferred when `of:` is also declared: `_declared_of_container!` runs UNCONDITIONALLY whenever `:of`
        # is present, no matter what it contains, and holds `type:` to a strictly narrower rule (Array or
        # Hash only, since that class decides how `of:` reads) — naming the classes that are actually legal
        # there. Firing here first would prescribe the weaker fix and cost the author a second edit.
        #
        # Deliberately NOT deferred to `shape:`, even though a shape's own container check often ALSO judges
        # `type:` (`_shape_compatible_type!` derives the container from it when the shape supplies none) —
        # unlike `of:`, that path is not unconditional: a shape supplying its own already-valid `container:`
        # skips derivation entirely, and the container check that runs instead judges the CONTAINER, not
        # `type:`. Detecting which of those two states applies means reading the shape's own `container:` —
        # a caller-suppliable value — a second time independent of whatever the container-derivation code
        # reads it as, and a `[]` that answers differently between the two reads (a hostile object, never an
        # ordinary Hash) could make each side see a different verdict and let a bad `type:` through neither
        # check. Checking `type:` here UNCONDITIONALLY whenever `shape:` is present removes the need to
        # predict the other path's behavior at all — this guard's own verdict never depends on a second read
        # of anything. The cost is one changed message: a bad `type:` beside a `shape:` now reports this
        # guard's `type:`-specific wording (which the previous per-position spec pinned as the SHAPE's own
        # "container: must be a class" message) instead — still an `ArgumentError` at declaration, and
        # arguably the more directly useful one, since `container:` is often not a key the author wrote at
        # all.
        def _reject_unsupported_type_klass!(validations)
          return unless validations.key?(:type)
          return if validations.key?(:of)

          declared = _declared_type_klass(validations)
          tokens = _declared_type_tokens(declared)
          raise ArgumentError, _unsupported_type_token_message("type:", declared) if tokens.empty?

          _reject_unsupported_type_token!(tokens, "type:")
        end

        # `ModelValidator.apply_syntactic_sugar`'s `options[:klass] ||= fields.first.to_s.classify` treats
        # EVERY falsy `klass:` — not just the `true`/absent spellings that mean "please infer" — as a request
        # to infer: `model: false` and `model: {klass: nil}` fall into the same `||=` as `model: true` and
        # silently become "please infer" too, an accident of `||=` treating `false` and `nil` as
        # indistinguishable from "not yet set" (PRO-3207, Codex review round 4). That makes the SAME
        # declaration mean two different things depending on unrelated global state: `model: false` raises
        # `NameError: uninitialized constant User` when no such constant exists, and silently, successfully
        # resolves through `User` when one happens to — an author's boolean typo (`false` for `true`) either
        # blows up or quietly works depending on what else the app happens to define.
        #
        # Never documented as a spelling (`model: true`/`model: TheModelClass`/`model: { klass:, finder: }`
        # are the only ones `docs/reference/class.md` and `AGENTS-consuming.md` show), so nothing legitimate
        # is given up by refusing it outright — but it must run BEFORE the sugar's `||=` erases the
        # distinction between "explicitly false/nil" and "not supplied at all", which is why this is a
        # separate guard rather than folded into `_reject_unsupported_model_klass!` below (that one runs
        # AFTER sugar, once the erasure has already happened). Keyed on `carries_key?`, not mere nil-ness, so
        # an absent `klass:` — the legitimate `model: { finder: :find_by_slug }`, which infers the class and
        # only overrides the finder — is untouched; only a `klass:` the author WROTE, and wrote as `false`
        # or `nil`, is refused. `true` is excluded on the same terms: it is the one falsy-adjacent value that
        # unambiguously means "please infer", checked by identity (`.equal?`) so a caller's own `==` never
        # decides whether its object reads as `true`.
        def _reject_falsy_model_klass!(validations)
          return unless validations.key?(:model)

          raw = validations[:model]
          bag = Internal::ShapeGraph.hash_or_nil(raw)

          if nil.equal?(bag)
            klass = raw
          else
            return unless Internal::ShapeGraph.carries_key?(bag, :klass)

            klass = bag[:klass]
          end

          return unless false.equal?(klass) || nil.equal?(klass)

          raise ArgumentError,
                "model: klass: false/nil is not a type to resolve a record through — pass `model: true` (or " \
                "omit klass: entirely) to infer the class from the field name, or name the class explicitly."
        end

        # `model:`'s `klass:` has the identical hole `_reject_unsupported_type_klass!` closes for `type:` —
        # `ModelValidator#validate_each` builds a `TypeValidator` over the same bag and delegates, so a token
        # outside its grammar reaches the same `value.is_a?(token)` and raises the same bare
        # `TypeError: class or module required` on every call (PRO-3207).
        #
        # The grammar is narrower than `type:`'s, deliberately not `_reject_unsupported_type_token!`: a model
        # field resolves a record by calling a finder method ON its `klass:` (`FieldResolvers::Model`), never
        # by asking a value `is_a?` of it, so there is nothing for a union or a pseudo-type Symbol to
        # dispatch through — one class or module, never a list of them. A union additionally passed
        # `TypeValidator`'s own check (which iterates a union happily) only for the resolver to call
        # `Array#find` instead of the class's own finder, silently resolving to the wrong thing under
        # `best_effort` rather than raising at all — this closes that too, since neither hole has a
        # legitimate use to preserve (no spec, doc, or downstream consumer declares `model:` with a union or
        # a pseudo-type).
        #
        # `_reject_falsy_model_klass!` (above) already refused the one falsy `klass:` that `apply_syntactic_sugar`
        # would otherwise silently reinterpret as "please infer" — so by the time this runs, whatever
        # survived is either a real Class/Module (or a String already `constantize`d into one) or a value
        # nothing upstream could make sense of either.
        def _reject_unsupported_model_klass!(validations)
          return unless validations.key?(:model)

          klass = validations[:model][:klass]

          case klass
          when ::Module then return
          end

          raise ArgumentError,
                "model: klass: must name a single Class or Module (got #{_declared_type_label(klass)}) — a " \
                "model field resolves a record by calling a finder method on this class, so a union or a " \
                "pseudo-type has nothing to dispatch through."
        end

        # `on:` inside a bag is the same dead declaration it is inside any other validator's option bag, and it
        # reaches positions the field-level check cannot see: a bag nested inside another bag, and either axis
        # of a map (PRO-3166). `_reject_validator_context_scope!` scans the FIELD's validator ENTRIES, so it
        # sees the field's own `of:` and nothing below it. Asked of the bag directly here, through the same
        # predicate that scan uses, so one rule decides it at every position.
        #
        # Unlike the other shared options, `on:` is dead at ALL of those positions rather than only some — see
        # `AXIS_INERT_OPTION_KEYS` for the split. Where ActiveModel does read the bag, `validate` installs a
        # gate of `!(Array(options[:on]) & Array(validation_context)).empty?`, and axn calls `valid?` with no
        # context, so the intersection is empty on every call; where it does not, the key is simply dropped.
        # One defect, one message.
        #
        # It fires for the field's own `of:` bag and for a map's `of:` bag as well, ahead of the entry scan,
        # which is deliberate: this message names the bag the author wrote rather than the validator key it
        # rode in on, and one spelling of one defect should not read two ways.
        def _reject_inner_contract_context_scope!(bag, fields)
          return unless Axn::Validation::Base.entry_context_scoped?(bag)

          _raise_validator_context_scope!("an `of:` bag", _declared_fields_label(fields), "that check runs")
        end

        # The bag-level twin of `_reject_strict_validation!`'s entry scan, for the reason that pair exists on the
        # context-scope side: the field's own `of:` IS an entry, so the scan sees it, but a bag nested inside one
        # and a map's axis are reached only by the declaration walk. Asked of the bag directly here, through the
        # same predicate the scan uses, so one rule decides it at every position.
        #
        # It fires for the field's own `of:` bag as well, ahead of the entry scan, which is deliberate: this
        # message names the bag the author wrote rather than the validator key it rode in on, and one spelling of
        # one defect should not read two ways.
        def _reject_inner_contract_strict!(bag, fields)
          return unless Axn::Validation::Base.entry_declares_strict?(bag)

          _raise_strict_validation!("an `of:` bag", _declared_fields_label(fields))
        end

        # A `message:` replaces the type description a mismatch reports, so a bag naming no class has nothing
        # for it to replace: `OfValidator#matches_axis?` waves every value through an empty class list, the
        # mismatch branch is never reached, and the message the author wrote is never emitted. Reachable since
        # `shape:` joined the bag grammar — `of: { shape: S, message: "…" }` is a bag that constrains something
        # and still names no class — and now at both map axes as well.
        #
        # Emptiness is asked exactly as the runtime asks it (`Array(...).empty?`), so the guard and the consumer
        # cannot disagree about which bags have a mismatch to describe: an absent `klass:`, a nil one, and an
        # empty union are one case here because they are one case there. `_reject_unconstraining_of_bag!` asks
        # the same question a step earlier and refuses the empty union outright, so what reaches this in a
        # DECLARED contract is a bag constraining by `of:` or `shape:` and naming no class — but the question is
        # still asked the same way, because a third spelling of "names no class" is the drift these two exist
        # to prevent.
        def _reject_unusable_of_message!(bag, fields)
          return unless Internal::ShapeGraph.carries_key?(bag, :message)
          return unless Array(bag[:klass]).empty?

          raise ArgumentError,
                "of: message: on #{_declared_fields_label(fields)} has nothing to describe — a `message:` " \
                "replaces the type description a mismatch reports, and this bag names no `klass:`, so nothing " \
                "at that position is ever a type mismatch and the message can never be emitted. Name the class " \
                "the message is about (`klass:`), or drop message:."
        end

        # The shared ActiveModel options an AXIS bag cannot honour, and so may not carry. Every OTHER position a
        # bag sits at is an ActiveModel validator entry, where AM reads these and they are live: the field's own
        # `of:` bag is an entry on the field, and a nested ELEMENT bag becomes one on the next level's
        # `ContainerContents` validator, since `OfValidator#inner_contract_validations` hands it over verbatim
        # under `:of`. An axis bag is never handed to AM at all — `OfValidator#axis_contract` reads it directly
        # — so a GATE written there is dropped rather than applied, and the axis constrains less than its
        # declaration says. Measured: `of: { klass: Array, of: { klass: Integer, if: -> { false } } }` lets
        # `[["x"]]` through, while `of: { values: { klass: Integer, if: -> { false } } }` still rejects
        # `{a: "x"}`.
        #
        # The TOLERANCE keys are not here, because they are not read by ActiveModel at any position: they state
        # what the position itself admits, not a context AM gates a validator entry on. A later step makes
        # `OfValidator` resolve them off the bag directly, at every position, so an axis will state its
        # tolerance exactly as an element bag does.
        #
        # `on:` and `strict:` are left out because `_check_inner_contract_bag!` has already refused each a step
        # earlier, naming the real problem — axn has no validation contexts, and no strict-raising mode — both of
        # which are true at every position rather than at this one. Listing either here would offer "drop it, the
        # axis reads nothing" where the messages above name what axn does not have.
        AXIS_INERT_OPTION_KEYS = (Axn::Validation::Base.shared_validation_option_keys -
                                  %i[on strict allow_nil allow_blank]).freeze

        # Every offender at once: an author who wrote two of them has one declaration to fix. The keys are
        # axn's own frozen Symbols, so naming them runs nothing of the caller's.
        def _reject_inert_axis_options!(bag, axis, fields)
          offenders = AXIS_INERT_OPTION_KEYS.select { |key| Internal::ShapeGraph.carries_key?(bag, key) }
          return if offenders.empty?

          raise ArgumentError,
                "of: #{axis}: does not support #{offenders.map { |key| "#{key}:" }.join(', ')} on " \
                "#{_declared_fields_label(fields)} — an axis is the one position an `of:` bag is never handed " \
                "to ActiveModel as a validator entry, so those options are read by nothing and the axis would " \
                "constrain less than it says. Drop them. A gate deciding whether the `of:` runs at all belongs " \
                "on the field's own declaration, where ActiveModel does read it."
        end

        # The field(s) a declaration error names, each through the shared name seam: a field name is the
        # caller's Symbol and reaches this only on the failure path, so nothing of its own is run to build it.
        def _declared_fields_label(fields) = fields.map { |field| _inspect_field_name(field) }.join(", ")

        # The axes a bag can constrain on. Keyed on `key?` rather than on truthiness, so a supplied-but-nil axis
        # is caught by this check rather than passing as one that was named.
        INNER_CONTRACT_AXES = %i[klass of shape].freeze

        # Whether one axis of a bag actually constrains. `klass:` asks EMPTINESS rather than presence, because
        # a class union is what `OfValidator#matches_axis?` iterates and an empty one holds a value to nothing:
        # `of: []` (sugar for `of: { klass: [] }`) declared cleanly, waved every element through, and emitted
        # `items: { anyOf: [] }` — a schema no element satisfies — so document and runtime disagreed in the
        # LOOSENING direction. Asked with `Array(...).empty?`, which is exactly how the runtime asks it and
        # exactly how `_reject_unusable_of_message!` asks it, so no two of the three can disagree about which
        # bags name a class. The other two axes are Hashes rather than lists, so presence is all there is.
        def _of_axis_constrains?(bag, axis)
          return false unless Internal::ShapeGraph.carries_key?(bag, axis)
          return !Array(bag[axis]).empty? if axis == :klass

          !bag[axis].nil?
        end

        # WHY an empty union is a defect, in the words shared by every position one can be written at: a bag's
        # `klass:` and a map's two axes. The three differ in what an author has to EDIT, never in what went
        # wrong — so the diagnosis is one string and only the remedy is per-position. Without this, the same
        # mistake read as three unrelated ones, and the map axes reported neither: an empty `values:` landed on
        # "name the axis you are constraining", which asks for the key the author had just written (PRO-3170).
        #
        # The RUNTIME consequence only, and deliberately no schema one. An empty union holds a value to nothing
        # wherever it is written, at every position and every depth — but what the SCHEMA does with it depends
        # on the position's ANCESTRY, which no bag can see from the point it is refused at: a `keys:` axis emits
        # nothing (every JSON object key is already a String, so there is no keyword to carry a constraint), and
        # neither does anything nested under one, at any depth. Measured: `of: { keys: [Symbol, String] }` and
        # `of: { keys: { klass: [Symbol, String] } }` both emit `{"type":"object","minProperties":1}` and no
        # `anyOf`, while the `values:` spelling of each emits `additionalProperties.anyOf`.
        #
        # So the earlier "the schema emits `anyOf: []`, which nothing satisfies" was true of an Array's element
        # and a map's `values:` and false of `keys:` — and threading enough ancestry to tell them apart would
        # put a walk-shaped parameter through five call sites to decorate an error message, with a wrong clause
        # at depth as the failure mode. The refusal states what is unconditionally true instead (PRO-3170).
        EMPTY_UNION_DIAGNOSIS = "a value held to every class in an empty list is held to none, so every value " \
                                "at that position passes"

        # The remedy half for the position an empty union sits at when it is a map's AXIS rather than a bag's
        # `klass:`. Separate from the `klass:` wording because the fix genuinely differs: a bag has `of:` and
        # `shape:` to fall back on, so dropping its empty `klass:` is real advice, while a map needs at least
        # one constraining axis — telling an author to simply drop theirs would send them to the "name an axis"
        # refusal on the next declaration. Takes the AXIS rather than a rendered option label, since the axis is
        # the key the author has to edit and only the caller knows which was written.
        def _empty_union_axis_message(axis)
          "of: #{axis}: names an empty union, so that axis constrains nothing — #{EMPTY_UNION_DIAGNOSIS}. " \
            "Name the class(es) that axis must hold, or drop the axis and constrain the other one — an axis " \
            "left off is the honest spelling of \"unconstrained\", while one naming nothing only looks like " \
            "a constraint."
        end

        # Whether an axis was SUPPLIED as an empty union, which is the one "names no class" spelling this
        # message is for. Deliberately narrower than `_axis_names_no_class?`: a nil axis and an absent one name
        # nothing either, but neither is an empty UNION, so both keep whatever refusal they already had —
        # "name the axis you are constraining" when nothing else on the bag constrains, and `must name a type
        # … NilClass` from `_reject_unsupported_map_axis!` when a sibling axis does. `nil` mirrors a bag's
        # `klass: nil`, which lands on "must constrain something" rather than on the empty-union message.
        #
        # Asked through `_declared_type_tokens` rather than `Array(...)` so this and
        # `_reject_unsupported_map_axis!` — the two guards that now route on the answer — cannot disagree about
        # which values are an empty union. That matters beyond tidiness: `Array()` tries the value's own
        # `to_ary`/`to_a` first, so a caller-supplied object could otherwise read as empty at one guard and
        # non-empty at the other, and fall between them.
        def _axis_names_empty_union?(declared)
          return false if nil.equal?(declared)
          return false unless nil.equal?(Internal::ShapeGraph.hash_or_nil(declared))

          _declared_type_tokens(declared).empty?
        end

        # Which refusal a map bag whose axes all name no class gets. An axis written as an empty union has a key
        # to name and gets the defect it actually has; a bag whose axes are absent or nil has none, so it keeps
        # the refusal that asks for one. The FIRST such axis in `MAP_OF_AXES` order is named rather than both:
        # each is one defect, and an author fixing this one meets the other on the next declaration.
        #
        # Runs only on the failure path, so the second read of `bag[axis]` costs nothing on a good declaration.
        def _map_axes_name_no_class_message(bag)
          axis = MAP_OF_AXES.find do |candidate|
            Internal::ShapeGraph.carries_key?(bag, candidate) && _axis_names_empty_union?(bag[candidate])
          end

          nil.equal?(axis) ? MAP_OF_REQUIRED_MESSAGE : _empty_union_axis_message(axis)
        end

        def _reject_unconstraining_of_bag!(bag)
          return if INNER_CONTRACT_AXES.any? { |axis| _of_axis_constrains?(bag, axis) }

          # A bag that NAMED `klass:` and named nothing with it gets the defect it actually has: "name the
          # contents' class with `klass:`" is no help to an author looking at the `klass:` they wrote.
          if Internal::ShapeGraph.carries_key?(bag, :klass) && !bag[:klass].nil?
            raise ArgumentError,
                  "of: klass: names an empty union, so this bag constrains nothing — #{EMPTY_UNION_DIAGNOSIS}. " \
                  "Name the class(es) the contents must be, or drop the empty klass: and constrain them with " \
                  "`of:` or `shape:`. (`of: []` is sugar for `of: { klass: [] }`.)"
          end

          # A bag carrying only value validators constrains the position perfectly well — `of: { format: ... }`
          # holds every element to a pattern while leaving its class open. Checked AFTER the empty-union raise
          # above, which no other constraint can rescue: `klass: []` emits `anyOf: []`, a node nothing
          # satisfies, so the bag is refused however much else it says.
          return if _bag_carries_positional_validator?(bag)

          raise ArgumentError,
                "of: must constrain something — name the contents' class with `klass:`, what is inside them " \
                "with `of:`, their members with `shape:`, or their value with a validator " \
                "(#{POSITIONAL_VALIDATOR_KEYS.map { |key| "#{key}:" }.join(', ')})"
        end

        # Whether the bag holds the value at its position to anything, as opposed to describing the position.
        # A falsy entry is a disabled validator ActiveModel skips, so it constrains nothing.
        def _bag_carries_positional_validator?(bag)
          POSITIONAL_VALIDATOR_KEYS.any? { |key| Internal::ShapeGraph.carries_key?(bag, key) && bag[key] }
        end

        # PRO-3192's two positional guards, at a bag position. Reached with the bag's own value constraints and
        # `klass:` in the role `type:` plays at a field — which is the role `klass:` already plays for the rest
        # of the bag grammar (`_inner_of_container!`) — so ONE rule covers the field and all three bag
        # positions. A second table here could drift from the first; a shared call cannot.
        def _reject_positional_bag_validators!(bag, fields)
          # Nothing to judge for a bag that names only what it holds — which is every `of: Integer` — so the
          # ordinary declaration reaches neither guard and allocates nothing beyond the emptiness check.
          return unless _bag_carries_positional_validator?(bag)

          validations = _bag_as_validations(bag)

          where = "an `of:` bag on #{_declared_fields_label(fields)}"
          _reject_container_position_validators!(validations, where:, nested: true)
          # No tolerance is passed, and none is read out of `validations` either (see `_bag_as_validations`):
          # a bag's `allow_nil:`/`allow_blank:` do not govern its position (PRO-3225), so honouring them here
          # would stand the guard down for a rescue that never happens — letting a contract which admits
          # NOTHING declare cleanly, which is the class this guard exists to refuse. At a field the same flags
          # DO rescue the contract, and there they still stand it down.
          _reject_unsatisfiable_value_constraints!(validations, where:, nested: true, tolerance: {})
          # Its mirror, in the same order the field path runs the pair: the unsatisfiable contract is reported
          # first, so a declaration broken both ways names the defect that rejects every call ahead of the one
          # that rejects none. Both guards run at all four positions — PRO-3192's rule is that a validator is
          # judged where it is declared, and an INVERTED one that forbids literals no value of the position's
          # class could be enforces nothing there just as surely as it does at a field.
          _reject_vacuous_value_constraints!(validations, where:, nested: true, tolerance: {})
        end

        # The bag as a VALIDATIONS hash: its value constraints, with `klass:` renamed to `type:` — the role
        # `klass:` plays for the rest of the bag grammar. Only the grammar keys are dropped by name, so a
        # validator added to `POSITIONAL_VALIDATOR_KEYS` reaches the guards without a second edit here.
        #
        # The shared ActiveModel options come out through `validator_entries`, exactly as they do for the
        # runtime's own forwarding (`OfValidator#inner_contract_validations`): they are not validators, and at a
        # bag position they are not enforced either, so leaving them in would have `Base.nil_accepted?` read a
        # tolerance out of the bag and reach the same wrong answer the explicit `tolerance: {}` above avoids.
        def _bag_as_validations(bag)
          validations = Axn::Validation::Base.validator_entries(bag.except(*BAG_GRAMMAR_KEYS))
          klass = bag[:klass]
          return validations if Array(klass).empty?

          # The CANONICAL `type:` shape, as a field's stored validations carry it: a bare token would be
          # normalized as a validator scalar and read under the wrong key, so every judgment that unwraps
          # `type: { klass: … }` would see no class at all.
          validations.merge(type: { klass: })
        end

        # A bag's own `of:` is held to exactly the grammar a FIELD's is, with `klass:` in `type:`'s role: the
        # class it names decides whether the inner bag is read as an Array's element or as a map's axes. One
        # function, so a container two levels down is judged by the same rules as one at the top.
        #
        # Called per rung by `_walk_inner_contracts!`, which owns the depth bound, the cycle guard and the path
        # allowance — so this canonicalizes the child of ONE bag and returns, and the walk decides whether there
        # is a next rung to canonicalize at all. Mutates `bag`, which is always a Hash of axn's own by the time
        # it is reached (the field-level detach copies the first rung; the line below copies each one after).
        def _canonicalize_inner_contract!(bag, fields)
          return unless Internal::ShapeGraph.carries_key?(bag, :of)

          # The field-level detach (`ShapeGraph.detach_option_containers!`) copies one level deep, and a nested
          # bag sits two — so the value under this bag's `:of` is still the caller's object. Detached HERE,
          # before any key is read out of it, so every read below reads axn's own copy, a later mutation of what
          # the caller still holds cannot change a declared contract at any depth, and
          # `reject_defaulting_option_container!` applies at every rung rather than only the first.
          Internal::ShapeGraph.detach_option_containers!(bag)
          # And canonical before any key is read out of it, for the reason the detach above is taken here: one
          # rung down is exactly as far as the field-level pass reaches. AFTER the detach, so the defaulting-bag
          # refusal still judges the container the author wrote rather than the plain copy canonicalizing
          # produces — the same order, and the same reason for it, as `_symbolize_option_bags!`'s own carve-out.
          _symbolize_inner_bag!(bag, :of) { "the `of:` option bag" }
          container = _inner_of_container!(bag)
          _drop_derived_of_container!(bag, container)
          bag[:of] = container.equal?(::Hash) ? _canonical_map_of!(bag, fields) : _canonical_array_of!(bag, fields)
        end

        # ONE inner-contract bag, canonicalized in place under the key that holds it. `_symbolize_option_bags!`
        # runs over a FIELD's (or a shape member's) own validator bags and stops there — it is entry-wise over
        # one Hash, and everything below a bag is the caller's data, whose meaning is not axn's to reinterpret.
        # An inner contract is the exception the recursion creates: a bag nested inside a bag, and either axis of
        # a map, are axn's own grammar again rather than caller data, so they are held to the same one-spelling
        # rule the outer bag is. Without it the identical bag declared at the first rung and was refused at the
        # second — `of: { "klass" => String }` stored `{klass: String, container: Array}`, while
        # `of: { klass: Array, of: { "klass" => Integer } }` raised `of: does not support "klass"` — which is the
        # "a value with a uniform meaning must be honored on every path" rule read backwards.
        #
        # `_symbol_keyed_bag` is the one symbolizer, reused rather than mirrored: it reads through the bound
        # `each` seam (never asking an indifferent-access bag to convert itself), preserves a key it cannot
        # symbolize so `_reject_unknown_of_keys!` still names it, and refuses one option declared under both
        # spellings. It answers nil when there is nothing to change, so a Symbol-keyed declaration — every one
        # the DSL writes for itself, and every rung of the second pass over a shape member — allocates nothing.
        #
        # The label is yielded through, so naming the position costs nothing until there is an error to name.
        def _symbolize_inner_bag!(owner, key, &)
          bag = Internal::ShapeGraph.hash_or_nil(owner[key])
          return if nil.equal?(bag)

          symbolized = _symbol_keyed_bag(bag, &)
          owner[key] = symbolized unless nil.equal?(symbolized)
        end

        # The same derivation `_of_container!` makes for a field, reading the bag's `klass:` instead of the
        # field's `type:`. A bag naming no class at all is refused here rather than guessed at: with no
        # container named there is no way to tell the Array grammar from the Hash grammar, which is the same
        # reason a union `klass:` is refused a line later.
        def _inner_of_container!(bag)
          unless Internal::ShapeGraph.carries_key?(bag, :klass)
            raise ArgumentError, "of: names no container, so its own `of:` has no reading — add `klass: Array` " \
                                 "or `klass: Hash`"
          end

          _declared_of_container!(bag[:klass], option: "klass:")
        end

        # A Hash has two things inside it, so the bare form has no honest reading: `of: Integer` would have to
        # pick an axis by convention, and which one it picked would not be visible in the declaration.
        #
        # `owner` is whatever DECLARED the `of:` being canonicalized — a field's validations bag, or an
        # inner-contract bag one rung up (PRO-3166). The two are read identically because the only key read is
        # `:of`, which means the same thing in either: the contract for what is inside.
        #
        # A `shape:` beside it is NOT read here, and the exempt set it derives is written later, by the walk
        # (`_derive_shaped_keys!`): the shape is snapshotted AFTER this runs at two of the three positions a map
        # can sit at, so reading it here would read the caller's members list a second time and record names the
        # stored shape may not carry.
        def _canonical_map_of!(owner, fields)
          bag = Internal::ShapeGraph.hash_or_nil(owner[:of])
          raise ArgumentError, MAP_OF_REQUIRED_MESSAGE if nil.equal?(bag)

          _reject_unknown_of_keys!(bag, MAP_OF_OPTION_KEYS)
          raise ArgumentError, _map_axes_name_no_class_message(bag) if MAP_OF_AXES.all? { |axis| _axis_names_no_class?(bag[axis]) }

          _reject_inner_contract_context_scope!(bag, fields)
          _reject_unsupported_map_axis!(bag)
          _canonicalize_map_axes!(bag, fields)
          bag.merge(container: ::Hash)
        end

        # An axis takes the same forms `type:` does — a class, a union of them, a `:boolean`/`:uuid`/`:params`
        # symbol — OR a contract of its own, which is the same inner-contract bag an Array's element takes. One
        # grammar in three positions, so a map's values are held to exactly what an array's elements are.
        #
        # ONE rung only, exactly as `_canonical_array_of!` is: what the axis bag itself holds is canonicalized by
        # `_canonicalize_inner_contract!` when the declaration walk reaches it, since `ShapeGraph.inner_contracts`
        # already yields every bag-valued axis of a map as an inner contract. Recursing from here would recurse
        # over the CALLER's graph ahead of the depth bound, the cycle guard and the path allowance the walk owns
        # — and would be a second canonicalization path for a node the walk canonicalizes anyway.
        #
        # `bag` is axn's own copy by the time it is reached, but the values UNDER it are still the caller's — the
        # option-container detach copies one level, and an axis bag sits two. Detached through the same seam
        # every stored option container goes through, before a key is read out of any of them: a later mutation
        # of what the caller still holds cannot change a declared contract at any depth, and a defaulting Hash is
        # refused at this rung with the axis named. Mutates `bag`.
        def _canonicalize_map_axes!(bag, fields)
          Internal::ShapeGraph.detach_option_containers!(bag)

          MAP_OF_AXES.each do |axis|
            # Canonical before its grammar is checked, on the same terms and in the same order as a nested
            # element bag (see `_symbolize_inner_bag!`): an axis is the third position one inner-contract bag
            # sits at, and a spelling accepted at the other two has to be accepted here.
            _symbolize_inner_bag!(bag, axis) { "the `of: { #{axis}: … }` option bag" }
            inner = Internal::ShapeGraph.hash_or_nil(bag[axis])
            next if nil.equal?(inner)

            _check_inner_contract_bag!(inner, fields)
            _reject_inert_axis_options!(inner, axis, fields)
          end
        end

        # Whether an axis names any class for the runtime to hold a value to. An absent axis names none, and so
        # does an EMPTY union: `OfValidator#matches_axis?` waves every value through a class list with nothing in
        # it, so `of: { values: [] }` reads as a declaration and constrains exactly nothing — the silent no-op
        # this whole option exists to refuse, and the reason `of: {}` is refused already.
        #
        # A Hash is NOT emptiness here whatever it holds: it is an inner contract of its own, which constrains
        # something by construction (`_check_inner_contract_bag!` refuses one that does not). Classified through
        # `ShapeGraph.hash_or_nil` — the value is the caller's, and a Hash subclass denying its own class would
        # otherwise decide whether its axis counts as named.
        def _axis_names_no_class?(declared)
          return true if nil.equal?(declared)
          return false unless nil.equal?(Internal::ShapeGraph.hash_or_nil(declared))

          Array(declared).empty?
        end

        # The pseudo-types a declared type may name beside a real class — shared by a field's own `type:`
        # and every `of:` position (a bare axis, a bag's `klass:`), so the three cannot drift about what a
        # type is. Mirrors the branches `Axn::Validators::TypeValidator.value_matches?` answers by name, which
        # is the authority — a token outside both sets reaches `value.is_a?(token)` and raises
        # `TypeError: class or module required` on every call rather than at the author.
        TYPE_TOKEN_PSEUDO_TYPES = %i[boolean uuid params].freeze

        # Every axis the author SUPPLIED has to name something the runtime can hold a value to. The emptiness
        # rule above only asks whether the bag as a whole constrains nothing, so a bag with one good axis
        # carried the other unchecked: `of: { keys: Symbol, values: false }` declared cleanly and then raised a
        # bare `TypeError: class or module required` from `value.is_a?(false)` on EVERY call, and
        # `of: { keys: Symbol, values: nil }` silently constrained nothing at all. Both are the failure this
        # option exists to refuse, arriving one axis later.
        #
        # Keyed on `key?` rather than on the value, so "supplied but names nothing" is refused while an axis
        # left off stays the honest spelling of "unconstrained". Each offender is named through
        # `_declared_type_label`, never its own `inspect`.
        #
        # An axis holding a Hash is skipped: that axis is a contract of its own, judged against the bag grammar
        # by `_canonicalize_map_axes!`. Classified through `hash_or_nil` — the value is the caller's, and a Hash
        # subclass denying its own class would otherwise pick which grammar its axis is held to. A Hash inside a
        # UNION is not that spelling and is still refused here: a union names types, and `Array()` reaches a
        # Hash as its entry pairs, so the bare form has to be answered before the union is unwrapped.
        def _reject_unsupported_map_axis!(bag)
          MAP_OF_AXES.each do |axis|
            next unless Internal::ShapeGraph.carries_key?(bag, axis)

            declared = bag[axis]
            next unless nil.equal?(Internal::ShapeGraph.hash_or_nil(declared))

            # An empty union is not a token the runtime cannot hold a value to — `[]` IS the union spelling, and
            # being empty is the defect — so it reports the emptiness, in the same words a bag's `klass:` uses
            # for the identical mistake. Reached when a SIBLING axis constrains: with both axes naming nothing
            # `_map_axes_name_no_class_message` has already answered, one guard earlier.
            raise ArgumentError, _empty_union_axis_message(axis) if _axis_names_empty_union?(declared)

            tokens = _declared_type_tokens(declared)
            # An axis SUPPLIED and naming nothing else (`nil`) has no token to name, so the refusal names the
            # value written instead. Unlike a bag's `klass:`, an axis has no second way to constrain, so there
            # is no other guard for this to defer to.
            raise ArgumentError, _unsupported_type_token_message("of: #{axis}:", declared) if tokens.empty?

            _reject_unsupported_type_token!(tokens, "of: #{axis}:")
          end
        end

        # The type tokens a declared value names, with the bare-Hash spelling answered BEFORE the union is
        # unwrapped: a Hash written where a type belongs would otherwise be searched as a list of
        # two-element Arrays and named as one. Classified through `hash_or_nil` — the value is the caller's,
        # and a Hash subclass denying its own class would otherwise pick how it is read. A caller that reads
        # a Hash as something else entirely (an axis holding an inner contract) answers that on its own terms
        # first and never reaches this.
        #
        # The union-or-single-token split, and the reason it is never `Kernel#Array()`, belong to
        # `ShapeGraph.type_tokens` — THE classification, shared with the nil-tolerance judgment and with
        # schema reflection so no two of them can disagree about what one declaration names. Read from here
        # for the AXIS position, where the value arrives as declared: a bare Hash written in place of a type
        # is one unsupported token, which is what that reader answers for it.
        def _declared_type_tokens(declared) = Internal::ShapeGraph.type_tokens(declared)

        # The one search for a token the runtime cannot hold a value to, shared by a field's own `type:`, the
        # bare-axis grammar and the bag's `klass:` so none of the three can drift about what a type is. Answers
        # the INDEX rather than the token: `nil` is itself an unsupported token, and `find` gives the same
        # answer for "found nil" as for "found nothing" — which is how `of: { values: [String, nil] }` declared
        # cleanly and raised the bare TypeError on every call.
        #
        # Emptiness is each caller's own question, because the three positions spell the answer differently —
        # see `_reject_unsupported_of_klass!` and `_reject_unsupported_type_klass!`.
        def _reject_unsupported_type_token!(tokens, option)
          index = tokens.find_index { |token| !_supported_type_token?(token) }
          return if nil.equal?(index)

          raise ArgumentError, _unsupported_type_token_message(option, tokens[index])
        end

        # `option:` travels with the message for the reason `_declared_of_container!`'s does: one rule, but the
        # key an author has to EDIT is `type:` at a field, `keys:`/`values:` at a bare axis, and `klass:` inside
        # a bag — each caller passes its own full spelling (`"type:"`, `"of: values:"`, `"of: klass:"`) rather
        # than a bare option name, so a refusal naming a key the declaration does not carry never prescribes a
        # fix with nowhere to land. The offender is named through `_declared_type_label`, never its own
        # `inspect`: it is the caller's object, and one raising from `to_s` while this message is built would
        # replace the ArgumentError with its exception.
        def _unsupported_type_token_message(option, declared)
          "#{option} must name a type — a Class, a union of them, or one of " \
            "#{TYPE_TOKEN_PSEUDO_TYPES.map(&:inspect).join(', ')} (got #{_declared_type_label(declared)})"
        end

        # `Module` covers a class and a module both, tested with `case`/`when` so nothing the token defines
        # decides whether it is one.
        def _supported_type_token?(token)
          case token
          when ::Module then true
          when ::Symbol then TYPE_TOKEN_PSEUDO_TYPES.include?(token)
          else false
          end
        end

        # THE canonicalization this ticket is for. `shape:` under `type: Array` means "each ELEMENT's members" —
        # the one position where a shape reaches THROUGH a value instead of describing it, and the only reason
        # it ever had to was that an Array's contents had no other word. `of:` is that word now, so the
        # declaration is folded into the bag at declaration time and the stored graph carries ONE contract
        # shape: a container's contents live in its `of:` bag at every depth, and no consumer has two places
        # to look. The SURFACE is unchanged — both spellings still declare — which is what PRO-3191 removes.
        #
        # Called from the declaration walk, per rung, AFTER the bag's own `shape:` has been snapshotted and
        # BEFORE the walk descends onto the bag: after, because the two shapes describe one node and are merged
        # into the bag's one slot; before, because the descent is what derives the bag's exempt key set from
        # the shape now sitting in it (`_derive_shaped_keys!`).
        #
        # Both shapes are already walked, checked, copied and bounded by the time this runs — the node's by the
        # snapshot its declaration took, the bag's by `_snapshot_inner_shape!` a line earlier — so this MOVES a
        # finished node rather than re-reading a caller's graph, and charges nothing beyond the `of:` rung the
        # walk already charged.
        #
        # The members are UNIONED rather than one displacing the other, because both applied before this
        # canonicalization: an author who wrote `type: Array, of: { klass: Hash, shape: A }` beside a block
        # declaring B had every element held to A and to B, by two validators over one node. One slot, one
        # union, same verdicts.
        def _fold_distributing_shape!(node, bag, position, fields)
          # A node whose declared type is Array has exactly one inner position, so this is a belt-and-braces
          # guard against a config ASSIGNED onto the class (`internal_field_configs=`) pairing `type: Array`
          # with a map bag, where folding an element contract onto an axis would be a contract nobody wrote.
          return unless Internal::ShapeGraph::ELEMENT_POSITION.equal?(position)
          return unless _distributing_shape?(node)

          distributed = Internal::ShapeGraph.hash_or_nil(node[:shape])
          return if nil.equal?(distributed)

          node.delete(:shape)

          existing = Internal::ShapeGraph.hash_or_nil(bag[:shape])
          # Detached before the write for the reason `_derive_raw_shape_container!` gives: the walk's memo hands
          # every position reusing one shape the SAME copy, so writing this position's members (and, below, its
          # container) in place would carry one position's derived contract into the other.
          folded = Internal::ShapeGraph.detach_node(nil.equal?(existing) ? distributed : existing)
          folded[:members] = nil.equal?(existing) ? distributed[:members] : existing[:members] + distributed[:members]
          _reject_folded_duplicate_members!(folded[:members], fields) unless nil.equal?(existing)
          folded[:container] = _folded_element_container(bag) if _derived_distributing_container?(folded[:container])
          # An explicit `container:` that was never the distributing marker survives the move and is held to
          # exactly the bar it always was, rather than being silently discarded by the derivation above.
          _reject_non_class_container!(folded[:container])
          bag[:shape] = folded
        end

        # Two members of one shape may not share a key, and the union above is the one construction that can
        # build such a list out of two lists each already checked: `_check_and_copy_shape_members!` judges each
        # block in isolation, and neither can see the other. Left unchecked the merged list declared cleanly and
        # produced exactly what that refusal exists to prevent — `required:` naming the key twice (JSON Schema
        # requires those to be unique), one `properties` entry for it, and one of the two declarations silently
        # unenforced, since `ShapeValidator#member_validator_classes` keys members by `field` and a duplicate
        # collapses.
        #
        # Only reached when BOTH lists exist, since a single list arrives already judged. The names are the
        # canonical Symbols the member walk captured and stored (`_snapshot_member_attributes!`), so this
        # compares what the schema keys on and canonicalizes nothing a second time — and nothing of the
        # caller's runs to reach the verdict.
        def _reject_folded_duplicate_members!(members, fields)
          seen = {}
          members.each do |member|
            name = Internal::ShapeGraph.read(member, :field)
            _raise_folded_duplicate_member!(name, fields) if seen.key?(name)

            seen[name] = true
          end
        end

        # Names both spellings, because the author wrote the key in two places and the fold is why they met:
        # a message naming only the key would send them to a shape that looks perfectly legal on its own.
        def _raise_folded_duplicate_member!(name, fields)
          label = _declared_fields_label(fields)
          raise Axn::ContractViolation::DuplicateFieldError,
                "Duplicate shape member declared: #{_inspect_field_name(name)} — the `shape:` inside the `of:` " \
                "bag on #{label} and the shape distributed over its elements both declare it, and the two " \
                "member lists are unioned into one. The reflected schema would name it twice in `required:` " \
                "while emitting one property for it, and only one of the two declarations would validate. " \
                "Declare #{_inspect_field_name(name)} in one of the two."
        end

        # Whether the container the folded shape arrives with is one the fold OWNS. A container belongs to the
        # POSITION, and the fold is a change of position: `::Array` is the marker that said "distribute over the
        # elements" (written by `_build_shape` from the field's `type:`), and `nil` is a raw `shape:` kwarg whose
        # container has not been derived yet — both are the enclosing position's answer, and neither is the
        # element's. Identity with the receiver on axn's side, on the same terms as every other read of this key:
        # a raw shape may put any object in that slot.
        def _derived_distributing_container?(container) = ::Array.equal?(container) || nil.equal?(container)

        # The container the ELEMENT position gates on once a distributing `shape:` has been folded onto it: the
        # single class the bag names, where a shape can be read off one — otherwise `ANY_CONTAINER`, the
        # sentinel for a position deliberately left ungated.
        #
        # Deliberately non-raising, which is what separates it from `_derive_inner_shape_container!`'s
        # derivation for a bag's OWN `shape:`. That one refuses a scalar or union `klass:`, because an author
        # who wrote `of: { klass: String, shape: … }` named a class a shape cannot be read off and wants to
        # know. This one is handed a declaration that is legal today — `type: Array, of: String` beside a
        # distributing block reads members off each scalar element, and the emitter deliberately validates
        # them without emitting them (`Schema.shape_overlay_applies?`) — so refusing it here would reject at
        # declaration what the block form still accepts, and this canonicalization changes storage, not what
        # the block form declares. (The raw `shape:` kwarg this once also covered is refused before reaching
        # here at all — PRO-3191 — so the only caller left is the block form's own fold.) Ungated is also what
        # the block spelling always means at this position: it names `Array` for the FIELD and never names
        # anything for the element.
        #
        # `::Array` is the one class this cannot store even though a shape reads perfectly well off one, because
        # `container: Array` is not a gate at that key: `ShapeValidator` reads it as "distribute over the
        # elements" (`shape_validator.rb:41`), so storing it for `of: Array` would read the members one level
        # too deep and reject `rows: [%w[a b]]` naming a position the author never declared. There is no
        # spelling for "read members off this Array element" while that reading holds, so the position stays
        # ungated — which is the pre-flip verdict exactly, since the distributing shape never gated the element
        # either. (The hand-written twin, `of: { klass: Array, shape: … }`, reaches the same ambiguity through
        # `_derive_inner_shape_container!` and is REFUSED there rather than given a fallback: the author named
        # the class, so the answer is a rule about what they wrote, and a spelling refused today can be granted
        # a meaning by PRO-3192 without contradicting anything released. This spelling has no such option — it
        # declares legally today, so a refusal here would reject at declaration what the surface still accepts.)
        def _folded_element_container(bag)
          return Internal::ShapeGraph::ANY_CONTAINER unless _shape_compatible_klass?(bag[:klass])

          klass = Array(bag[:klass]).first
          ::Array.equal?(klass) ? Internal::ShapeGraph::ANY_CONTAINER : klass
        end

        # Whether this node's `shape:` describes its value's ELEMENTS rather than the value itself — the one
        # reading `shape:` has under `type: Array`, and the one the fold above removes.
        #
        # Derived from the declared `type:` through `_declared_type_klass`, the same read `_shape_compatible_type!`
        # makes, so the question "which class does this shape hang off" has one answer wherever it is asked —
        # and, because that read is tolerant of the shorthand, one that does not depend on whether the caller
        # reaches this before or after `_canonicalize_validator_options!` expanded it. Both orders occur: the
        # declaration snapshots a field's shape before its options are canonicalized and a member's after.
        #
        # By IDENTITY for the reason `_declared_of_container!` is: the declared class is the caller's, and one
        # answering `==` for its own purposes would otherwise choose whether its shape distributes. It cannot
        # simply CALL that method, which raises for every type that is not a container — and `type: Hash`,
        # `type: SomeData` and a plain class all carry a perfectly legal non-distributing `shape:`.
        def _distributing_shape?(node)
          return false unless Internal::ShapeGraph.carries_key?(node, :shape)

          declared = Array(_declared_type_klass(node))
          declared.size == 1 && ::Array.equal?(declared.first)
        end

        # The bag a distributing `shape:` is folded into when the declaration named no `of:` at all
        # (`expects :rows, type: Array do … end`): there is no element class, so the bag constrains its
        # contents by members alone and the walk has a rung to descend. Minted by the walk rather than by
        # `_canonicalize_validator_options!` because there is no caller bag to hold to the bag grammar here —
        # what this builds is axn's own, and it constrains something by construction (the fold puts the shape
        # in it a moment later), which is the one rule that grammar exists to enforce. Mutates `node`.
        def _open_distributing_bag!(node)
          return unless _distributing_shape?(node)
          # Key presence, not the value: a declaration that named `of:` owns that slot, and the canonicalization
          # above has already held whatever it named to the bag grammar.
          return if Internal::ShapeGraph.carries_key?(node, :of)

          node[:of] = { container: ::Array }
        end

        # `shape:` names a Hash's own members and `of:` names its values, so on a Hash — and only on a Hash —
        # the two describe DIFFERENT nodes and are complements rather than rivals. JSON Schema settles what
        # that means: `additionalProperties` applies only to the keys `properties` does not match, so a key the
        # shape names is exempt from the map contract, on BOTH axes. (`keys:` emits nothing, so there is no
        # document to contradict there — but the symmetric rule is what stops a shape member quietly acquiring
        # the key-type requirement it never asked for.)
        #
        # The exempt set is derived onto the map bag here rather than beside the canonicalization, because this
        # is where the node's shape is FINAL: a shape member's and an inner bag's `shape:` are both snapshotted
        # after their `of:` is canonicalized, and a distributing `shape:` has been folded into the bag it
        # describes before the walk descends onto that bag. `node` is a field's/member's validations bag or an
        # inner-contract bag, and its OWN `shape:` is the whole of what names its properties — which is what
        # the fold buys: the exempt set no longer has to be carried down from an enclosing node that named
        # properties for a bag it did not sit in. Mutates `node`.
        def _derive_shaped_keys!(node)
          bag = Internal::ShapeGraph.hash_or_nil(node[:of])
          return if nil.equal?(bag)
          # A map is the only container the exemption can arise on, asked through the one predicate that tells
          # the two bag grammars apart.
          return unless Internal::ShapeGraph.map_bag?(bag)

          node[:of] = bag.merge(shaped_keys: _shaped_keys(node[:shape]))
        end

        # The keys the shape covering one node names, which JSON Schema emits as that node's `properties`. Read
        # from the emitter's own key computation (`Schema.named_members`) rather than re-derived beside it, so
        # the runtime skips exactly the keys the document exempts — the "a guard derives from what its consumer
        # emits" rule, whose failure mode here would be a contract stricter than the schema it publishes.
        #
        # Frozen, and the shared empty Array where nothing is named, because it is stored in a declared contract
        # and read on every entry of every Hash validated against it.
        def _shaped_keys(declared_shape)
          shape = Internal::ShapeGraph.hash_or_nil(declared_shape)
          return Internal::ShapeGraph::NO_SHAPED_KEYS if nil.equal?(shape)

          keys = Axn::Internal::Reflection::Schema.named_members(shape[:members]).map { |_member, name| name.to_sym }
          keys.empty? ? Internal::ShapeGraph::NO_SHAPED_KEYS : keys.uniq.freeze
        end

        # Bag keys admitted by the whitelist only so a dedicated guard can name what is actually wrong with them.
        UNADVERTISED_OF_KEYS = %i[on strict].freeze
        private_constant :UNADVERTISED_OF_KEYS

        # Every offender at once: an author who wrote two of them has one declaration to fix, not two rounds
        # of the same error.
        def _reject_unknown_of_keys!(bag, allowed)
          offenders = bag.keys.reject { |key| allowed.include?(key) }
          return if offenders.empty?

          # `on:` and `strict:` sit in the whitelist so `_reject_inner_contract_context_scope!` /
          # `_reject_inner_contract_strict!` can name the real problem (axn has no validation contexts, and no
          # strict-raising mode) instead of reporting either as unknown — but both are left out of what this
          # ADVERTISES, since a key this line calls supported and the next line refuses is not one to point an
          # author at.
          supported = allowed.reject { |key| UNADVERTISED_OF_KEYS.include?(key) }
          raise ArgumentError,
                "of: does not support #{offenders.map { |key| _of_key_label(key) }.join(', ')} " \
                "(supported: #{supported.map { |key| "#{key}:" }.join(', ')})"
        end

        # An offending key written into the message. A Symbol is named through a BOUND `Symbol#name` and keeps
        # the `key:` spelling the supported list uses; anything else goes through the shared name seam, which
        # answers without dispatching. `_symbol_keyed_bag` preserves a key it cannot symbolize, so an unknown
        # one may be an arbitrary caller object — and interpolating it ran that object's own `to_s`, which
        # replaced this declaration error with the caller's exception (outside StandardError, one that escapes
        # every rescue meant to settle it).
        def _of_key_label(key)
          case key
          when ::Symbol then "#{SYMBOL_KEY_NAME.bind_call(key)}:"
          else Axn::Internal::Reflection::PropertyNames.inspect_field_name(key)
          end
        end

        SYMBOL_KEY_NAME = ::Symbol.instance_method(:name)
        private_constant :SYMBOL_KEY_NAME

        # The two keys the field grammar admits that ActiveModel cannot resolve a validator for, at any
        # position and under any declared type. `validates` resolves an entry by
        # `const_get("#{key.to_s.camelize}Validator")` from the class being declared on, which for axn is a
        # `Validation::Base` subclass — `ActiveModel::Validations` and axn's own validator constants, nothing
        # else — so both names miss and every call raises `ArgumentError: Unknown validator: '…Validator'`.
        # A declaration that looks supported, enforces nothing, and converts every call into an exception is
        # the one outcome that should not stand, so both are refused where the declaration is written.
        #
        # They stay in `KNOWN_VALIDATION_KEYS` rather than being struck from it, for the reason `on:` does:
        # a recognized option reported as an unknown key names the author's problem less well than a message
        # that says what the option would have meant.
        #
        # Key PRESENCE, not truthiness. The falsy-entry no-op that leaves `confirmation: false` alone does not
        # apply: AM's `const_get` runs BEFORE its `next unless options`, so `uniqueness: false` raises exactly
        # as `uniqueness: true` does (measured).
        #
        # One at a time rather than joined, which is the opposite of how same-reason offenders are reported
        # (`_reject_validator_context_scope!` names every `on:` at once): these are two different problems with
        # two different fixes, and an author who wrote both is better served reading one at a time.
        def _reject_unsupported_validator_keys!(validations, where:)
          _raise_uniqueness_unsupported!(where) if validations.key?(:uniqueness)
          _raise_bare_message_unsupported!(where) if validations.key?(:message)
        end

        # `uniqueness:` is an ActiveRecord validator — it needs a record, a relation to query, and a connection
        # — and an axn contract has none of the three: it validates a plain value that arrived over the wire.
        #
        # Supporting it for `model:`-backed fields, where a record does exist, was considered and rejected: the
        # option would then mean one thing on one kind of field and be refused on every other, and the check it
        # would run (does another row share this value) is a question about the database at a moment, not about
        # the input the contract is describing. A contract that queries is a contract whose reflected schema
        # cannot state what it enforces.
        def _raise_uniqueness_unsupported!(where)
          raise ArgumentError,
                "uniqueness: on #{where} is not supported — it is an ActiveRecord validator " \
                "(ActiveRecord::Validations::UniquenessValidator), so it needs a record and a relation to " \
                "query, and an axn contract validates a plain value with ActiveModel alone. Declared, it " \
                "resolves to no validator at all and every call raises `Unknown validator: " \
                "'UniquenessValidator'`. Check uniqueness where the records are — on the model, or as " \
                "`validate: ->(value) { ... }` querying it yourself."
        end

        # `message:` overrides the wording of ONE check, so it belongs inside that check's own option bag. At a
        # field's top level it is not the shared option it looks like: AM's `_validates_default_keys` is
        # `if:`/`unless:`/`on:`/`allow_blank:`/`allow_nil:`/`strict:`/`except_on:` and does not include it, so a
        # bare `message:` is parsed as a validator ENTRY named `message` and looks for a `MessageValidator`.
        #
        # The bag spelling is untouched by this and is where every working use already lives — `type: { klass:,
        # message: }`, an `of:` bag's own (`OF_OPTION_KEYS` carries it), and every ActiveModel built-in's
        # (`length:`, `inclusion:`, …). Only the field's or member's own top-level key is refused, since only
        # that one reaches `validates` as an entry.
        #
        # The three spellings the message names are the ones measured to work. `validate: { with:, message: }`
        # is deliberately NOT among them though its bag admits the key: `ValidateValidator#validate_each` adds
        # the CALLABLE's return value as the error and never reads `options[:message]`, so a message there is
        # inert — pointing an author at it would trade one silently-ignored option for another.
        def _raise_bare_message_unsupported!(where)
          raise ArgumentError,
                "message: on #{where} is not an option at this level — it overrides one check's wording, so it " \
                "belongs inside that check's own bag (`type: { klass: String, message: \"...\" }`, `of: " \
                "{ klass: String, message: \"...\" }`, `length: { minimum: 3, message: \"...\" }`). " \
                "ActiveModel's shared options do not include `message:`, so a bare one is read as a validator " \
                "named `message` and every call raises `Unknown validator: 'MessageValidator'`."
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

          _raise_validator_context_scope!(offenders.join(" / "), where,
                                          offenders.size == 1 ? "that check runs" : "those checks run")
        end

        # A validator whose ActiveModel implementation can only reach the declared value through its Ruby string
        # form or a numeric coercion of it, on a field whose every declared type is a container. Refused at
        # declaration: `format:` there constrains `["a"].inspect` — satisfiable, meaningless, and unexpressible
        # in JSON Schema, where `pattern` applies to strings — and `numericality:` accepts no container value at
        # all, whatever its options say. (`comparison:` and `acceptance:` are NOT here — see
        # `TO_S_TARGETED_VALIDATOR_KEYS` for the measurements that took them back out.)
        #
        # Gates do NOT rescue one. This is a judgment about what the validator can MEAN at this position, and a
        # closed `if:` skips a check rather than giving it a reading. The satisfiability guard below refuses
        # through a gate too, for a different reason: reflection is static-maximal, so a gated can-never-match
        # set still emits an unsatisfiable node.
        #
        # Every offender is named at once: an author who wrote two has one declaration to fix.
        def _reject_container_position_validators!(validations, where:, nested: false)
          return unless _declares_container_type_only?(validations[:type])

          entries = Axn::Validation::Base.validator_entries(validations)
          # A falsy entry is a disabled validator ActiveModel skips, so it constrains nothing and names nothing.
          offenders = TO_S_TARGETED_VALIDATOR_KEYS.select { |key| entries[key] }
          return if offenders.empty?

          raise ArgumentError,
                "#{offenders.map { |key| "#{key}:" }.join(' / ')} on #{where} cannot " \
                "constrain a container: ActiveModel reads #{offenders.length == 1 ? 'it' : 'them'} off the " \
                "value's Ruby string form (`format:` matches `[\"a\"].to_s`) or off a numeric coercion of it " \
                "(`numericality:`), and a container has neither — so the check constrains punctuation or can " \
                "never pass. A validator constrains the value at the position it is declared at. Constrain the " \
                "contents at THEIR own position instead — #{_contents_position_remedy(nested)} — or drop the option."
        end

        # Where the contents of the refused container live, worded for the position the refusal fired at. At a
        # FIELD it is the field's own `of:`; inside a bag the container is already an `of:`, so the next rung
        # down is another one. Shared by both refusals so they cannot come to name different fixes.
        def _contents_position_remedy(nested)
          if nested
            "a bag naming a container takes an `of:` of its own (`of: { klass: Array, of: { format: ... } }`)"
          else
            "in `of:` (`of: { klass: String, format: ... }` for an Array's elements, " \
              "`of: { values: { ... } }` for a map's)"
          end
        end

        # An `inclusion:` set no value of the declared type can be a member of — a contract that rejects every
        # input while looking like a constraint. The common spelling of it is the one this ticket retires:
        # `type: Array, of: String, inclusion: { in: %w[a b] }` used to distribute over the elements, and under
        # the positional rule it asks for an array that IS the string "a", so it is refused with the position
        # named rather than silently rejecting every call.
        #
        # NOT container-only: `type: Integer, inclusion: { in: %w[1 2] }` is unsatisfiable for the same reason
        # and is as broken, so scoping this to containers would leave the identical hole open on every other
        # type.
        #
        # Membership starts from the runtime's own matcher (`TypeValidator.value_matches?`), so the guard cannot
        # disagree with the check it is predicting — the guard/projection rule in AGENTS.md — and widens from
        # there only where a cross-class comparison genuinely passes (see `_literal_may_satisfy?`). It stands
        # down wherever a passing value survives the check as written: a set it may not read, a type it cannot
        # judge, or a tolerance flag, under which nil passes and the emitted node stays satisfiable (`type:
        # ["array","null"]` with nil in the enum).
        #
        # An `if:`/`unless:` gate does NOT stand it down, and that asymmetry is the point: reflection is
        # static-maximal, so a gated can-never-match set still emits `{type: "array", enum: [...]}` — exactly
        # the unsatisfiable node the corollary forbids. A gate removes the check rather than giving the set a
        # reading: closed it enforces nothing, open it rejects everything.
        # The option keys each value-comparing validator reads its literals from. One judgment serves all three
        # because they break the same way. `other_than` is deliberately ABSENT from comparison's list: it is an
        # inverted operator, so a wrong-type bound makes the check ActiveModel runs always PASS rather than
        # never (`["a"] != 1` is true) — vacuous rather than unsatisfiable, the same reason `exclusion:` is not
        # here either. Both are judged by `VACUOUS_CONSTRAINT_KEYS` below, on the opposite verdict. The
        # remaining five are ActiveModel's own non-inverted checks (activemodel 7.2.2.2, comparison.rb
        # COMPARE_CHECKS).
        VALUE_CONSTRAINT_KEYS = {
          inclusion: %i[in within],
          acceptance: %i[accept],
          comparison: %i[equal_to greater_than greater_than_or_equal_to less_than less_than_or_equal_to],
        }.freeze

        # The INVERTED half of the same map: the option keys whose literals decide when a check FAILS rather
        # than when it passes, so wrong-type literals make the check always pass instead of never. Judged by
        # `_reject_vacuous_value_constraints!` with the identical readers and the opposite verdict.
        #
        # `exclusion:` names a set exactly as `inclusion:` does. `comparison:` contributes only `other_than`,
        # ActiveModel's one inverted operator; its other five belong above.
        VACUOUS_CONSTRAINT_KEYS = {
          exclusion: %i[in within],
          comparison: %i[other_than],
        }.freeze

        # The validators whose LITERALS reach the emitted schema, where a blank rescuing the RUNTIME cannot
        # rescue the PROJECTION — and the projection of a satisfiable contract must itself be satisfiable
        # (AGENTS.md). `inclusion:` emits its set as `enum`, so a wrong-typed set leaves a node nothing can
        # satisfy: `type: Array, presence: false, inclusion: { in: [1], allow_blank: true }` accepts `[]` at
        # runtime and emits `{type: "array", enum: [1]}`, which admits neither `1` (wrong type) nor `[]` (not in
        # the enum). A blank that only passes by being SKIPPED is not in the enum by construction, so no such
        # declaration can have a satisfiable node, and refusing it is right even though a value passes.
        #
        # Measured per key rather than assumed: `comparison:` and `acceptance:` emit only the declared type
        # (`{type: "array"}`) and carry none of their literals, so their nodes stay satisfiable and the blank
        # stand-down is sound for them. `exclusion:` emits nothing at all and is the vacuity guard's business.
        # `spec/axn/core/validations/degenerate_literals_spec.rb` locks the emitted node for both polarities, so
        # a future emitter that started projecting a comparison bound would fail there rather than here.
        PROJECTED_LITERAL_KEYS = %i[inclusion].freeze

        # The comparison operators ActiveModel decides with `==` rather than `<=>` (activemodel 7.2.2.2,
        # comparison.rb COMPARE_CHECKS): the non-inverted `equal_to` here, and the inverted `other_than` whose
        # own map is `VACUOUS_CONSTRAINT_KEYS`. Named because equality is judgeable at every declared type while
        # `<=>` is not — see `_judgeable_constraint_literals` for the measured difference.
        EQUALITY_COMPARISON_KEYS = %i[equal_to].freeze

        # The two validators whose membership is decided by the COLLECTION's own `include?` rather than by an
        # operator, and so the only ones whose equality depends on which collection was written.
        CLUSIVITY_KEYS = %i[inclusion exclusion].freeze

        # AcceptanceValidator's own default set, used when an entry names none (`acceptance: true`) — so
        # `type: Integer, acceptance: true` is judged against what it will really be compared with and refused,
        # while `type: String, acceptance: true` stands down, because `"1"` is a String.
        DEFAULT_ACCEPTANCE_SET = ["1", true].freeze

        # A tolerated nil is a passing value only if the WHOLE contract admits it, which is a question about every
        # validator on the field rather than about the constrained entry alone — so the stand-down asks
        # `Base.nil_accepted?`, the same judgment requiredness and nullability already turn on, rather than
        # reading one entry's tolerance keys.
        #
        # Two ways the narrower reading was wrong, both measured. An entry's own tolerance does not carry the
        # field: `inclusion: { in: ["a"], allow_blank: true }` on a `type: Array` field leaves the default
        # presence check in place, so `[]` is rejected by presence while every non-empty Array fails inclusion —
        # nothing passes. And a validator can admit nil without saying so: ActiveModel's acceptance skips a nil
        # outright, so `type: [Array, NilClass], presence: false, acceptance: true` accepts nil and is perfectly
        # satisfiable, while an entry-options read sees no tolerance key at all.
        #
        # `tolerance` is the DECLARATION-level pair, folded in as the shared options it becomes. Only its TRUTHY
        # half is merged: an explicit `allow_nil: false` riding along would change how `nil_accepted?` reads an
        # `acceptance:` entry (AM's own skip is disabled by exactly that key), turning a satisfiable contract
        # into a refused one.
        def _reject_unsatisfiable_value_constraints!(validations, where:, tolerance:, nested: false, allow_empty: nil)
          klasses = _judgeable_type_klasses(validations)
          return if klasses.empty?

          admitted = tolerance.select { |_key, value| value }
          return if Axn::Validation::Base.nil_accepted?(admitted.any? ? validations.merge(admitted) : validations)

          entries = Axn::Validation::Base.validator_entries(validations)
          VALUE_CONSTRAINT_KEYS.each do |key, option_keys|
            entry = entries[key]
            next unless entry
            next if _blank_can_satisfy?(entry, key, validations, tolerance, klasses, allow_empty:)

            _reject_non_reflexive_bound!(key, entry, option_keys, klasses, where:) if key == :comparison

            literals = _judgeable_constraint_literals(key, entry, option_keys, klasses)
            next if literals.nil?
            next if _constraint_satisfiable?(key, literals, klasses, cross_family: _cross_family_admissible?(key, entry))

            # Whether a blank would have passed decides only the WORDING here: the refusal itself is settled by
            # the projection invariant above, which no runtime-passing blank can satisfy.
            blank_tolerant = PROJECTED_LITERAL_KEYS.include?(key) &&
                             Axn::Validation::Base.effective_entry_options(entry, tolerance)[:allow_blank].present?

            raise ArgumentError,
                  _unsatisfiable_constraint_message(key, entry, klasses, where:, blank_tolerant:, nested:)
          end
        end

        # A bound nothing can equal makes every one of ActiveModel's five non-inverted operators reject every
        # value, so the entry admits nothing. Measured across all five (`x == NAN`, `x > NAN`, `x >= NAN`,
        # `x < NAN`, `x <= NAN` are false for every x, NaN itself included), which is why this is asked of the
        # whole option list rather than of `equal_to:` alone.
        #
        # Deliberately NOT gated on a container position, where the TYPE judgment of the four `<=>` operators is:
        # that gate exists because `<=>` crosses classes unpredictably, and non-reflexivity is not a question
        # about the bound's relationship to the declared type at all. The closed-world stand-down inside
        # `_non_reflexive_literal?` is what keeps a value object's own operators from being judged here.
        #
        # Its own message, because the shared one blames the bound's TYPE and a NaN bound is of the declared type
        # — the defect is the value, not the class.
        def _reject_non_reflexive_bound!(key, entry, option_keys, klasses, where:)
          bounds = _static_bounds(Axn::Validation::Base.validator_entry_options(entry), option_keys)
          return if bounds.empty?
          return unless bounds.any? { |bound| _non_reflexive_literal?(bound, klasses) }

          raise ArgumentError,
                "#{key}: on #{where} can never match — it compares against a bound that does not equal even " \
                "itself (a NaN), and every one of ActiveModel's non-inverted operators reports false against " \
                "one, so every value is rejected. Compare against a bound a value can actually match, and test " \
                "for NaN with `validate: ->(value) { ... }`."
        end

        # The unsatisfiable message, which names the reason the set or bound matches nothing. An empty Range
        # matches nothing whatever the declared type is, so blaming the literals' TYPE there would name a defect
        # the declaration does not have.
        def _unsatisfiable_constraint_message(key, entry, klasses, where:, blank_tolerant: false, nested: false)
          if blank_tolerant
            return "#{key}: on #{where} can never match — nothing it compares against is of type " \
                   "#{klasses.map { |klass| _declared_type_label(klass) }.join(' or ')}, so the only value that " \
                   "could pass is the blank your `allow_blank:` skips, and the emitted schema advertises the set " \
                   "as an `enum` no value can satisfy at all. Compare against literals of the declared type."
          end

          if _empty_range_set?(key, entry)
            return "#{key}: on #{where} can never match — the Range it names is empty, so it contains no value " \
                   "at all and every value is rejected. Name a Range with at least one value in it (an " \
                   "exclusive Range whose endpoints meet, or one whose bounds run backwards, is empty)."
          end

          "#{key}: on #{where} can never match — nothing it compares against " \
            "is of type #{klasses.map { |klass| _declared_type_label(klass) }.join(' or ')}, so every " \
            "value is rejected. A validator constrains the value at the position it is declared at: compare " \
            "against literals of the declared type, and constrain a container's CONTENTS at their own " \
            "position — #{_contents_position_remedy(nested)}."
        end

        # Whether the refusal being worded is about an empty Range rather than about the literals' type. Asked
        # only on the failure path, and only of the two validators that name a set — `comparison:` names bounds.
        def _empty_range_set?(key, entry)
          return false unless CLUSIVITY_KEYS.include?(key)

          collection = Axn::Validation::Base.declared_set_collection(entry)
          collection.is_a?(::Range) && _empty_range?(collection)
        end

        # Whether a BLANK value passes this entry, which makes the entry satisfiable however its literals read:
        # ActiveModel's `EachValidator` skips a blank before any validator sees it when the entry tolerates one
        # (`value.blank? && allow_blank`), so the check never runs on it and the value survives.
        #
        # The mirror of `_unskipped_literals` on the vacuity side, which reads the same skip to discount a
        # forbidden literal. Here it rescues the whole entry, and it must: refusing one of these would claim
        # "every value is rejected" of a contract with a passing value — measured, `type: Array, presence: false,
        # inclusion: { in: [1], allow_blank: true }` accepts `[]` and rejects `["a"]`.
        #
        # Three things have to hold together, and the third is what keeps the coverage: the entry must tolerate a
        # blank, the declared type must HAVE a blank instance (`NEVER_BLANK_KLASSES`, the same list the vacuity
        # guard's comparison gate reads), and the rest of the contract must admit it. Without that last one this
        # would stand down on `type: Array, inclusion: { in: ["a"], allow_blank: true }`, where the default
        # presence check still rejects `[]` and nothing passes after all.
        #
        # Emptiness is asked through the axis judgments that already own the question — the automatic presence
        # check, an explicit `presence:`, an author's `length:` floor, and `allow_empty:` — rather than a second
        # reading of the same declaration. Anything they cannot settle resolves to ADMITTED, standing the guard
        # down: this guard's safe direction is admitting a broken declaration, never refusing a working one.
        def _blank_can_satisfy?(entry, key, validations, tolerance, klasses, allow_empty:)
          return false if PROJECTED_LITERAL_KEYS.include?(key)
          return false unless Axn::Validation::Base.effective_entry_options(entry, tolerance)[:allow_blank]
          return false if _blank_rejected_by_contract?(validations, allow_empty:, tolerant: tolerance.values.any?)

          siblings = _judgeable_blank_siblings(validations, except: key, tolerance:)

          _blank_witnesses_for(klasses).any? { |klass, witness| _some_blank_survives?(siblings, klass, witness) }
        end

        # The siblings whose verdict counts at all: not the audited entry, not a disabled one, not one whose own
        # tolerance skips the blank exactly as the audited entry does, and not one a gate can skip — a gated
        # sibling is no evidence, since this verdict is what a refusal rests on and a gate can only make a
        # validator run LESS. Gates are resolved across BOTH tiers (`validates` merges the declaration's shared
        # options under the entry's own), through the reader that owns that precedence.
        def _judgeable_blank_siblings(validations, except:, tolerance:)
          decl_gates = _shared_validation_options(validations).slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)

          Axn::Validation::Base.validator_entries(validations).reject do |key, sibling|
            key == except || !sibling ||
              Axn::Validation::Base.effective_entry_options(sibling, tolerance)[:allow_blank] ||
              Axn::Validation::Base.entry_effective_gate_keys(sibling, decl_gates).any?
          end
        end

        # Whether SOME blank of this class survives every sibling — which is what the stand-down claims, and what
        # a per-witness verdict could not establish. Two siblings can each admit a blank and still share none:
        # `inclusion: { in: [" "] }` beside `acceptance: { accept: ["\t"] }` admits `" "` and `"\t"`
        # respectively and nothing at all between them, so asking each about one witness said "another blank
        # might do" twice and let an impossible contract declare.
        #
        # The candidates are ENUMERABLE wherever a value must be IN a set to pass, which is what makes the
        # negative answer sound rather than a guess: only a member can pass, so only a blank member can be the
        # blank that passes.
        def _some_blank_survives?(siblings, klass, witness)
          # A sibling rejecting every blank whatever it is leaves nothing to enumerate.
          return false if siblings.any? { |key, sibling| _one_sibling_blank_verdict(key, sibling, witness) == :rejects_every_blank }

          candidates = _candidate_blanks(siblings, klass, witness)
          return true if candidates.any? { |candidate| _all_siblings_admit_blank?(siblings, candidate) }

          # Nothing survived. That settles the class only where the candidates were exhaustive; otherwise a blank
          # this cannot name may still pass, and refusing on that would refuse a contract that works.
          !_blank_candidates_exhaustive?(siblings, klass)
        end

        def _all_siblings_admit_blank?(siblings, candidate)
          siblings.all? { |key, sibling| _one_sibling_blank_verdict(key, sibling, candidate) == :admits }
        end

        # Every blank of `klass` that could possibly pass: the class's own witness, plus the blank members of each
        # set a value must be IN to pass. Members are filtered to the WITNESS'S OWN CLASS — a blank of another
        # class is no alternative for a value that has to be a `klass` (measured: `type: String` with
        # `inclusion: { in: ["ok", []] }` was letting the empty ARRAY stand in for a String blank).
        def _candidate_blanks(siblings, klass, witness)
          alternates = siblings.flat_map do |key, sibling|
            next [] unless MEMBERSHIP_BLANK_KEYS.include?(key)

            Array(_membership_members(key, sibling)).select do |member|
              Internal::NativeMethods.blank_literal?(member) && Internal::Identity.class_of(member).equal?(klass)
            end
          end

          [witness] + alternates
        end

        # Whether the candidates above are the WHOLE list of blanks that could pass. True when the class has just
        # one blank, and true when some readable must-be-in set is present — nothing outside such a set can pass
        # it, so its blank members are exhaustive. False otherwise, where `String`'s unbounded whitespace blanks
        # mean the absence of a passing candidate proves nothing.
        def _blank_candidates_exhaustive?(siblings, klass)
          return true if _sole_blank_klass?(klass)

          siblings.any? { |key, sibling| MEMBERSHIP_BLANK_KEYS.include?(key) && !_membership_members(key, sibling).nil? }
        end

        # The validators a value must be a MEMBER of to pass, and their members under each one's own reader.
        MEMBERSHIP_BLANK_KEYS = %i[inclusion acceptance].freeze

        def _membership_members(key, sibling)
          key == :acceptance ? _acceptance_members(sibling) : _readable_set_members(sibling)
        end

        # The blank value each declared class actually HAS, as [klass, witness] pairs. A blankness question needs
        # a witness rather than a class, unlike the nil axis where `nil` is the one value — so a class with no
        # entry here yields no witness and no stand-down. Selected by `equal?` against axn's own keys rather than
        # by `Hash#[]`, which would hash the caller's class.
        def _blank_witnesses_for(klasses)
          BLANK_WITNESSES.select { |klass, _| klasses.any? { |declared| declared.equal?(klass) } }.to_a
        end

        # A blank instance of each blankable class the closed equality world vouches for. Deliberately not
        # derived (`klass.new`) — that runs the caller's constructor, and every class here is one whose blank is
        # a literal. `Set` follows its own `defined?` guard; the never-blank classes have no entry by definition.
        BLANK_WITNESSES = {
          ::String => "", ::Symbol => :"", ::Array => [], ::Hash => {}, ::NilClass => nil, ::FalseClass => false
        }.merge(defined?(Set) ? { ::Set => Set[] } : {}).freeze

        # Whether the witness above is the class's ONLY blank value, which is what lets a sibling's rejection of
        # it settle anything. Measured against ActiveSupport rather than reasoned from: emptiness is blankness for
        # a container, so `[]`/`{}`/`Set[]` are each the sole blank of their class, and `:""` is Symbol's because
        # `blank?` asks a Symbol `empty?` (`:" "` is NOT blank). `String` is the exception and the reason this
        # distinction exists at all — `blank?` matches a whitespace-only String, so `""`, `" "` and `"\t\n"` are
        # all blank and no single one of them answers for the class.
        def _sole_blank_klass?(klass) = SOLE_BLANK_KLASSES.any? { |known| known.equal?(klass) }

        SOLE_BLANK_KLASSES = [
          ::Symbol, ::Array, ::Hash, ::NilClass, ::FalseClass, (defined?(Set) ? ::Set : nil)
        ].compact.freeze

        # Whether every OTHER validator on the field admits the blank witness. The entry under audit skips it, but
        # the field is what has to admit a value, and a sibling that rejects the blank leaves nothing passing —
        # `type: Array, presence: false, inclusion: { in: [1], allow_blank: true }, exclusion: { in: [[]] }`
        # forbids the very `[]` the inclusion skips, so no Array passes at all.
        #
        # Only the families this guard judges EXACTLY are consulted, and every other answer is "admits": a
        # What ONE sibling does with ONE blank. Two answers are about that blank (`:admits`/`:rejects`); the
        # third is about the class — `ComparisonValidator` rejects a blank BEFORE it looks at any bound
        # (activemodel 7.2.2.2, comparison.rb:23), so it rejects every blank whatever it compares against, and no
        # enumeration of alternatives could help.
        #
        # Anything this cannot read exactly answers `:admits`, standing the guard down rather than guessing:
        # `format:`, `numericality:`, a `validate:` callable and an unreadable set all reach that fallback, which
        # under-restricts. A sibling whose own tolerance skips the blank never reaches here at all.
        def _one_sibling_blank_verdict(key, sibling, witness)
          case key
          # `ComparisonValidator` rejects a blank BEFORE it looks at any bound (activemodel 7.2.2.2,
          # comparison.rb:23), so it rejects them all whatever it compares against.
          when :comparison then :rejects_every_blank
          when :inclusion then _excluding_set_verdict(_readable_set_members(sibling), witness)
          when :acceptance
            _excluding_set_verdict(_acceptance_members(sibling), witness,
                                   skips_nil: Axn::Validation::Base.acceptance_admits_nil?(
                                     Axn::Validation::Base.validator_entry_options(sibling),
                                   ))
          # An exclusion set rejects only what it NAMES, so it never speaks for the class.
          when :exclusion
            _readable_set_members(sibling)&.any? { |member| member == witness } ? :rejects : :admits
          else :admits
          end
        end

        # The verdict of a set a value must be IN to pass — `inclusion:`, and `acceptance:` under its own reader.
        # `skips_nil:` is acceptance's own default nil-skip, asked through `Base.acceptance_admits_nil?` rather
        # than assumed: an entry may disable it (`allow_nil: false`), and then a nil witness really is compared
        # against the set and really can be rejected.
        def _excluding_set_verdict(members, witness, skips_nil: false)
          return :admits if skips_nil && Internal::Identity.nil_value?(witness)
          return :admits if members.nil? # a set this cannot read admits, rather than being guessed at
          return :admits if members.any? { |member| member == witness }

          :rejects
        end

        # An `acceptance:` entry's set, read by ITS rule rather than the clusivity one: `AcceptanceValidator`
        # tests `Array(accept).include?(value)`, so a Hash `accept:` is searched as its `[key, value]` PAIRS and
        # only the shapes `Array()` leaves alone are readable. With no `accept:` of its own it compares against
        # ActiveModel's default set, which is what makes a bare `acceptance: true` reject an Array blank.
        def _acceptance_members(sibling)
          opts = Axn::Validation::Base.validator_entry_options(sibling)
          accept = Internal::ShapeGraph.carries_key?(opts, :accept) ? opts[:accept] : DEFAULT_ACCEPTANCE_SET
          return nil unless Axn::Validation::Base.literal_set_collection?(accept)
          return nil unless accept.all? { |member| _vouched_equality_operand?(member) }

          accept
        end

        # The members of a clusivity set this guard may read, or nil for one it may not — and nil is load-bearing,
        # since every caller reads it as "admits" and collapsing it into a membership answer would turn a set axn
        # cannot read into a refusal.
        #
        # Nil is answered for any member outside the closed equality world, or one carrying its own equality, for
        # the reason `_non_reflexive_literal?` stands down on the same: callers compare these with the member's
        # own `==`, and a member axn has not vouched for would be answering a declaration question for it.
        def _readable_set_members(entry)
          collection = Axn::Validation::Base.declared_set_collection(entry)
          if collection.is_a?(::Range)
            # An empty Range holds nothing, which is readable and definite. Any other Range is not: its
            # membership is decided by `<=>` against bounds the witness need not be comparable with, and a wrong
            # guess in either direction is a refusal this guard must not make.
            return _empty_range?(collection) ? [] : nil
          end

          members = Axn::Validation::Base.literal_set_members(entry)
          return nil if members.nil?
          return nil unless members.all? { |member| _vouched_equality_operand?(member) }

          members
        end

        # Whether ONE value's equality is the one its class carries and one this guard vouches for — the pair of
        # conditions `_non_reflexive_literal?` requires of a bound, asked here of a set member.
        def _vouched_equality_operand?(value)
          klass = Internal::Identity.class_of(value)

          _judgeable_equality?(klass) && _class_owned_equality?(value, klass)
        end

        # Whether something in this declaration OTHER than the tolerant entry rejects an empty value. Read off
        # the emptiness axis rather than re-derived: `allow_empty: false` installs a check of its own, the
        # automatic presence check covers a declaration that named no requiredness signal, and an explicit
        # `presence:`/`length:` floor answers for itself. Asked before the axis is settled, so the automatic
        # check is predicted through the same `_default_presence_applies?` that will install it.
        def _blank_rejected_by_contract?(validations, allow_empty:, tolerant:)
          return true if allow_empty == false
          return true if _default_presence_applies?(validations, allow_empty:, tolerant:)

          # An AUTHORED entry counts only where a gate cannot skip it, for the reason a sibling does: this is an
          # affirmative claim that the blank is rejected, and a gate can only make a validator run LESS. Measured
          # — `length: { minimum: 1, if: -> { false } }` never runs, so `[]` really does pass. The two answers
          # above need no such test: `allow_empty: false` installs axn's own ungated check, and the automatic
          # presence check is only inferred where the author named no requiredness signal at all.
          decl_gates = _shared_validation_options(validations).slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
          return true if _ungated_entry?(validations[:presence], decl_gates) &&
                         _presence_emptiness_answer(validations, tolerant:) == :rejected
          return true if _ungated_entry?(validations[:length], decl_gates) &&
                         _length_emptiness_answer(validations) == :rejected

          false
        end

        # Whether nothing can skip this entry — its own `if:`/`unless:` or one the declaration hands it.
        def _ungated_entry?(entry, decl_gates) = Axn::Validation::Base.entry_effective_gate_keys(entry, decl_gates).empty?

        # An `exclusion:` set — or an `other_than:` bound — no value of the declared type could ever be, which
        # makes the check impossible to FAIL. The author wrote a constraint, the class defines cleanly, and
        # every value passes: "the strongest form of a silently ignored option", in
        # `_reject_validator_context_scope!`'s words. `type: Array, exclusion: { in: ["admin"] }` is the
        # spelling that reaches here most often — no Array is the String "admin", so the set forbids nothing
        # any Array could be, and `["admin"]` passes the check it names.
        #
        # The mirror of the guard above, and deliberately not folded into it: unsatisfiable asks whether any
        # value can PASS, vacuous whether any can FAIL, and the two verdicts are opposite on the same evidence.
        # So the literals, the readers and the closed equality world are shared outright, and only the verdict
        # is negated — a set is vacuous exactly when its `inclusion:` mirror would be unsatisfiable.
        #
        # Two doctrine differences follow from the inversion, both of them the reason this is its own method:
        #
        # TOLERANCE is read for the OPPOSITE purpose. The satisfiability guard stands down under it, because a
        # tolerated nil is a value that PASSES; no amount of passing makes a check something can fail, so
        # tolerance never rescues a declaration here. What it does instead is DISCOUNT WITNESSES: ActiveModel
        # skips a tolerated value outright, so a forbidden literal the flag skips is one no admitted value can
        # ever be compared against — `type: NilClass, exclusion: { in: [nil] }, allow_nil: true` forbids only
        # the nil the flag exempts, and `type: Array, exclusion: { in: [[]] }, allow_blank: true` forbids only
        # the blank one. Both accept every input, and both are refused once the skipped literal stops counting.
        #
        # A GATE does not rescue one either, but for a simpler reason than above: `exclusion:` emits nothing
        # into the schema, so there is no static-maximal node to argue from. A gate can only remove the check.
        # Closed it enforces nothing, open it enforces nothing — there is no reading under which the
        # declaration means what it says.
        def _reject_vacuous_value_constraints!(validations, where:, tolerance:, nested: false)
          klasses = _judgeable_type_klasses(validations)
          return if klasses.empty?

          entries = Axn::Validation::Base.validator_entries(validations)
          VACUOUS_CONSTRAINT_KEYS.each do |key, option_keys|
            entry = entries[key]
            next unless entry

            literals = _vacuous_constraint_literals(key, entry, option_keys, klasses, tolerance)
            next if literals.nil?

            witnesses = _witness_literals(key, literals, entry, tolerance, klasses)
            next if _any_literal_may_satisfy?(witnesses, klasses, cross_family: _cross_family_admissible?(key, entry))

            raise ArgumentError, _vacuous_constraint_message(key, entry, klasses, where:, nested:)
          end
        end

        # The vacuity message, worded the way its mirror above is: an empty Range forbids nothing whatever the
        # declared type is, so naming the literals' TYPE would name a defect the declaration does not have.
        def _vacuous_constraint_message(key, entry, klasses, where:, nested: false)
          if _empty_range_set?(key, entry)
            return "#{key}: on #{where} enforces nothing — the Range it names is empty, so it forbids no value " \
                   "at all and every value passes. Name a Range with at least one value in it (an exclusive " \
                   "Range whose endpoints meet, or one whose bounds run backwards, is empty)."
          end

          "#{key}: on #{where} enforces nothing — no value of type " \
            "#{klasses.map { |klass| _declared_type_label(klass) }.join(' or ')} could be one of the " \
            "literals it forbids, so every value passes. A validator constrains the value at the " \
            "position it is declared at: forbid literals of the declared type, and constrain a container's " \
            "CONTENTS at their own position — #{_contents_position_remedy(nested)}."
        end

        # The forbidden literals that could actually be the value that FAILS. Two filters, and the second is
        # asked only of `comparison:` because the two validators reach their verdict by different routes.
        def _witness_literals(key, literals, entry, tolerance, klasses)
          literals = _reflexive_literals(literals, klasses) if key == :comparison

          _unskipped_literals(literals, entry, tolerance)
        end

        # A bound nothing can equal — not even itself — is no witness: `other_than:` is `!=`, so the check
        # reports a difference from every value including the bound, and passes always. `Float::NAN` and
        # `BigDecimal::NAN` are the two such values among the types this guard vouches for (measured).
        #
        # Deliberately NOT applied to `exclusion:`, and the difference is measured rather than assumed: a
        # collection's membership test short-circuits on object IDENTITY before it ever asks `==`, so
        # `[Float::NAN].include?(Float::NAN)` and `Set[Float::NAN].include?(Float::NAN)` are both true and the
        # set really does forbid the value. Discounting it there would refuse a contract that enforces.
        #
        # The stand-downs that keep this safe live in `_non_reflexive_literal?`, which the satisfiability guard
        # reads on the opposite verdict — so a bound outside the closed world, or one carrying its own equality,
        # is discounted by neither guard.
        def _reflexive_literals(literals, klasses)
          literals.reject { |literal| _non_reflexive_literal?(literal, klasses) }
        end

        # THE definition of "this literal cannot equal itself", read by both guards on opposite verdicts: the
        # vacuity guard discounts such a bound as a witness (`other_than:` passes always), while the
        # satisfiability guard refuses one outright (every non-inverted operator rejects always). One definition
        # so the two can never disagree about the same bound, and so the single place that runs an operator on a
        # caller's value stays single.
        #
        # BOTH sides must be ones the closed world vouches for, exactly as `_literal_may_satisfy?` requires — and
        # this runs BEFORE that judgment, so it repeats the stand-down rather than inheriting it. The declared
        # type decides as much as the bound does: a value object whose `==` answers for the bound really can
        # differ from it, so `type: Token, comparison: { other_than: Float::NAN }` has a failing input when
        # `Token#==` accepts NaN, and discounting the bound there would refuse a contract that enforces. Asked of
        # EVERY declared branch, since a runtime value takes one and any un-vouched-for branch could supply the
        # equality.
        def _non_reflexive_literal?(literal, klasses)
          return false unless klasses.all? { |klass| _judgeable_equality?(klass) }

          klass = Internal::Identity.class_of(literal)
          return false unless _judgeable_equality?(klass) && _class_owned_equality?(literal, klass)

          # rubocop:disable Lint/BinaryOperatorWithIdenticalOperands
          # The identical operands ARE the check: a value unequal to itself can never equal anything. Asked
          # with `!=` rather than a negated `==` because that is the operator ActiveModel applies here.
          literal != literal
          # rubocop:enable Lint/BinaryOperatorWithIdenticalOperands
        end

        # Whether the equality the probe above would run is the one the CLASS carries, rather than one this
        # particular object does. The probe is the only place this guard runs an operator at all, and a
        # per-object override makes its answer foreign twice over: it executes the caller's own code, and it
        # generalizes one object's behaviour to every value of the declared type. Measured — a `String` bound
        # carrying `def bound.!=(other) = true` reports non-reflexive, while an ordinary `"x"` uses
        # `String#==` and really does fail the check, so discounting the bound refuses a working contract.
        #
        # Decided by OWNERSHIP rather than by another probe: both operators must be owned by the exact class
        # or something in its ancestry, which a singleton class never is. `Method#owner` is read through
        # `NativeMethods`, and ancestry through its bound `Module#ancestors`, so nothing the object defines
        # answers the question. `==` is asked alongside `!=` because BasicObject's `!=` negates it, so an
        # override of either decides the probe (`Date#==` comes from `Comparable`, which its ancestry carries).
        def _class_owned_equality?(literal, klass) = _class_owned_operators?(literal, klass, %i[!= ==])

        # The ownership test itself, over whichever operators the caller names — shared by the equality probe
        # above and by the Range emptiness probe, which asks the same question of `<=>`.
        def _class_owned_operators?(literal, klass, names)
          names.all? do |name|
            owner = Internal::NativeMethods.method_owner(literal, name)
            next false unless owner

            owner.equal?(klass) || Internal::NativeMethods.includes_module?(klass, owner)
          end
        end

        # The forbidden literals that could still be COMPARED against an admitted value. ActiveModel's
        # `EachValidator` skips a tolerated value before any validator sees it (`value.nil? && allow_nil`,
        # `value.blank? && allow_blank`), so a literal the flag exempts can never be the value that fails —
        # it is not a witness, and counting it would certify a check nothing can fail.
        #
        # Tolerance is resolved per ENTRY through `effective_entry_options`, the same precedence `validates`
        # itself applies (declaration defaults under the entry's own options), so an entry turning a
        # declaration-wide flag back off keeps its literals: with `allow_nil: false` on the entry, nil really
        # is compared, and the declaration really can fail.
        #
        # Blankness is `Internal::NativeMethods.blank_literal?` — ActiveSupport's own reading of `blank?`,
        # which is what the skip tests, decided through bound reads so a literal cannot answer for itself.
        # Nil is asked by identity for the same reason. `allow_blank` subsumes the nil case (a nil is blank),
        # and both are asked so an `allow_nil`-only entry still discounts its nil.
        def _unskipped_literals(literals, entry, tolerance)
          opts = Axn::Validation::Base.effective_entry_options(entry, tolerance)
          allow_nil = opts[:allow_nil]
          allow_blank = opts[:allow_blank]
          return literals unless allow_nil || allow_blank

          literals.reject do |literal|
            (allow_blank && Internal::NativeMethods.blank_literal?(literal)) ||
              (allow_nil && Internal::Identity.nil_value?(literal))
          end
        end

        # The literals ONE inverted entry will be judged against, or nil for an entry that cannot be judged.
        # Both routes delegate to the readers the satisfiability guard already uses, so neither validator grows
        # a second way to read the same option.
        #
        # `exclusion:` names its set exactly where `inclusion:` does, Range judgment included: a Range is
        # decided by `<=>`, which is nil across unrelated classes, so `(1..5)` forbids no Array however the
        # array is spelled — and at a SCALAR position it stands down, since `(1.0..5.0).cover?(3)` is true.
        #
        # `other_than:` is judged at EVERY type, where the five non-inverted bounds are judged only at a
        # container position. That gate exists because `<=>` decides those operators and a `Comparable` value
        # object's `<=>` routinely accepts another class, which no ancestry test predicts. `other_than` is
        # `!=` (activemodel 7.2.2.2, comparison.rb COMPARE_CHECKS), and equality has no such hole here: the
        # closed world stands down on any class whose `==` axn does not vouch for, so the gate would only cost
        # coverage — `type: String, comparison: { other_than: 1 }` is as vacuous as the container spelling.
        # The bound is read by `key?`, since `other_than: false` is a real bound, and a Symbol or Proc stands
        # down because ActiveModel resolves it against the record per call (`ResolveValue`).
        def _vacuous_constraint_literals(key, entry, option_keys, klasses, tolerance)
          return _judgeable_set_members(entry, klasses) if key == :exclusion

          opts = Axn::Validation::Base.validator_entry_options(entry)
          bounds = option_keys.select { |option| opts.key?(option) }.map { |option| opts[option] }
          return nil if bounds.empty?
          return nil if bounds.any? { |bound| _dynamic_bound?(bound) }
          return nil unless _blank_cannot_reach_comparison?(entry, tolerance, klasses)

          bounds
        end

        # Whether the bound is the ONLY thing a `comparison:` entry can reject — which is what makes the
        # equality judgment above sufficient. It usually is not: ActiveModel's `ComparisonValidator` rejects a
        # blank value BEFORE it looks at any bound (`value.nil? || value.blank?` → `errors.add(:blank)`,
        # activemodel 7.2.2.2, comparison.rb:23), so an entry on a type that HAS a blank value rejects that
        # value whatever the bound says, and enforces something after all.
        #
        # Measured: `type: Array, comparison: { other_than: 1 }` rejects `[]`, and on a `presence: false`
        # field the entry is the only thing rejecting it. So the vacuity question is only reachable where no
        # blank value can arrive — a declared type with no blank instance, or an entry whose `allow_blank`
        # skips them before the check runs. Every other `comparison:` declaration stands down.
        #
        # `exclusion:` has no such branch — `Clusivity` compares membership and nothing else — which is why
        # this asks only about the comparison route.
        def _blank_cannot_reach_comparison?(entry, tolerance, klasses)
          return true if Axn::Validation::Base.effective_entry_options(entry, tolerance)[:allow_blank]

          klasses.all? { |klass| NEVER_BLANK_KLASSES.any? { |known| known.equal?(klass) } }
        end

        # A declaration whose admissible SIZES form an empty interval — a floor it imposes sitting above a
        # ceiling it also imposes, so nothing of the declared type can satisfy it. One test closes what were
        # four spellings of the same defect (PRO-3220): `absence:` against the non-emptiness floor a typed
        # field carries by default, a `length:` ceiling of 0 against that same floor, a `length:` naming
        # `minimum: 3, maximum: 2` in one entry, and an `inclusion:` set whose every member is outside the
        # interval. They differ only in which spelling supplies which bound.
        #
        # Both bounds come from `Reflection::Schema`'s own derivations rather than from a re-reading beside
        # them — the guard/projection rule in AGENTS.md — so what this refuses is exactly the pair of bounds
        # that would have been emitted. That is also why an `if:`/`unless:` gate does not stand it down:
        # reflection is static-maximal, so a gated bound is still emitted, and the node still carries a floor
        # above its own ceiling.
        #
        # A nil tolerance DOES stand it down, and the same reasoning as the value-constraint guard applies: a
        # tolerated nil is a passing value, and the emitted node stays satisfiable through the null branch its
        # nullability adds. Asked through `Base.nil_accepted?`, the judgment requiredness and nullability
        # already turn on, rather than by reading one entry's tolerance keys.
        def _reject_unsatisfiable_size_interval!(validations, where:)
          return if Axn::Validation::Base.nil_accepted?(validations)

          _reject_blank_axis_complement!(validations, where:)

          return if _bound_bearing_entry_gated?(validations)

          minimum = Internal::Reflection::Schema.declared_size_minimum(validations)
          maximum = Internal::Reflection::Schema.declared_size_maximum(validations)

          _raise_empty_size_interval!(validations, where, minimum, maximum) if _empty_interval?(validations, minimum, maximum)
          _reject_size_closed_inclusion_set!(validations, where:, minimum:, maximum:)
        end

        # Whether the bounds this declaration derives admit no size at all — a floor above the ceiling, on a
        # declaration whose every branch that ceiling actually bounds.
        def _empty_interval?(validations, minimum, maximum)
          return false unless minimum && maximum && minimum > maximum

          _every_branch_is_bounded?(validations)
        end

        # Whether every branch this declaration names is one the ceiling actually bounds — the question a
        # union makes necessary, since a value need satisfy only ONE branch and one unbounded branch is enough
        # to sink the claim that nothing satisfies the declaration.
        #
        # Only an `absence:`-derived ceiling can be escaped, because it is a statement about the BLANK axis
        # rather than the size one: it bounds a value to size 0 only where that value's blankness implies size
        # 0. For `:boolean` it does not — `false` is blank, so the `absence:` accepts it, and LengthValidator
        # measures its rendering rather than a length it has none of. So
        # `type: [Array, :boolean], presence: false, absence: true, length: { minimum: 1 }` is satisfied by
        # `false` on every call, though its Array branch admits nothing at all.
        #
        # An earlier cut of this tried to WITNESS that branch instead — to check that `false` satisfies the
        # declaration and stand down only then. That does not terminate. A witness is a claim that something
        # passes, so it owes every check in the declaration a pass, and each review round found another check
        # it had not been asked: the author's own `length:` ceiling, then a closed `inclusion:` set, then
        # `exclusion:`/`format:`/`numericality:`/`comparison:`/`acceptance:` — six of them measured in one
        # sweep, with a custom `validate:` unanswerable in principle. Deciding a value against every validator
        # in a declaration is a satisfiability solver, and building one inside a guard is the same unbounded
        # treadmill `Internal::NativeMethods` exists to refuse.
        #
        # So the question is about the DECLARED TYPE, which is finite and knowable, rather than about a value:
        # is every branch bounded. It costs three narrow refusals the witness version got right — a floor above
        # what `false` measures, and an `is:`/`maximum:` that excludes it — and buys a rule that cannot acquire
        # a new hole from a validator nobody thought about. Under-restriction leaves a broken contract
        # declaring; over-restriction rejects a working one, and only the second is unrecoverable.
        # Scoped to an absence-derived ceiling by the first line, and the existing suite is what caught its
        # absence: a `length:` ceiling is a size bound the author wrote, so it bounds every branch by
        # construction and this question does not arise — without the gate, `type: String,
        # length: { minimum: 3, maximum: 2 }` stopped being refused because a String's blank values are not its
        # empty ones.
        def _every_branch_is_bounded?(validations)
          return true unless Internal::Reflection::Schema.absence_bounds_size?(validations)

          Internal::Reflection::Schema.absence_ceiling_bounds_every_token?(validations)
        end

        # The validator entries that can supply a bound to the size rules below, or the set they scan. Kept as a
        # list rather than asked of each derivation in turn, because the derivations are the EMITTER's and are
        # rightly static-maximal — the question here is a different one.
        # `absence` is deliberately NOT here, though it does supply a ceiling. Its derivation
        # (`Schema.absence_bounds_size?`) asks the gate question itself and answers "no ceiling" for a gated
        # entry, so naming it here only made a gated `absence:` stand down bounds it never contributed —
        # measured, that suppressed 21 correct refusals in the guard's product, every one of them a gated
        # `absence:` beside an `inclusion:` set whose member the EMPTINESS floor excludes, which is a
        # contradiction the absence entry plays no part in. The other three belong here because their
        # derivations are the emitter's and rightly static-maximal: `declared_length_floor`/`_ceiling` count a
        # gated bound as written, `presence_rejects_blank?` reads a gated entry's tolerance as live, and the set
        # scan does not consult the `inclusion:` entry's own gate.
        BOUND_BEARING_VALIDATOR_KEYS = %i[presence length inclusion].freeze

        # Whether any entry that could supply a bound can be skipped on a given call — its OWN gate and any it
        # inherits from the declaration alike, which is what makes this the only gate test the size rules need.
        # A declaration-level `if:` reaches every entry here, so it stands the rules down through this one test
        # rather than through a check of its own; and reaching them THROUGH the per-entry model is what keeps
        # ActiveModel's precedence intact, since a blank nested `if:` drops the shared gate for that key and
        # leaves the entry ungated after all (`presence: { if: nil }, absence: { if: nil }, if: -> { false }`
        # really does enforce both checks on every call).
        #
        # The size rules claim "no value satisfies this contract", and a bound that is sometimes not enforced
        # cannot support that claim:
        # `length: { minimum: 3, maximum: 2, if: -> { false } }` really does admit `["a"]` on every call where
        # its gate is closed, and a floor read out of a gated `presence:` is no floor on those calls either.
        #
        # Coarser than it strictly needs to be — one gated entry stands the whole comparison down, rather than
        # only the bound it supplies — and deliberately so: under-restriction leaves a broken contract
        # declaring, while over-restriction rejects a working one, and only the second is unrecoverable.
        #
        # This is where the size rules part company with the EMITTER, which is static-maximal and will still
        # emit `{minItems: 3, maxItems: 2}` for the gated entry above. That node is unsatisfiable while its
        # contract is not, which is a real defect — but it is the emitter's gate policy, it predates this
        # guard (a gated `length:` ceiling has emitted that way since PRO-3192), and the corollary this rule
        # enforces is about refusing a CONTRACT that admits nothing.
        def _bound_bearing_entry_gated?(validations)
          gates = _shared_validation_options(validations)
          keys = BOUND_BEARING_VALIDATOR_KEYS + [Internal::FieldConfig::NON_EMPTINESS_KEY]

          keys.any? do |key|
            entry = validations[key]

            entry && Axn::Validation::Base.entry_effectively_gated?(entry, gates)
          end
        end

        # `presence:` and `absence:` are exact complements: ActiveModel's presence check errors on a `blank?`
        # value and its absence check errors on a `present?` one (activemodel 8.1.3.1, presence.rb / absence.rb),
        # so a declaration carrying both live admits nothing whatever the declared type — no value is blank and
        # present at once.
        #
        # That last step is the assumption this rule rests on, and it is ActiveSupport's: `present?` is defined
        # as `!blank?`, and every core class AS specializes defines the pair together. A class overriding ONE of
        # them is outside it — a non-empty `Array` subclass answering `present? => false` satisfies both checks
        # — but that is an assumption the whole size layer already makes rather than this rule's own: the
        # `minItems: 1` reflection emits for a bare `presence:` is unsound against exactly the same object
        # (measured: a subclass answering `blank? => true` with contents satisfies the emitted node and is
        # rejected at runtime). Refusing to make it here would mean deleting the rule, since a declared `type:`
        # admits every subclass and nothing at declaration time can see what will arrive. Asked FIRST, and
        # separately from the size interval, because it is the one question here that needs no size reasoning:
        # the blank axis lands on the size axis only for a type whose blank values are its empty ones, and for
        # a `String` it does not (`"  "` is blank, and two characters long).
        #
        # The presence half is usually the check axn infers, which is why this is reachable from a declaration
        # naming only `absence:` — and why `allow_empty: true` / `presence: false`, which suppress that check,
        # are the fix rather than a workaround.
        #
        # A GATE on either entry stands the rule down, and this is the one place in this file where a gate
        # rescues rather than being counted static-maximally. The reason is that the gated pair has a legitimate
        # reading the ungated pair does not: `presence: { unless: :archived? }, absence: { if: :archived? }` is
        # a working contract, and no structural test can tell complementary conditions from identical ones
        # (two Procs are never comparable). Refusing it would reject a declaration that works, which this guard
        # must never do — so it under-restricts here, and the emitted node is unaffected either way.
        #
        # EFFECTIVE gates, not each entry's own: the question is whether both checks run on every call, and a
        # DECLARATION-level `if:` stops them both just as surely as a nested one stops either. (That is the
        # opposite of what `_entry_guaranteed_to_run?` answers, and rightly — it asks whether one entry can be
        # skipped independently of its siblings, which a shared gate never does.)
        def _reject_blank_axis_complement!(validations, where:)
          entries = Axn::Validation::Base.validator_entries(validations)
          absence = entries[:absence]
          return unless absence

          # That a `presence:` entry is PRESENT is not that it rejects anything: ActiveModel skips a
          # blank-tolerant entry outright for a blank value, and blank values are the only ones a presence
          # check ever rejects — so `presence: { allow_blank: true }` enforces nothing and leaves `absence:`
          # unopposed. Asked through the emitter's own `presence_rejects_blank?`, THE definition of "does an
          # active presence check here reject every blank value", so the half this rule leans on is the same
          # half the emitted floor is derived from.
          #
          # `absence:`'s own tolerances need no such test: it rejects only NON-blank values, and both
          # `allow_blank:` and `allow_nil:` withdraw it from values it already accepts.
          return unless Internal::Reflection::Schema.presence_rejects_blank?(validations)

          gates = _shared_validation_options(validations)
          return if [entries[:presence], absence].any? { |entry| Axn::Validation::Base.entry_effectively_gated?(entry, gates) }

          # Both exits are named rather than the one that applies: by the time this runs, an inferred presence
          # check and an authored one are the same entry (`_apply_default_presence!` writes a bare `true`, and
          # the nil-skip pass rewrites either into an options bag), so which was written is no longer legible
          # here — and a message that guessed would send half its readers the wrong way.
          raise ArgumentError,
                "presence: and absence: on #{where} admit no value at all: they are exact complements — " \
                "presence rejects every blank value, absence rejects every value that is not blank — so " \
                "nothing satisfies both. Drop one of the two: `allow_empty: true` (or `presence: false`) " \
                "suppresses the non-emptiness check, including the one axn infers where a declaration " \
                "names none."
        end

        def _raise_empty_size_interval!(validations, where, minimum, maximum)
          authored = _size_floor_authored?(validations, minimum)
          floor_source = authored ? "from `length:`" : "the non-emptiness check a typed field carries by default"
          remedy = if authored
                     "Correct the bounds so the floor does not sit above the ceiling."
                   else
                     "Widen the ceiling, or drop the floor with `allow_empty: true` (or `presence: false`)."
                   end

          raise ArgumentError,
                "#{where} admits no value at all: it requires a size of at least #{minimum} (#{floor_source}) " \
                "and at most #{maximum} (#{_size_ceiling_source(validations)}), an empty interval — so every " \
                "value is rejected, and the reflected schema carries a floor above its own ceiling, which no " \
                "caller can satisfy. #{remedy}"
        end

        # Whether the AUTHOR's own `length:` supplied the floor, rather than the emptiness axis — which decides
        # both how the message names the bound and which remedy it offers, since `allow_empty:` moves one floor
        # and not the other. The floor the emitter derived is what settles it: `declared_size_minimum` prefers
        # an emittable `length:` floor and falls back to the 1 the non-emptiness axis imposes, so a `length:`
        # floor that does not equal the derived minimum is one the derivation set aside (a blank-tolerant
        # entry), leaving the axis to do the talking.
        def _size_floor_authored?(validations, minimum)
          declared = Axn::Validation::Base.declared_length_floor(_effective_length_options(validations))

          Axn::Validation::Base.emittable_length_floor?(declared) && declared == minimum
        end

        # The ceiling's spelling, asked through the emitter's own predicate so the message cannot name one
        # source while the derivation used the other.
        def _size_ceiling_source(validations)
          Internal::Reflection::Schema.absence_bounds_size?(validations) ? "from `absence:`" : "from `length:`"
        end

        # An `inclusion:` set every member of which the size bounds exclude. The same "does any member leave a
        # value able to satisfy this" question `_reject_unsatisfiable_value_constraints!` asks of the declared
        # TYPE, asked here of the declared sizes — and a member must clear both, since a member of the wrong
        # type is rejected whatever its size.
        #
        # Only a LITERAL set is judged. A Range's bounds are not its members, so measuring them would answer a
        # different question; every other unreadable set stands the check down, the direction this guard must
        # prefer.
        def _reject_size_closed_inclusion_set!(validations, where:, minimum:, maximum:)
          # A live `absence:` constrains the set even where it names no SIZE — on a `String` it rejects every
          # non-blank value while no size key expresses that, so the bounds are both nil and the members are
          # still constrained. Without this the mirror case below (`absence:` beside a non-blank member) was
          # unreachable: the scan returned here before the member was ever weighed.
          return if minimum.nil? && maximum.nil? && !Internal::Reflection::Schema.absence_bounds_blankness?(validations)

          klasses = _judgeable_type_klasses(validations)
          return if klasses.empty?

          entry = Axn::Validation::Base.validator_entries(validations)[:inclusion]
          return unless entry
          return if _blank_value_bypasses_set?(validations, entry, minimum)

          return unless _membership_is_the_members_own_equality?(entry)

          members = Axn::Validation::Base.literal_set_members(entry)
          return if members.nil? || members.empty?

          return if members.any? { |member| _member_size_admissible?(member, klasses, minimum, maximum, validations) }

          # Which axis closed the set decides the message, and the test is which one still ADMITS the member:
          # where a member clears the size bounds and fails the blank axis, size cannot explain the refusal and
          # its wording is actively wrong (`" "` is not outside "at least 1" — it is blank, and an `absence:` on
          # a String names no size at all, which rendered the bounds as an empty "()"). Where the bounds exclude
          # it too, they are the better diagnosis: for a container blank and empty are the same fact, so the
          # size message says it in the axis the author wrote and names `allow_empty:` as the fix.
          if members.any? { |member| _member_size_within_bounds?(member, minimum, maximum) }
            _raise_blank_axis_closed_inclusion_set!(where, validations)
          else
            _raise_size_closed_inclusion_set!(where, minimum, maximum)
          end
        end

        # The set is closed by the BLANK axis rather than by a size bound: either every member is blank and a
        # live `presence:` rejects blank values, or every member is non-blank and a live `absence:` rejects
        # those. Named separately from the size message because the fix differs — the author has to relax the
        # blank check or change the members, and widening a size bound does nothing.
        def _raise_blank_axis_closed_inclusion_set!(where, validations)
          if Internal::Reflection::Schema.absence_bounds_blankness?(validations)
            raise ArgumentError,
                  "inclusion: on #{where} can never match — `absence:` rejects every value that is not blank, " \
                  "and no member of the set is blank, so every value is rejected. Drop the `absence:`, or " \
                  "include a blank member (\"\" for a String)."
          end

          raise ArgumentError,
                "inclusion: on #{where} can never match — every member of the set is BLANK, and this " \
                "declaration's presence check rejects every blank value, so every value is rejected. Note that " \
                "for a String blankness is not emptiness: \" \" is one character long, so a size bound cannot " \
                "express this and `minLength` does not. Allow blank values (`allow_empty: true` drops the " \
                "presence check a typed field carries by default, or `presence: false` disables an explicit " \
                "one), or include a non-blank member."
        end

        # Whether a BLANK value could get through without the set being consulted at all, which would make the
        # member scan prove nothing: ActiveModel skips a blank-tolerant entry outright for such a value, so the
        # set stops being the only way through. Whether one can actually arrive is a question about the rest of
        # the contract rather than about this entry, asked in two steps.
        #
        # First, the emptiness axis, which is what the sibling guard's measured note is really about: an
        # entry's own tolerance does not carry the field, because a live presence or non-emptiness check
        # rejects EVERY blank value whatever its size — so `inclusion: { in: ["a"], allow_blank: true }` on a
        # bare `type: Array` still admits nothing, the `[]` the tolerance would have let past being rejected
        # before the set is reached. Asked through the emitter's own `empty_value_rejected?`, the same
        # judgment the floor is derived from.
        #
        # Then the size bounds, and here the type decides. Where every declared type's blank values are its
        # EMPTY ones a blank value measures 0, so a floor above 0 excludes it. For a `String` it does not:
        # `"  "` is blank and two characters long, so a blank value of very nearly any size exists and no size
        # bound rules one out.
        #
        # Read through the entry's EFFECTIVE options, so a declaration-level `allow_blank:` counts exactly as
        # the entry's own does.
        def _blank_value_bypasses_set?(validations, entry, minimum)
          return false unless Axn::Validation::Base.effective_entry_options(entry, _shared_validation_options(validations))[:allow_blank]
          return false if Internal::Reflection::Schema.empty_value_rejected?(validations)
          return true unless Internal::Reflection::Schema.blank_values_are_empty?(validations)

          minimum.nil? || minimum.zero?
        end

        # Whether ONE set member leaves a value able to satisfy the declaration: of a type the field admits,
        # and of a size the bounds admit. Type membership reuses the shared literal judgment, which already
        # stands down on any pair it cannot judge.
        #
        # Measuring the member is only evidence about the values it can MATCH if its equality is one axn
        # vouches for, because `Array#include?` dispatches `member == candidate` — so the member decides
        # membership itself, and one matching `[1]` while measuring 0 really does satisfy a `minimum: 1` floor.
        #
        # The size itself is then read through the emitter's ownership test, which answers nil for a value
        # whose measurement is not Ruby's own.
        #
        # THE ASSUMPTION THIS RESTS ON, stated because it cannot be checked here: that a value MATCHING the
        # member measures as the member does. `Array#==` compares CONTENTS, so an `Array` subclass with empty
        # contents and a `length` of its own is matched by the member `[]` and measured by ActiveModel as
        # whatever it says — `type: Array, presence: false, length: { minimum: 3 }, inclusion: { in: [[]] }` is
        # satisfied by `Class.new(Array) { def length = 3 }.new` and by no honest value (measured).
        #
        # The assumption is kept, and the reason is SCOPE rather than a trade. A value whose `length` contradicts
        # its own contents is a class lying about itself, which is non-standard behaviour and not this gem's to
        # defend against — the same line AGENTS.md draws for a foreign object's `to_sym`, `encoding` or
        # `inspect`. Nothing here hardens against such a value; it simply is not counted as the witness that
        # would make a declaration satisfiable.
        #
        # That line does NOT license refusing anything an honest value can satisfy, and the priority runs the
        # other way round: this rule is an affordance — telling an author at declaration what they would
        # otherwise learn on the first call — and an affordance is worth less than the freedom to write working
        # code. Where an honest value satisfies a declaration, the rule stands down however unsatisfiable the
        # projection looks (see the union branch at `_every_branch_is_bounded?`, where `false` is an ordinary
        # value and the rule gives up three correct refusals to keep it). Measured, and this is the check that
        # matters rather than the argument: across 3072 cells of the guard's product — every type, floor,
        # ceiling and set, unions and gated entries included — against a spread holding sizes 0..6 of every
        # container, there are ZERO refusals an honest value satisfies.
        #
        # What honouring the lying value would cost, for the record: 22 of the product's 76 refusals, both
        # spellings the rule exists for among them (`absence:` on a typed field, `length: { maximum: 0 }`),
        # since every size a declaration bounds can be answered by a value that measures itself. And the
        # declaration would then EMIT `{type: "array", enum: [[]], minItems: 3}`, a node no document satisfies,
        # which AGENTS.md refuses outright. Both are reasons the choice is comfortable; neither is the reason
        # it is made.
        #
        # The same assumption carries the blank axis (a subclass answering `blank?` for itself) and the
        # `minItems: 1` reflection emits for a bare `presence:`. It is the layer's, not this rule's.
        # `spec/axn/core/validations/unsatisfiable_size_interval_spec.rb` pins it as a stated limit, with the
        # runtime control that shows the candidate really does pass.
        def _member_size_admissible?(member, klasses, minimum, maximum, validations)
          return false unless klasses.any? { |klass| _literal_may_satisfy?(member, klass) }
          return true unless _member_equality_vouched_for?(member)

          _member_size_within_bounds?(member, minimum, maximum) &&
            _member_survives_the_blank_axis?(member, validations)
        end

        # Whether a member the two tests above have cleared clears the size bounds too — the SIZE half on its
        # own, which is also what tells the two refusal messages apart: a member this admits and the blank axis
        # rejects is one the size bounds cannot explain. Kept separate from the equality and type stand-downs
        # rather than folded in, because those two mean "do not judge this member at all" and must not be read
        # as "the size bounds admit it".
        def _member_size_within_bounds?(member, minimum, maximum)
          size = Internal::Reflection::Schema.container_size(member)
          return true if size.nil?

          (minimum.nil? || size >= minimum) && (maximum.nil? || size <= maximum)
        end

        # Whether the member survives the BLANK axis, which the size bounds do not stand in for wherever a type
        # has blank values that are not its empty ones. For `Array`/`Hash` they coincide and this adds nothing.
        # For a `String` they do not, and the gap is a real one in both directions:
        #
        #   * `type: String, inclusion: { in: [" "] }` — the inferred `presence:` rejects the sole member for
        #     being blank, while its length of 1 clears the floor that same check supplies. Nothing satisfies
        #     the declaration, and it emitted `{type: "string", enum: [" "], minLength: 1}` — a node
        #     `json_schemer` accepts `" "` against while the runtime rejects every input, so the schema told a
        #     client to send the one value guaranteed to fail.
        #   * `type: String, presence: false, absence: true, inclusion: { in: ["ab"] }` — the mirror. A live
        #     `absence:` rejects every value that is not blank, so a non-blank member cannot be the witness
        #     either.
        #
        # Bounded on purpose, and this is the line that keeps it from becoming the witness treadhole the union
        # branch already fell into: a member must satisfy the checks THIS GUARD DERIVED ITS BOUNDS FROM — the
        # blank axis and the size axis — and nothing else. A `format:` or `numericality:` beside them can also
        # sink a member, and asking about those would be deciding a value against every validator in the
        # declaration, which is a satisfiability solver rather than a guard. Those stay under-restrictions,
        # the recoverable direction.
        #
        # Both reads are the emitter's own, so what is refused here cannot disagree with the bound that was
        # emitted: `presence_rejects_blank?` for the floor, and `absence_bounds_blankness?` for the ceiling.
        def _member_survives_the_blank_axis?(member, validations)
          # Judged only where the member answers the blank axis with RUBY'S code, on the same terms
          # `container_size` applies to its measurement: a member whose `present?` or `blank?` is its own
          # decides for itself whether an `absence:` accepts it, and standing down leaves the declaration
          # legal — the direction this guard must err in.
          return true unless Internal::Reflection::Schema.blankness_natively_answered?(member)

          blank = Internal::Reflection::Schema.presence_blank?(member)

          return false if blank && Internal::Reflection::Schema.presence_rejects_blank?(validations)

          !(!blank && Internal::Reflection::Schema.absence_bounds_blankness?(validations))
        end

        # Whether the set's own `include?` decides membership by asking a MEMBER — which is what makes vouching
        # for that member's `==` (below) vouch for the whole operation.
        #
        # Two things must hold, and the second is not implied by the first.
        #
        # The container must be an Array. `Array#include?` dispatches `member == candidate`, so the member is
        # the whole operation and it is one axn holds. A `Hash`- or `Set`-backed set is looked up by
        # `hash`/`eql?`, and there the CANDIDATE supplies half the comparison — an object axn will never see at
        # declaration, and one whose `hash` may collide with a member of a quite different size.
        #
        # And the `include?` that will RUN must be Array's own, asked by ownership exactly as a member's `==`
        # is. An exact-class Array can still carry a singleton `include?`, and that spelling reaches a declared
        # contract by a supported route: `ShapeGraph.detached_option_array` stores a FROZEN container as the
        # caller's object rather than copying it, precisely because nothing can mutate it afterwards — so the
        # override survives, and `Clusivity` dispatches it. (An unfrozen one never gets this far; that seam
        # refuses a container defining methods of its own, since `dup` would drop the singleton class and the
        # copy would answer differently from what was declared.)
        #
        # Read through the shared collection reader, so a bare `inclusion: [..]` and the long
        # `inclusion: { in: [..] }` are judged as the one thing they are.
        def _membership_is_the_members_own_equality?(entry)
          collection = Axn::Validation::Base.declared_set_collection(entry)
          return false unless collection.instance_of?(::Array)

          ::Array.equal?(Internal::NativeMethods.method_owner(collection, :include?))
        end

        # Whether the `==` this member will actually be compared with is the one the closed equality world
        # vouches for. Two questions, and both are needed:
        #
        #   * is the member's class in that world at all — asked by EXACT class, never by descent, for the
        #     reasons `JUDGEABLE_EQUALITY_CLASSES` gives;
        #   * does that class OWN the `==` that would run. A singleton method is invisible to the first
        #     question — `member = []; def member.==(other) = other == [1]` is an exact `Array` whose equality
        #     is nobody's but its own — so the effective owner is read the same way the size predicates read
        #     theirs, through `NativeMethods.method_owner`.
        #
        # The owner is compared by identity, so nothing the member defines decides the question.
        def _member_equality_vouched_for?(member)
          klass = Internal::Identity.class_of(member)
          return false unless _judgeable_equality?(klass)

          klass.equal?(Internal::NativeMethods.method_owner(member, :==))
        end

        def _raise_size_closed_inclusion_set!(where, minimum, maximum)
          bounds = [("at least #{minimum}" if minimum), ("at most #{maximum}" if maximum)].compact.join(" and ")
          raise ArgumentError,
                "inclusion: on #{where} can never match — every value in its set is outside the sizes this " \
                "declaration admits (#{bounds}), so every value is rejected and the emitted `enum` names " \
                "nothing the emitted size bounds allow. Widen the size bounds (`allow_empty: true` drops the " \
                "floor a typed field carries by default), or drop the members the bounds exclude."
        end

        # Classes whose instances compare and equate ACROSS the family, so a literal of one can satisfy a
        # declaration naming another: every Numeric with every other (`1 == 1.0`, `3 > 1.5`,
        # `[1.0].include?(1)`), and the date/time trio, which Rails code mixes routinely. UNRELATED classes do
        # not (`["1"].include?(1)` is false), which is what keeps judging them safe.
        #
        # Deliberately not narrowed further: `type: Date, comparison: { greater_than: Time.now }` raises on
        # every call outside Rails (bare `Date`/`Time` do not compare) but is legal once ActiveSupport's
        # Date/Time extensions are loaded, and a `Complex` bound stands down here too. A declaration's
        # legality must not depend on what happens to be loaded, so both stay admitted — the under-restricting
        # direction, which this guard must prefer over refusing a declaration that can genuinely work.
        CROSS_COMPARABLE_FAMILIES = [[::Numeric], [::Date, ::Time, ::DateTime]].freeze

        # The classes whose equality axn actually understands, and the ONLY pairs it will judge. Ruby's core
        # value types compare by content within a type and refuse across unrelated ones (`["1"].include?(1)` is
        # false), which is exactly what makes a verdict about them safe.
        #
        # This list is deliberately a CLOSED world rather than a list of exceptions to widen. The guard was
        # first written the other way round — enumerate the classes whose `==` compares contents, judge
        # everything else — and that enumeration was wrong four times over, each time by refusing a legal
        # declaration: a `Comparable` value object whose `<=>` takes a Numeric, sibling subclasses of one
        # container root, a literal carrying its own cross-class `==`, and a `Regexp`/`Range` subclass
        # (`SubRegexp.new("a") == /a/` is true — measured). Equality is not inferable from ancestry, so an open
        # world cannot be completed; naming what IS known and standing down on everything else can be, and it
        # errs by admitting a broken declaration rather than by refusing a working one.
        #
        # `BigDecimal` is admitted on the same evidence as `Rational`, not on the strength of its `nan?`
        # self-report: it is a stdlib Numeric value type whose `==` compares content and is owned by the class
        # (measured — `BigDecimal#==` and `BigDecimal#<=>` are BigDecimal's own, `!=` is BasicObject's, which
        # its ancestry carries), it crosses exactly the Numeric family this guard already crosses
        # (`BigDecimal("1") == 1`), and it takes no subclass in the stdlib. Named UNCONDITIONALLY, unlike `Set`:
        # `axn.rb` requires bigdecimal itself, so a load order that left it out would raise there rather than
        # quietly drop it from this frozen list and stop the refusals it earns from firing.
        JUDGEABLE_EQUALITY_CLASSES = [
          ::String, ::Symbol, ::Integer, ::Float, ::Rational, ::BigDecimal, ::NilClass, ::TrueClass,
          ::FalseClass, ::Array, ::Hash, ::Date, ::Time, ::DateTime, (defined?(Set) ? ::Set : nil)
        ].compact.freeze

        # Whether ONE literal could satisfy a constraint on a value of ONE declared klass. The runtime's own
        # matcher answers first, so the guard cannot disagree with the type check about the same pair.
        #
        # Everything past that is a stand-down. A pair outside the closed world above is not judged at all,
        # because its `==` belongs to the classes involved. Within it, one further chance: a literal in the same
        # cross-comparable family as the declared type really does compare across classes, which is what keeps
        # `type: Float, inclusion: { in: [0, 1] }` declaring.
        #
        # `klass` is always a real Module — `_judgeable_type_klasses` stands the whole guard down unless every
        # declared token is one — so nothing here asks a caller-supplied token what it is. The LITERAL's class is
        # read through `Internal::Identity`, and membership is compared by identity, so neither side's own
        # methods decide a declaration.
        def _literal_may_satisfy?(literal, klass, cross_family: true)
          return true if Validators::TypeValidator.value_matches?(literal, klass:)
          return true unless _judgeable_equality?(Internal::Identity.class_of(literal)) && _judgeable_equality?(klass)
          return false unless cross_family

          CROSS_COMPARABLE_FAMILIES.any? do |family|
            family.any? { |root| Internal::NativeMethods.includes_module?(klass, root) } &&
              family.any? { |root| Internal::Identity.kind?(literal, root) }
          end
        end

        # Exact-class membership, never descent: a SUBCLASS of a core value type may override `==` (or inherit
        # one that crosses the subclass boundary, as an Array subclass does), and either way its equality is no
        # longer the one this list vouches for. Compared with `equal?` so nothing the class defines decides it.
        def _judgeable_equality?(klass) = JUDGEABLE_EQUALITY_CLASSES.any? { |known| known.equal?(klass) }

        # The literals one value-comparing entry will be judged against, or nil for an entry that cannot be
        # judged at declaration. Each validator names them differently, and each has its own unjudgeable shapes:
        #
        # `comparison:` names one bound per key, and ActiveModel RESOLVES a Symbol or Proc bound against the
        # record at validation time (`ResolveValue`) — measured: `comparison: { equal_to: :allowed }` passes when
        # that method returns the value — so a declaration carrying one is unjudgeable and stands down. Bounds are
        # read by `key?` rather than truthiness, since `equal_to: false` is a real bound.
        #
        # `acceptance:` names a set under `accept:`, defaulting to ActiveModel's own when absent. A bare scalar
        # (`accept: "yes"`) is not a literal set the shared reader will read, so it stands down. Only that
        # reader's admissibility TEST is shared; its member-reading rule is not, because
        # `AcceptanceValidator` tests `Array(accept).include?(value)`, and `Array()`
        # on a Hash yields its `[key, value]` PAIRS rather than its keys — measured, `accept: { "a" => 1 }`
        # accepts `["a", 1]` and rejects `"a"` — so `literal_set_members`'s "a Hash's members are its keys"
        # rule (right for `inclusion:`, whose `include?` tests keys) is wrong for this validator.
        #
        # `inclusion:` delegates to the set reader, which also judges a Range's bounds at a container position.
        # Whether ONE entry's literals leave any value of the declared type able to satisfy it. The quantifier
        # differs by validator and the difference is the whole point: `inclusion:`/`acceptance:` name a SET, and a
        # value satisfies the check by matching ONE member, so the entry is satisfiable when any member could
        # match. `comparison:` names one bound per operator and ActiveModel applies every one of them, so the
        # value must satisfy them ALL — an entry is unsatisfiable the moment a single bound is
        # (`comparison: { equal_to: ["a"], greater_than: 1 }` on a `type: Array` field admits nothing, though its
        # equality literal is an Array).
        #
        # The nesting of the two quantifiers matters as much as which one each takes, because a union declares
        # several branches and a single runtime value takes exactly ONE of them. For `comparison:`, some ONE
        # branch must satisfy EVERY bound: `type: [Array, Hash], comparison: { equal_to: [], greater_than: {} }`
        # has an Array-satisfiable bound and a Hash-satisfiable bound and admits nothing, because no value is
        # both. For a SET, one branch and one member is all a value needs, so either order reads the same.
        def _constraint_satisfiable?(key, literals, klasses, cross_family: true)
          if key == :comparison
            return klasses.any? do |klass|
              literals.all? { |literal| _literal_may_satisfy?(literal, klass, cross_family:) }
            end
          end

          _any_literal_may_satisfy?(literals, klasses, cross_family:)
        end

        # The SET quantifier on its own, because both guards ask for it and neither owns it: one literal
        # matching one declared branch is all a set-membership check needs to be reachable. The satisfiability
        # guard reads it as "some value can pass"; the vacuity guard negates it, reading "no value can fail".
        # An empty literal list answers false either way — nothing to match — which is what makes
        # `inclusion: { in: [] }` unsatisfiable and `exclusion: { in: [] }` vacuous by the same line.
        def _any_literal_may_satisfy?(literals, klasses, cross_family: true)
          literals.any? { |literal| klasses.any? { |klass| _literal_may_satisfy?(literal, klass, cross_family:) } }
        end

        # Whether a literal of a DIFFERENT class in the same cross-comparable family can match this entry —
        # true for everything except a set whose `include?` is keyed by hash identity.
        #
        # `Clusivity` calls the collection's own `include?`, so the COLLECTION decides which equality applies.
        # An Array compares with `==`, under which the families really do cross (`[1].include?(1.0)` is true).
        # A `Set` and a `Hash` (whose members are its keys) look the member up by `hash` + `eql?`, and `eql?`
        # never crosses a family — measured: `Set[1].include?(1.0)` and `{1 => true}.include?(1.0)` are both
        # false while `1 == 1.0` is true. Widening there predicts a match ActiveModel will not make, in both
        # directions: `type: Float, inclusion: { in: Set[1] }` rejects every Float, and its `exclusion:` mirror
        # forbids none. Everything else — `acceptance:` (read through `Array()`), a `comparison:` bound, a
        # Range's bounds (`cover?`, decided by `<=>`) — compares by operator, so the families cross as before.
        #
        # Exact-class through `Internal::Identity`, so neither the collection nor its members decide it.
        def _cross_family_admissible?(key, entry)
          return true unless CLUSIVITY_KEYS.include?(key)

          collection = Axn::Validation::Base.declared_set_collection(entry)
          klass = Internal::Identity.class_of(collection)
          !(klass.equal?(::Hash) || (defined?(Set) && klass.equal?(::Set)))
        end

        def _judgeable_constraint_literals(key, entry, option_keys, klasses)
          return _judgeable_set_members(entry, klasses) if key == :inclusion

          opts = Axn::Validation::Base.validator_entry_options(entry)
          if key == :acceptance
            return DEFAULT_ACCEPTANCE_SET unless Internal::ShapeGraph.carries_key?(opts, :accept)

            # Judge only the shapes `Array()` leaves alone (an Array or a Set); a Hash or a bare scalar stands
            # the guard down rather than being read through the wrong rule. Which shapes those are is the set
            # reader's own question, asked through its definition rather than respelled here.
            accept = opts[:accept]
            return nil unless Axn::Validation::Base.literal_set_collection?(accept)

            return accept
          end

          # A `<=>`-decided comparison bound is judgeable only at a CONTAINER position, exactly as a Range set
          # is, and for the same reason: outside a container those operators' semantics belong to the declared
          # class. A `Comparable` value object routinely accepts another class — a `Money` whose `<=>` takes a
          # Numeric satisfies `type: Money, comparison: { greater_than: 0 }` (measured: `Money.new(1) > 0` is
          # true) — and no ancestry test can predict that. An Array/Hash/Set compares with its own kind and
          # nothing else, so there the bound's type settles it.
          #
          # `equal_to:` is exempt from that gate, judged at EVERY type exactly as its inverted twin
          # `other_than:` already is (`_vacuous_constraint_literals`). Both are decided by `==` rather than
          # `<=>`, and equality has no hole the gate is covering: swept across every pair in the closed world,
          # `==` never crosses outside `CROSS_COMPARABLE_FAMILIES`, while `<=>` does — `Date > 0` is TRUE, since
          # Ruby reads a Numeric bound as an Astronomical Julian Day Number, and `Date == 0` is false. So the
          # gate is load-bearing for the four and would only cost coverage on the two: `type: String,
          # comparison: { equal_to: 1 }` rejects every String, as surely as its `other_than:` mirror forbids
          # none.
          judgeable = _all_container_tokens?(klasses) ? option_keys : (option_keys & EQUALITY_COMPARISON_KEYS)

          bounds = _static_bounds(opts, judgeable)
          bounds.empty? ? nil : bounds
        end

        # The bounds of a `comparison:` entry this guard can actually read — every one ActiveModel resolves
        # against the record per call (`ResolveValue`) dropped, rather than standing the whole entry down
        # because of it. Empty when nothing static remains, which stands the caller down as before.
        #
        # Sound only because `ComparisonValidator` applies EVERY operator the entry names: a value must satisfy
        # all of them, so a static bound nothing can satisfy sinks the entry whatever a Symbol or Proc sibling
        # later resolves to, and judging a SUBSET of a conjunction can only under-restrict. Standing down on the
        # pair instead let `comparison: { equal_to: Float::NAN, greater_than: -> { 0 } }` declare while rejecting
        # every value, and `type: Array, comparison: { equal_to: 1, greater_than: :floor }` likewise.
        #
        # Deliberately NOT used by the vacuity reader, whose quantifier is the other way round: there a bound
        # decides when the check FAILS, so dropping one would be claiming "nothing can fail" from a subset of the
        # ways to fail. Its single inverted operator makes the two equivalent today, and encoding the unsound
        # generalization anyway is how that stops being true quietly.
        def _static_bounds(opts, option_keys)
          option_keys.select { |option| opts.key?(option) }
                     .map { |option| opts[option] }
                     .reject { |bound| _dynamic_bound?(bound) }
        end

        # The declared types no instance of which is `blank?`, so a `comparison:` entry on one is reached by
        # every admitted value and its bound really is the only thing it can reject. Measured against
        # ActiveSupport rather than reasoned from: a Numeric is never blank (`0.blank?` is false), and neither
        # is a Date/Time. Everything else can be — `[]`, `{}`, `Set[]`, `""`, `:""`, `nil`, `false` — and a
        # class outside this list is assumed blankable, since a value object answering `empty?` is blank to
        # ActiveSupport and nothing here can tell without asking it.
        NEVER_BLANK_KLASSES = [
          ::Integer, ::Float, ::Rational, ::BigDecimal, ::TrueClass, ::Date, ::Time, ::DateTime
        ].freeze

        # Whether a bound is one ActiveModel RESOLVES against the record per call (`ResolveValue`) rather than
        # comparing directly — a Symbol or a Proc — so a declaration carrying one cannot be judged here.
        #
        # Classified through `Internal::Identity`, never `bound.is_a?`: the bound is caller-supplied, so its
        # own answer should not decide which branch a guard takes. This does NOT make a hostile bound safe,
        # and the reachability is worth stating rather than implying — `_literal_may_satisfy?` calls
        # `TypeValidator.value_matches?` a step later, which asks `is_a?` because the guard must not disagree
        # with the check it predicts, and the type check asks it again on every call. A bound whose `is_a?`
        # raises raises either way. THE single definition, shared by both literal readers so neither can
        # classify a bound the other would not.
        def _dynamic_bound?(bound)
          return true if Internal::Identity.kind?(bound, ::Symbol) || Internal::Identity.kind?(bound, ::Proc)

          # `ResolveValue` falls through to `value.respond_to?(:call)` and calls ANY other callable
          # (activemodel 7.2.2.2, resolve_value.rb:17), so a bound is dynamic on its ability to be called, not
          # on being one of the two obvious classes — a String carrying a singleton `call` is resolved exactly
          # as a Proc is, and judging it by its own class refused a declaration that works.
          #
          # BOTH channels are asked, and the union is deliberate: the method table misses a `call` reached
          # through `respond_to_missing?`/`method_missing` (measured — a String proxy answering `respond_to?
          # (:call)` is resolved by ActiveModel while its method table shows nothing), and `respond_to?` is the
          # question ActiveModel actually asks, so the guard must not disagree with the check it predicts.
          # Either saying "callable" stands the bound down, which is the only direction that cannot refuse a
          # working declaration — a missed callable is judged as a literal, and that is what refuses one.
          return true unless Internal::NativeMethods.method_owner(bound, :call).nil?

          bound.respond_to?(:call)
        end

        # The declared types this guard can judge membership against: every token a real Class or Module. Empty
        # for an undeclared type and for a declaration naming any pseudo-type (`:boolean`/`:uuid`/`:params`),
        # whose admissible values are not a class membership question — both stand the guard down.
        #
        # Empty for a SELF-GATED `type:` entry too. All three callers read the declared type to rule values OUT
        # — a set no value of the type could match, a forbidden set no value of the type could be, a member the
        # size bounds exclude — so a type check that can be skipped while the rest of the declaration runs
        # rules nothing out on those calls. `type: { klass: Array, if: -> { false } }, presence: false,
        # length: { minimum: 3 }, inclusion: { in: ["abc"] }` is satisfied by `"abc"` on every call (measured):
        # the closed gate admits the String, the set contains it, and its length clears the floor. The same
        # reading rescues the vacuity rule's mirror — `exclusion: { in: ["admin"] }` under a gated `type: Array`
        # really does reject the String "admin" it now admits.
        #
        # `entry_self_gated?`, and this is the one question that reader is right for: it asks whether the entry
        # is skippable INDEPENDENTLY OF ITS SIBLINGS, which is exactly what makes a type check stop ruling
        # values out while the constraint judging them still runs. A gate the whole DECLARATION carries reaches
        # the type check and the constraint alike, so it creates no asymmetry between them and is deliberately
        # not counted here — the three callers answer it in their own opposite ways (the size rules stand down
        # on it; the value-constraint and vacuity rules refuse it outright, "closed the check enforces nothing,
        # open it rejects everything", pinned in `container_position_validators_spec.rb`), and reading the
        # effective gate here would impose one policy on all three. Measured: it did, and broke both pins.
        #
        # Classified with `case`/`when Module`, which does not call the token's own `is_a?`.
        def _judgeable_type_klasses(validations)
          entry = Axn::Validation::Base.validator_entries(validations)[:type]
          return [] unless entry
          return [] if Axn::Validation::Base.entry_self_gated?(entry)

          tokens = _declared_type_tokens_in(entry)
          return [] if tokens.empty?

          tokens.all? { |token| case token when ::Module then true else false end } ? tokens : []
        end

        # The set members whose type membership can be judged, or nil for a set that cannot be judged at all.
        # Usually that is `Base.literal_set_members` — a literal in-memory Array/Set, never an Array subclass or
        # a dynamic source, since judging one would run the caller's own traversal.
        #
        # A RANGE is the one non-literal set that can still be judged, and its BOUNDS are judgeable only at a
        # container position: a Range decides membership with `<=>`, which is nil across unrelated classes, so
        # `(1..5).include?([1, 2])` is false however the array is spelled — while `(["a"]..["z"]).include?(["b"])`
        # would need `<=>` between Arrays, which exists. So the bounds are what decide, not the Range-ness, and
        # they are exactly what the membership test wants. Deliberately not extended past a container position:
        # `(1.0..5.0).cover?(3)` is true, so a Float-bounded Range on `type: Integer` is satisfiable and judging
        # its bounds would falsely refuse it. A beginless-and-endless Range yields no bounds and stands the guard
        # down.
        #
        # An EMPTY Range is a separate question, asked first and at every position, because emptiness is not
        # about the bounds' type at all — see `_empty_range?`.
        def _judgeable_set_members(entry, klasses)
          collection = Axn::Validation::Base.declared_set_collection(entry)
          return Axn::Validation::Base.literal_set_members(entry) unless collection.is_a?(::Range)
          return [] if _empty_range?(collection)
          return nil unless _all_container_tokens?(klasses)

          bounds = [collection.begin, collection.end].compact
          bounds.empty? ? nil : bounds
        end

        # Whether a Range names NO value at all — an exclusive one whose endpoints meet, or one whose bounds run
        # backwards. Answered ahead of the container gate above and independently of it, because this is not a
        # question about the bounds' type: an empty set matches nothing whatever the declared type is, so there
        # is no cross-class comparison for the gate to be protecting against. Reduced to the EMPTY MEMBER LIST
        # rather than judged separately, so the verdict falls out of the line that already reads
        # `inclusion: { in: [] }` as unsatisfiable and `exclusion: { in: [] }` as vacuous.
        #
        # `!range.cover?(range.begin)` is the whole test, and it is the range's OWN matcher rather than a
        # reimplementation of it: `cover?` is `begin <= value` and `value <(=) end`, so it accepts `begin`
        # exactly when `begin <(=) end` — which is emptiness. Verified against sampling across exclusive,
        # reversed, degenerate and ordinary ranges over Integer, Float and Date bounds; no disagreement.
        #
        # Scoped to the ranges Clusivity decides with `cover?` — a Numeric/Time/Date/DateTime begin
        # (activemodel 7.2.2.2, clusivity.rb:40) — and that scope is measured, not tidiness. An `include?`-backed
        # Range is ITERATED, and Ruby's single-character String shortcut makes the obvious reading wrong:
        # `("b".."a").include?("a")` is TRUE while `("b".."a").cover?("a")` is false and `to_a` is empty, so a
        # reversed inclusive String range really does reject a value and refusing it would refuse a contract
        # that enforces. The remaining `include?` shapes have no `succ` and raise loudly on every call
        # (`(["a"]...["a"])` → `TypeError: can't iterate from Array`), which is an existing stand-down.
        #
        # A one-sided Range is never empty, so a nil bound answers false rather than being compacted away. The
        # exact `Range` class is required and both bounds must be ones the closed world vouches for with
        # class-owned `<=>`, for the reason `_non_reflexive_literal?` requires the same: this runs an operator on
        # caller-supplied values, and a subclass or a singleton override would otherwise pick the verdict.
        def _empty_range?(range)
          return false unless Internal::Identity.class_of(range).equal?(::Range)
          # The exact class is not enough: a Range instance can carry SINGLETON methods, and the probe below would
          # then generalize one object's answers into a verdict about the declaration. Reachable — a Range literal
          # is frozen, but `Range.new(1, 1, true).dup` and `.clone(freeze: false)` are not, and both take a
          # singleton method. EVERY read the probe makes is covered, not just the comparison: a singleton `begin`
          # returning a value outside the range makes `cover?(begin)` false while the native `cover?` still admits
          # the real members (measured on `(1..2).dup`). Asked by ownership exactly as the bounds' `<=>` is, so
          # nothing the object defines decides this.
          return false unless _class_owned_operators?(range, ::Range, %i[cover? begin end])

          first = range.begin
          last = range.end
          return false if nil.equal?(first) || nil.equal?(last)
          return false unless _cover_comparable_bound?(first) && _cover_comparable_bound?(last)

          !range.cover?(first)
        end

        # Whether ONE Range bound is one whose ordering this guard will judge: a class Clusivity dispatches
        # `cover?` for, in the closed world, carrying its own `<=>`.
        def _cover_comparable_bound?(bound)
          klass = Internal::Identity.class_of(bound)
          return false unless COVER_COMPARABLE_BOUND_CLASSES.any? { |known| known.equal?(klass) }

          _class_owned_operators?(bound, klass, %i[<=>])
        end

        # The bound classes the emptiness test above will judge: the intersection of what Clusivity decides with
        # `cover?` (`Numeric`, `Time`, `DateTime`, `Date`) and what `JUDGEABLE_EQUALITY_CLASSES` vouches for.
        # Exact-class membership, never descent, for the reason that list is.
        COVER_COMPARABLE_BOUND_CLASSES = [
          ::Integer, ::Float, ::Rational, ::BigDecimal, ::Date, ::Time, ::DateTime
        ].freeze

        # Whether every token names a container whose cross-class comparison is reliably false. THE single
        # definition, shared by the to_s-targeted refusal and the Range judgment.
        def _all_container_tokens?(tokens) = tokens.all? { |token| CONTAINER_TYPE_TOKENS.any? { |container| container.equal?(token) } }

        # Whether every type this declaration names is a container whose `to_s` is an inspect form. Answers
        # false for an undeclared type, a union carrying one non-container, and a pseudo-type token — each a
        # declaration the guard above must stand down on, since a value it can constrain is still possible.
        #
        # The `type:` bag's `klass:` is read where a bag was declared, so axn's own canonicalized
        # `type: { klass: Array }` is judged as the `Array` it is. Compared with `equal?` and classified through
        # `hash_or_nil`, because a guard that dispatches `==`/`is_a?` on a caller's class is one the caller can
        # switch off.
        def _declares_container_type_only?(declared)
          tokens = _declared_type_tokens_in(declared)
          return false if tokens.empty?

          _all_container_tokens?(tokens)
        end

        # The type tokens a FIELD declaration names, reading a `type:` bag's `klass:` where a bag was declared
        # and the bare spelling otherwise. Deliberately NOT the same answer as `_declared_type_tokens`, which
        # this wraps: that one exists to read an AXIS or `of:` position, where a bare Hash written in place of a
        # type is searched as a list of two-element Arrays, so it must answer `[declared]` rather than unwrap
        # it. A field's `type:` has no such axis — a bag there is always axn's own — so this unwraps it via
        # `bag[:klass]` first and only falls through to the wrapped reader for the union/bare-token case. Two
        # different questions, both legitimate; a caller that wants the axis answer keeps using
        # `_declared_type_tokens` directly.
        #
        # Reads `bag[:klass]` on the assumption that any Hash-valued entry here is already axn's own plain Hash
        # — true because this runs downstream of `ShapeGraph.detach_option_containers!` (`:1651`), which is
        # what makes that read safe rather than a dispatch onto a caller-supplied object. Classified through
        # `hash_or_nil`, never by dispatching to the value: the bag is the caller's, and a Hash subclass denying
        # its own class would otherwise pick how it is read.
        def _declared_type_tokens_in(declared)
          bag = Internal::ShapeGraph.hash_or_nil(declared)

          _declared_type_tokens(nil.equal?(bag) ? declared : bag[:klass])
        end

        # ActiveModel's `strict:` asks `errors.add` to RAISE instead of recording the error — and axn already
        # settles a contract violation by raising, into the same handling: `Validation::Fields` collects the
        # errors, the executor composes them into one `Axn::InboundValidationError` (or a user-facing failure),
        # and the exception chain turns that into a failed result. A strict raise arrives at that chain having
        # skipped the composition, so it can only take things away, never add the caller-facing raise ActiveModel
        # documents:
        #
        # * a `user_facing:` violation loses its message — strict raises before the settlement that would have
        #   reclassified it, so the caller sees the generic "Something went wrong" instead of the field's own text
        # * co-occurring violations are lost — `errors.add` raises on the first one, so a report that named every
        #   defect in the contract names one
        # * a `strict:` naming a class outside StandardError escapes the call entirely, which no axn call does
        #
        # And it does none of that consistently: ActiveModel's own validators read the option out of the options
        # hash they are handed, while axn's (`type:`, `of:`, `shape:`, `model:`, `validate:`) add their errors
        # without forwarding it — so the same spelling raises beside `presence:` and is dropped beside `type:`.
        # Refused rather than forwarded to the remaining five, since making it uniform would spread the losses
        # above rather than fix them.
        #
        # Refused at EVERY position a validator's options are written — a field, a subfield, an ambient subfield,
        # an exposure, a shape member, and an `of:` bag at any depth — through the two seams that reach them:
        # this scan for a declaration's own key and its validator entries, `_reject_inner_contract_strict!` for a
        # bag. Every offender is named at once: an author who wrote two of them has one declaration to fix.
        def _reject_strict_validation!(validations, where:)
          offenders = []
          offenders << "the declaration" if Internal::ShapeGraph.carries_key?(validations, :strict)
          Axn::Validation::Base.validator_entries(validations).each do |key, entry|
            offenders << "#{key}:" if Axn::Validation::Base.entry_declares_strict?(entry)
          end
          return if offenders.empty?

          _raise_strict_validation!(offenders.join(" / "), where)
        end

        # The one sentence, shared by the entry scan above and by the bag check that reaches the positions it
        # cannot see (`_reject_inner_contract_strict!`) — the same split, and for the same reason, as the
        # context-scope pair below. `inside` is where the `strict:` was written, so the message names the thing
        # the author has to edit.
        def _raise_strict_validation!(inside, where)
          raise ArgumentError,
                "`strict:` inside #{inside} on #{where} is ActiveModel's strict-raising mode, and axn does not " \
                "have one: a contract violation already raises, and the strict exception lands in the same " \
                "handling with LESS to say — it pre-empts the settlement, so a `user_facing:` message degrades " \
                "to the generic one, co-occurring violations are dropped, and a class outside StandardError " \
                "escapes the call. Drop `strict:`; a failed validation already stops the action. To shape what " \
                "the failure says, use `message:` on the check, `user_facing:` on the field, or `fails_on`."
        end

        # The one sentence, shared by the entry scan above and by the bag check that reaches the positions it
        # cannot see (`_reject_inner_contract_context_scope!`). `inside` is what the `on:` was written in — a
        # validator key, or a bag — so the message names the thing the author has to edit rather than a
        # construct their declaration does not carry.
        def _raise_validator_context_scope!(inside, where, runs)
          raise ArgumentError,
                "`on:` inside #{inside} on #{where} names an ActiveModel validation context, and " \
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
          path_allowance: nil,
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
          # The line above canonicalized the field's `of:` one rung deep; the rest of the chain is descended
          # here, under the depth bound, the cycle guard and the path allowance the walk owns. Immediately
          # after it, because every check below reads a bag that has to be final by then — and ahead of
          # `_derive_raw_shape_container!` for the reason that comment gives, that a derivation must land on
          # nodes which are axn's own.
          _walk_declared_inner_contracts!(validations, fields, path_allowance || _new_path_allowance(fields))

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
          #
          # First of the group, because it is the broadest of the six judgments: the other five ask what a
          # validator can MEAN at this position, while this one asks whether the key names a validator at all —
          # and the answer is no wherever it is written. It reads only this hash's own keys (kwargs, so Symbols
          # by construction) and nothing nested, so unlike its neighbours it has no dependency on the
          # canonicalization above.
          _reject_unsupported_validator_keys!(validations, where: _declared_fields_label(fields))
          _reject_validator_context_scope!(validations, where: fields.map(&:to_s).inspect)
          _reject_strict_validation!(validations, where: fields.map(&:to_s).inspect)

          # Beside the context-scope refusal: both refuse a validator that cannot do what the declaration says,
          # ahead of every consumer of this bag. Placement ahead of the tolerance push-down is not load-bearing
          # for THIS message — it carries only key names and the field label, both push-down-invariant — but it
          # is for the satisfiability guard Task 3 adds here next, whose message quotes the declared set.
          _reject_container_position_validators!(validations, where: _declared_fields_label(fields))

          # The tolerance PAIR, not a collapsed boolean: the guard resolves it per entry the way `validates` does,
          # so an entry overriding one of these keeps its own value. Passed explicitly because these are
          # declaration KWARGS at this point — the push-down that writes them into each entry has not run yet.
          # `allow_empty:` rides along for the same reason: the guard asks whether a blank value passes, and this
          # runs ahead of `_reconcile_emptiness_axis!`, so the flag has not yet become the check it installs.
          _reject_unsatisfiable_value_constraints!(validations, where: _declared_fields_label(fields),
                                                                tolerance: { allow_nil:, allow_blank: },
                                                                allow_empty:)

          # Its mirror, taking the same tolerance pair and reading it the other way: not as a stand-down (a
          # tolerated value PASSES, which cannot rescue a check nothing fails) but to discount the forbidden
          # literals ActiveModel would skip. Second, so a declaration broken both ways is reported as the
          # unsatisfiable contract — the defect that rejects every call, ahead of the one that rejects none.
          _reject_vacuous_value_constraints!(validations, where: _declared_fields_label(fields),
                                                          tolerance: { allow_nil:, allow_blank: })

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
            # `allow_nil:`/`except_on:`) ride the hash as sibling keys of the validators but are NOT
            # validators. Sliced out (through AM's own canonical list, so the set cannot drift) and
            # restored verbatim, because normalizing one as a scalar would corrupt it — `if: :flag` would
            # become `if: { with: :flag }`, a Hash the callback machinery cannot resolve, so the gate would
            # stop deciding anything. Core-Ruby delete rather than ActiveSupport's `Hash#except!`: axn runs
            # outside Rails, where that core_ext may never be loaded.
            shared_option_keys = Axn::Validation::Base.shared_validation_option_keys
            shared_options = validations.slice(*shared_option_keys)
            shared_option_keys.each { |key| validations.delete(key) }

            # `confirmation:` is the one validator a tolerance must not reach, and it is held out by
            # OVERRIDING the declaration tier rather than by being skipped: the pair is stated on the
            # declaration below, so `validates` applies it to every entry, and an entry's own value wins per
            # key (AM merges `defaults.merge(entry)`). Every other validator judges the field's own value, so
            # a tolerance stands it down — there is nothing to check when the value the author called optional
            # is absent. `confirmation:`'s subject is the RELATIONSHIP between the field and its companion,
            # and a supplied companion is compared against the base whatever the base holds: `password: ""`
            # beside `password_confirmation: "x"` is a mismatch the caller must see, not a blank to wave
            # through. A snapshot of the keys, since the loop reassigns entries as it goes.
            validations.keys.each do |key|
              v = validations[key]
              next unless v
              next unless _tolerance_exempt_validator?(key)

              validations[key] = Axn::Validation::Base.normalize_validator_options(v)
                                                      .merge(allow_blank: false, allow_nil: false)
            end

            validations.merge!(shared_options)
            # The declaration's own tier, stated once. An author who wrote the key directly among the
            # validations is authoritative — that spelling arrived in `shared_options` above — so it is not
            # overwritten here.
            validations[:allow_blank] = allow_blank unless shared_options.key?(:allow_blank)
            validations[:allow_nil] = allow_nil unless shared_options.key?(:allow_nil)
          else
            _apply_default_presence!(validations, allow_empty:, tolerant:)
          end

          # Asked once the validations hash is final (both tolerance branches above have run), since the
          # answer depends on what they left behind.
          _apply_nil_skip_to_non_type_validators!(validations)

          # LAST, so it judges exactly the bag each config will carry — the same bag the emitter reads its size
          # bounds out of. Every earlier guard here reads the author's own spelling; this one reads the settled
          # contract, because the floor it weighs is one axn itself installs (`_apply_default_presence!`).
          _reject_unsatisfiable_size_interval!(validations, where: _declared_fields_label(fields))

          fields.map { |field| [field, validations] }
        end

        # A field whose `type:` rejects nil has already reported that nil completely; running the other
        # validators against it only adds derivative messages (a custom `validate:` written for a real value
        # raises, and its crash is surfaced as a second failure on the same field). Give every non-type
        # validator nil-tolerance so the type error stands alone. Only the type validator's own nil verdict
        # is authoritative, so it is left untouched, as are validators that already carry explicit tolerance.
        #
        # `:of` is exempt for a different reason than `:type` is: the flag this method writes suppresses a
        # DERIVATIVE message on a nil field, and `:of` has no nil verdict to suppress in the first place —
        # `OfValidator`'s `validate_elements`/`validate_entries` both `return unless value.is_a?(...)`, so the
        # bag no-ops structurally on a nil field whether or not it carries `allow_nil:`. Writing the flag into
        # it anyway would change nothing about a nil field while leaving axn's own write sitting in the bag —
        # indistinguishable from tolerance an author declared inside `of:` on purpose.
        # Mutates `validations`.
        def _apply_nil_skip_to_non_type_validators!(validations)
          return unless _type_rejects_nil?(validations)

          shared_option_keys = Axn::Validation::Base.shared_validation_option_keys

          # Iterate a snapshot of the keys: the loop reassigns entries as it goes, and Ruby forbids
          # mutating a Hash mid-iteration.
          validations.keys.each do |key|
            opt = validations[key]
            next if key == :type || key == :of || !opt || shared_option_keys.include?(key)

            normalized = Axn::Validation::Base.normalize_validator_options(opt)
            next if normalized.key?(:allow_nil) || normalized.key?(:allow_blank)

            # Every entry that reaches here records an error rather than raising: `strict:` — the one
            # option under which relaxing an entry would swallow a raise instead of dropping a duplicate
            # message, since EachValidator's allow_nil skip runs BEFORE validate_each — is refused at
            # declaration (`_reject_strict_validation!`), at both tiers and at every position.
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
        #   * an if:/unless: gate that desynchronizes the type check from its siblings — one the type entry
        #     carries itself, or a declaration-level one a sibling overrides — so some other validator runs
        #     on a call where the type check does not and its nil rejection is then the only account of the
        #     nil to give (see below for exactly which gates can do that).
        def _type_rejects_nil?(validations)
          raw = validations[:type]
          return false unless raw.is_a?(Hash) && raw[:klass]

          # The options the type check will run under, the declaration's included — a shared tolerance
          # governs it exactly as one inside the bag does.
          type = Axn::Validation::Base.effective_entry_options(raw, _shared_validation_options(validations))
          return false if type[:allow_nil] || type[:allow_blank]

          # Relaxing the siblings is safe exactly when the type check runs on every call any sibling runs
          # on — which the CONDITIONS the type check runs under decide, resolved as ActiveModel merges the
          # two gate tiers (per key: an entry's own value overrides the declaration's, a blank one drops
          # the declaration's for that entry and is then ignored):
          #
          #   * a NON-BLANK gate the type entry carries itself ties the type check to a condition no
          #     sibling shares, so a sibling can run on a call it is closed on. Nothing else need be
          #     asked — the type check stands apart from the whole declaration;
          #   * otherwise the type check runs under the declaration's gates, minus any key the type entry
          #     blanks out. Only a sibling that mentions one of those SURVIVING keys can outlive it: a
          #     sibling naming a key they do not share keeps every shared condition and merely adds one —
          #     a strict narrowing, which can never run where the type check does not — while naming a
          #     shared key REPLACES that condition (with a different one, or with a blank that un-gates the
          #     sibling outright), making the sibling's nil rejection the only account of a nil on some
          #     call and so not one to relax;
          #   * with no surviving key the type check is unconditional — it runs on every call, so every
          #     sibling is covered whatever its own gate. That is the case a blank gate key on the type
          #     entry reaches when the declaration carries no gate for it to drop (AM ignores the blank,
          #     leaving the type check exactly as unconditional as a bare `type:`), and the reason
          #     mentioning a key is not on its own a reason to stand down.
          #
          # Key PRESENCE is the test for the SIBLINGS — a blank same-key value there is not inert, it
          # un-gates that sibling — while the type entry's own gates are asked by effective value, since a
          # blank one gates nothing. Both come from the single definitions in `Axn::Validation::Base`
          # rather than a re-test here.
          return false if Axn::Validation::Base.entry_self_gated?(raw)

          gate_keys = Axn::Validation::Base.entry_effective_gate_keys(raw, _shared_validation_options(validations))
          if gate_keys.any?
            siblings = Axn::Validation::Base.validator_entries(validations).except(:type)
            return false if siblings.any? { |_key, opt| Axn::Validation::Base.entry_mentions_gate_key?(opt, keys: gate_keys) }
          end

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
        # judgment resolves against. Validation::Base holds the one definition, so the tier a guard here resolves
        # against and the tier the emitter resolves against cannot drift.
        def _shared_validation_options(validations)
          Axn::Validation::Base.shared_validation_options(validations)
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
        # The inbound facade every generated reader resolves through. Private, and reached by axn's own
        # machinery only through `Internal::ActionState` (an UnboundMethod resolves and binds a private
        # method fine): nothing dispatches the name, so it costs the user nothing and they are free to
        # declare a field called `internal_context`.
        #
        # Privatized one method at a time rather than with a bare `private`, which would also withdraw the
        # user-facing sugar (`inputs`, `expose`, `set_execution_context`, `execution_context`) below.
        def internal_context = @__internal_context ||= _build_context_facade(:inbound)
        private :internal_context

        def result = @__result ||= _build_context_facade(:outbound)

        # Resolved declared-inbound fields as a Hash (defaults/preprocess applied, model: fields
        # resolved to their record), keyed by wire key. Splat into a nested action to forward
        # inputs: `Child.call(**inputs, override: x)`. Reads through internal_context (not raw
        # provided_data) so a model: field supplied by `<field>_id` forwards the resolved record —
        # the record lives only in the reader. Fields whose resolved value is nil are omitted, so a
        # nested action still applies its own absent/default handling for them.
        def inputs
          context = Axn::Internal::ActionState.internal_context(self)
          self.class._declared_fields(:inbound).each_with_object({}) do |field, hash|
            value = context.public_send(field)
            hash[field] = value unless value.nil?
          end
        end

        # Sugar reaching sugar is the same defect as an internal dispatching one: a user who takes
        # `internal_context` would otherwise redirect these two at their own value.
        def default_error = Axn::Internal::ActionState.internal_context(self).default_error
        def default_success = Axn::Internal::ActionState.internal_context(self).default_success

        # Accepts:
        # - a single Axn::Result: forwards (result.declared_fields & own outbound declared fields)
        # - two positional arguments (key, value)
        # - a hash of key/value pairs
        def expose(*args, **kwargs)
          forwarding_a_result = args.size == 1 && kwargs.empty? && args.first.is_a?(Axn::Result)
          return Axn::Internal::ActionState.expose_from_result(self, args.first) if forwarding_a_result

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

            raise Axn::ContractViolation::UnknownExposure, key unless Axn::Internal::ActionState.result(self).respond_to?(key)

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
          # The hook is USER code, and it runs on the exception-report path — so it is subject to the
          # same "must never itself raise" rule the ambient slice below is guarded for. Unguarded, a
          # raising hook propagated out of here into `Internal::ExceptionContext.build` and aborted
          # `trigger_on_exception` BEFORE `Axn.config.on_exception` was reached, so the real exception
          # was reported nowhere (verified). Guarded through `best_effort` rather than the silent
          # `_safe_execution_context_slice`: this one is the caller's own code, so its failure is worth a
          # warning and an `on_ignored_exception` report of its own rather than degrading unremarked.
          hook_context = if respond_to?(:additional_execution_context, true)
                           Axn::Extensions.best_effort("resolving additional_execution_context", action: self) do
                             additional_execution_context
                           end || {}
                         else
                           {}
                         end
          extra_context = explicit_context.merge(hook_context).except(*RESERVED_EXECUTION_CONTEXT_KEYS)

          ctx = {
            inputs: _safe_execution_context_slice { Axn::Internal::ActionState.inputs_for_logging(self) },
            outputs: _safe_execution_context_slice { Axn::Internal::ActionState.outputs_for_logging(self) },
            **extra_context,
          }

          # Resolving/filtering ambient context can raise (e.g. a failing ambient_context_provider
          # whose error is now memoized and re-raised on every read — see
          # Axn::Core::AmbientContext#ambient_context). Building exception-report context must never
          # itself raise, or the real exception never reaches Axn.config.on_exception, so omit
          # ambient_context here rather than propagate.
          ambient = _safe_execution_context_slice do
            ambient_filter = self.class._has_dynamic_sensitive_fields? ? self.class._build_instance_filter(self) : self.class.inspection_filter
            masked = self.class._mask_unfilterable_shapes(Axn::Internal::ActionState.ambient_context(self),
                                                          self.class._sensitive_ambient_shape_paths(self), self)
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
