# frozen_string_literal: true

module Axn
  module Validation
    # Shared kernel for the one-off ActiveModel validator classes Fields and Subfields build: the
    # custom validator constants and symbol-argument delegation to the action. Subclasses supply the
    # value source (`read_attribute_for_validation`) and how to reach the action
    # (`_action_for_validation`).
    class Base
      include ActiveModel::Validations

      # NOTE: exposing the validators as constants here (rather than registering them globally)
      # scopes them to axn's own one-off validator classes, so they can't affect the consuming
      # apps' validators.
      ModelValidator = Validators::ModelValidator
      TypeValidator = Validators::TypeValidator
      ValidateValidator = Validators::ValidateValidator
      OfValidator = Validators::OfValidator
      ShapeValidator = Validators::ShapeValidator
      NonEmptinessValidator = Validators::NonEmptinessValidator

      # ActiveModel's own two, subclassed for the positional reading (see WholeValueClusivity). Listed here for
      # the same reason the axn-only validators are: `validates` resolves a validator by `const_get` from the
      # class being declared on, so a constant here shadows `ActiveModel::Validations::InclusionValidator` for
      # axn's one-off validator classes — top-level field, subfield, shape member, and every `of:` position
      # (PRO-3193), which `Validation::ContainerContents` inherits from `Fields` and so picks up for free —
      # and for nothing else the consuming app declares.
      InclusionValidator = Validators::InclusionValidator
      ExclusionValidator = Validators::ExclusionValidator

      # Normalize a scalar validator value the way ActiveModel's own `validates` does, so the tolerance
      # push-down (contract.rb `_parse_field_validations`) can layer allow_blank:/allow_nil: onto the
      # SAME options hash `validates` would build — the terse spelling (`numericality: true`,
      # `inclusion: [..]`/`1..5`, `format: /re/`) then combines transparently with a tolerance flag,
      # matching how it behaves WITHOUT one (PRO-2915). Reuses AM's private `_parse_validates_options`
      # rather than copying its case statement, so the mapping cannot drift (activemodel 7.2.2.2:
      # TrueClass→{}, Hash→itself, Range/Array→{in:}, else→{with:}).
      def self.normalize_validator_options(value) = _parse_validates_options(value)

      # ONE validator ENTRY's options as ActiveModel will act on them — the form to read whenever a
      # judgment turns on an entry's CONTENTS. A falsy entry is a disabled validator AM skips, which names
      # nothing at all; every other value is normalized the way `validates` does, so a bare shorthand
      # (`length: 2..5`, `inclusion: %w[a b]`) is read in the form AM expands it to rather than the form the
      # author happened to type.
      #
      # Normalizing at the READ is the point: entries are also normalized in place by the declaration-time
      # passes (the tolerance push-down, the nil-skip), but those run only under their own conditions — a
      # gated or nil-admitting type entry leaves its siblings exactly as written — so a reader that assumed
      # a Hash would silently skip a constraint ActiveModel enforces. Idempotent on a Hash, so asking here
      # costs nothing where a pass already ran.
      def self.validator_entry_options(entry)
        return {} unless entry

        normalize_validator_options(entry)
      end

      # ONE entry's options as `validates` will hand them to the validator: the declaration-wide shared options
      # with the entry's own merged over them, which is literally what AM builds
      # (`defaults.merge(_parse_validates_options(options))`, activemodel 7.2.2.2). Every per-entry judgment reads
      # THIS rather than the entry alone, because a shared `allow_nil:`/`allow_blank:`/`strict:` governs how
      # the entry runs just as an entry's own does — and an entry's own value overrides the shared one per key,
      # which the merge order gives for free.
      #
      # A falsy entry is a disabled validator AM skips outright, so it has no effective options to speak of.
      # The two GATE questions deliberately do not come through here: `entry_effective_gate_keys` resolves the
      # same two tiers with AM's blankness rule applied per key, and `entry_self_gated?` asks about an entry's own
      # gate specifically.
      def self.effective_entry_options(entry, declaration_options)
        return {} unless entry

        declaration_options.merge(normalize_validator_options(entry))
      end

      # ActiveModel's shared "default" validator options — keys that ride alongside validator entries
      # in a `validates` call but are NOT validators themselves (if:/unless:/on:/strict:/allow_blank:/
      # allow_nil:). Exposed so the tolerance push-down (contract.rb) can hold them OUT of the
      # per-validator scalar normalization — merging tolerance into `strict: true`, say, would rewrite
      # it to a Hash and break strict raising. Reuses AM's own canonical list so the set can't drift.
      def self.shared_validation_option_keys = _validates_default_keys

      # The shared options ONE declaration carries — the tier every per-entry judgment resolves against.
      # THE single definition, so the emitter, the declaration guards and the nil-axis judgment all read the
      # same slice of the same bag rather than three copies of it.
      def self.shared_validation_options(validations) = validations.slice(*shared_validation_option_keys)

      # The real VALIDATOR entries in a validations hash — everything that is NOT an ActiveModel shared
      # option (if:/unless:/on:/strict:/allow_blank:/allow_nil:). THE single definition of "is this a
      # validator", shared by the validator-class builder, the gate sweeps, and schema reflection, so
      # "does this field have any validators / do its validators accept nil" is decided one way
      # everywhere. Without it, a shared-only hash like `{ strict: true }` reads as a validator: the
      # builder calls `validates` and ActiveModel raises "You need to supply at least one validation",
      # and reflection marks the (omittable) field required.
      def self.validator_entries(validations) = validations.except(*shared_validation_option_keys)

      # Whether the field's validators, taken together, permit a nil/omitted value. Drives both
      # input optionality and nullability (adding "null" to the emitted type). A lone validator's
      # allow_nil: doesn't count if another (presence, type, …) still rejects nil.
      #
      # An entry is nil-tolerant if it's a disabled validator (falsy `opt` — `false` or `nil`, both of
      # which ActiveModel skips), `absence` (nil is always "absent"), `acceptance` unless explicitly
      # `allow_nil: false` (ActiveModel's acceptance is allow_nil by default), a Hash allowing nil/blank,
      # `confirmation` (ActiveModel compares only when the `<attr>_confirmation` accessor is non-nil, so the
      # check adds no error of its own on a nil — the companion's OWN requiredness is a separate question,
      # carried by the gate on the companion config), a maximum-only `length:` (the one check ActiveModel compares
      # a nil against, and a nil's measured size of 0 clears any maximum — see length_admits_nil?), a
      # `format:` whose literal pattern admits the empty string a nil is tested as (see format_admits_nil?),
      # a `type:` at least one of whose declared klasses nil is an instance of (TypeValidator then reports no
      # defect, so the nil is no type violation at all), an `exclusion` set not containing nil, or an
      # `inclusion` set that explicitly contains nil. Any other active validator — including a bare `true`
      # (e.g. `numericality: true`) — rejects nil.
      #
      # This is the question requiredness and nullability both turn on, asked identically by schema
      # reflection and by a field config's own `optional?` so the two can never disagree about the same
      # declaration.
      def self.nil_accepted?(validations)
        # Judge only the REAL validators: ActiveModel's shared options (if:/unless:/on:/strict:/
        # allow_blank:/allow_nil:) ride in the validations hash but aren't validators, so a restored
        # `strict: true` under a tolerance flag must not read as a nil-rejecting validator and wrongly
        # mark the field required. The judgment is static-maximal: gated validators are counted as if
        # their gates were open (a condition can only relax enforcement at runtime, never tighten it).
        v = validator_entries(validations)
        return true if v.empty?

        # The shared options are stripped from the ENTRY set but still govern how each entry runs, so they are
        # handed to the per-entry judgment rather than discarded: `validates` applies a declaration-wide
        # `allow_nil:`/`allow_blank:` to every validator in the call.
        v.all? { |key, opt| nil_tolerant_validation?(key, opt, shared_validation_options(validations)) }
      end

      # `declaration_options` are the shared options the entry rides alongside — required rather than defaulted,
      # so a caller cannot omit the tier that decides several of these answers and get a quietly wrong one.
      def self.nil_tolerant_validation?(key, opt, declaration_options)
        return true unless opt # a disabled validator (falsy `opt` — `false`/`nil`); ActiveModel skips it

        # Judged on the options `validates` will actually hand the validator, so a declaration-wide tolerance
        # counts exactly as an entry's own does.
        opts = effective_entry_options(opt, declaration_options)
        return true if opts[:allow_nil] || opts[:allow_blank]
        return true if key == :absence
        return true if key == :acceptance && acceptance_admits_nil?(opts)
        return true if key == :confirmation
        return true if key == :format && format_admits_nil?(opts)
        return true if key == :length && length_admits_nil?(opts)
        return true if key == :type && type_admits_nil?(opts)
        return true if key == :exclusion && set_includes_nil?(opts) == false
        return true if key == :inclusion && set_includes_nil?(opts) == true

        false
      end

      # Whether a validator ENTRY is scoped to an ActiveModel validation CONTEXT — an `on:` among its options,
      # which makes it permanently inert: `Fields.errors_for` calls `valid?` with no context, so the entry runs
      # on no call at all. THE definition behind the declaration guard that refuses one
      # (`_reject_validator_context_scope!`) — its only consumer: a context-scoped entry cannot be declared, so no
      # judgment downstream ever meets one.
      #
      # Only the key's presence is asked: `validate` installs the context gate on `options.key?(:on)` whatever
      # the value, so `on: nil`/`false`/`[]` name a context no call is in exactly as `on: :publish` does —
      # `Array(nil)` is `[]`, and intersecting an empty Array with anything is empty.
      #
      # Distinct from an if:/unless: GATE, which a given call MAY run, and which stays fully supported.
      # (Not to be confused with a DECLARATION-level `on:`, which is axn's subfield parent.)
      def self.entry_context_scoped?(entry_opts) = entry_carries_option?(entry_opts, :on)

      # Whether a validator ENTRY carries ActiveModel's `strict:` among its options, which asks for a mode axn
      # does not have: strict raising replaces the recorded error with a raise, and axn settles a contract
      # violation by raising already — so the strict exception reaches the same handling and the settlement it
      # pre-empted is simply lost. THE definition behind the declaration guard that refuses one
      # (`_reject_strict_validation!`) — its only consumer, so no judgment downstream ever meets one.
      #
      # Only the key's presence is asked. ActiveModel reads the option by TRUTHINESS (`errors.add`'s
      # `if exception = options[:strict]`), so a falsy one really is inert — but that makes `strict:` an option
      # whose only accepted value would be the one that does nothing, which is not an option axn has. Keyed the
      # way `uniqueness:` is rather than the way `confirmation: false`/`coerce: false` are: those two leave a
      # falsy entry alone because their TRUTHY spelling is supported, so the falsy one is a real no-op inside a
      # real option. `strict: true` is supported nowhere, so `strict: false` is not a no-op within an option —
      # it is a switch that cannot be turned on, and admitting it would advertise one that can. It would also
      # move the error: a config-driven `strict: flag` declares cleanly where the flag is false and raises at
      # class definition where it is true, which is the same declaration failing in one environment only.
      def self.entry_declares_strict?(entry_opts) = entry_carries_option?(entry_opts, :strict)

      # One ENTRY, one option key, asked without dispatching to the bag — the shared read behind both refusals
      # above, because a guard a caller can invert is not a guard: `hash_or_nil` classifies with `case`/`when`
      # (which does not call the object's `is_a?`) and `carries_key?` binds `Hash#key?`. That matches how
      # ActiveModel reads the same bag — `_parse_validates_options` cases on `Hash`, and `key?` is asked of the
      # plain Hash its `merge` builds — so the two cannot disagree about one entry.
      def self.entry_carries_option?(entry_opts, key)
        bag = Axn::Internal::ShapeGraph.hash_or_nil(entry_opts)
        !nil.equal?(bag) && Axn::Internal::ShapeGraph.carries_key?(bag, key)
      end

      # Whether an `acceptance:` ENTRY would let a nil through. ActiveModel's AcceptanceValidator skips a nil
      # outright unless the entry disables that (`allow_nil: false`), and even then accepts a value that is a
      # MEMBER of the accept set — so an explicit nil in the set is accepted with the skip disabled. With no
      # set of its own AM compares against its default `["1", true]`, which excludes nil, so the absence of a
      # set is not tolerance. Membership is the shared literal-set judgment, which answers "unknown" for a set
      # reflection may not read — and unknown resolves to nil-REJECTING, the safe direction.
      def self.acceptance_admits_nil?(entry_opts)
        return true unless entry_opts.is_a?(Hash) && entry_opts[:allow_nil] == false

        set_includes_nil?(entry_opts, keys: %i[accept]) == true
      end

      # Whether a `type:` ENTRY would let a nil through — nil is an instance of at least one declared klass
      # (`type: [Array, NilClass]`, `type: Object`), so TypeValidator finds the value valid and the nil is no
      # type violation at all. Union semantics are TypeValidator's own: a value matching ANY declared klass
      # passes, so one nil-admitting member admits nil.
      #
      # Both reads are non-dispatching, and this is a path where that matters most: every declaration guard
      # that stands down on a nil tolerance asks this at CLASS-DEFINITION time, so a token deciding how it is
      # read decides a guard's verdict, and one whose method raises stops the class being defined at all. The
      # bag is classified by `ShapeGraph.hash_or_nil` rather than by asking it `is_a?(Hash)`, and the tokens by
      # `ShapeGraph.type_tokens` rather than by `Kernel#Array`, which would dispatch the token's own
      # `to_ary`/`to_a`.
      def self.type_admits_nil?(entry_opts)
        bag = Axn::Internal::ShapeGraph.hash_or_nil(entry_opts)
        klasses = Axn::Internal::ShapeGraph.type_tokens(nil.equal?(bag) ? entry_opts : bag[:klass])

        klasses.any? { |klass| type_klass_admits_nil?(klass) }
      end

      # Whether ONE declared klass would let a nil through, per TypeValidator's own matcher — so the
      # nil-tolerance judgment that drives optional?/requiredness/nullability and the declaration-time
      # nil-skip push-down cannot disagree about the same declaration.
      def self.type_klass_admits_nil?(klass)
        Validators::TypeValidator.value_matches?(nil, klass:)
      rescue TypeError
        # A `type:` that is neither a Class/Module nor a known pseudo-type is a broken declaration whose
        # TypeError belongs to validation time, where it already surfaces. Answer "admits nil" so the caller
        # stands down and the declaration behaves exactly as it does with the question unasked, rather than
        # preempting that error here. Scoped to this one call so an unrelated TypeError still propagates.
        true
      end

      # WHERE a clusivity set lives, for one validator entry: under one of `keys:` in the hash long form
      # (`in:`/`within:` for inclusion/exclusion, `accept:` for acceptance), or the bare collection itself in
      # the shorthand (`inclusion: %w[a b]`). The two enforce the same set at runtime, so every consumer reads
      # them identically. THE single definition of that location, shared by the nil-membership judgment below,
      # the declaration-time satisfiability guard (contract.rb `_reject_unsatisfiable_value_constraints!`), and schema
      # reflection's `enum` (`Schema.inclusion_enum_values`), so no two can disagree about which collection one
      # entry names.
      def self.declared_set_collection(opt, keys: %i[in within])
        return keys.filter_map { |key| opt[key] }.first if opt.is_a?(Hash)

        opt
      end

      # The MEMBERS of a clusivity set, when they are members axn may read: a literal in-memory Array or Set, or
      # a Hash (whose `include?` tests KEYS, so the keys are the members). Nil — "can't tell" — for everything
      # else, because a judgment on a set must stay side-effect-free: a dynamic collection (a Symbol or Proc
      # resolved against the record at validation time, an `ActiveRecord::Relation` whose `include?` would query
      # the database) is never read, and neither is an Array SUBCLASS, which could override the traversal.
      # Exact-class throughout (`instance_of?`), for the reason reflection's own read is (PRO-2944).
      #
      # THE single definition of "which members can be judged", shared by the nil-membership judgment below and
      # by the declaration-time satisfiability guard, so the two cannot read one declaration differently.
      def self.literal_set_members(opt, keys: %i[in within])
        collection = declared_set_collection(opt, keys:)
        members = collection.instance_of?(Hash) ? collection.keys : collection
        return nil unless literal_set_collection?(members)

        members
      rescue StandardError
        nil
      end

      # Whether a collection is one axn may read its members out of directly: an in-memory Array or Set, and
      # exactly those classes rather than any descendant, since a subclass could override the traversal. THE
      # single definition of that admissibility test, shared by the reader above and by the satisfiability
      # guard's `acceptance:` branch (contract.rb), which reads its set under a different rule
      # (`AcceptanceValidator` tests `Array(accept).include?(value)`) but admits exactly the same shapes.
      def self.literal_set_collection?(collection)
        collection.instance_of?(::Array) || (defined?(Set) && collection.instance_of?(::Set))
      end

      # Tri-state: nil = can't tell; true/false = nil's membership in the set. Only inspected for in-memory
      # literal collections: reflection must stay side-effect-free, so a dynamic collection (e.g. an
      # ActiveRecord::Relation, whose `include?` would query the database) is treated as unknown (nil).
      # Detection is identity-based (`equal?(nil)`), never `include?`/`==`: an element with a custom `==`
      # could itself run user code. A Range's bounds are Comparable, so nil is never a member.
      # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
      #
      # `keys:` names where the set lives in the long form, so the one judgment serves every validator that
      # compares a value against a literal set — `in:`/`within:` for inclusion/exclusion, `accept:` for
      # acceptance.
      def self.set_includes_nil?(opt, keys: %i[in within])
        return false if declared_set_collection(opt, keys:).is_a?(Range)

        members = literal_set_members(opt, keys:)
        return nil if members.nil?

        members.any? { |element| element.equal?(nil) }
      rescue StandardError
        nil
      end
      # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

      # The value of one ActiveModel shared default option (`:if`/`:unless`/`:on`/`:strict`/…) as it
      # applies to a single validator ENTRY. `validates` builds each validator's options as
      # `declaration_defaults.merge(entry_options)` (activemodel 7.2.2.2), so an entry that carries the
      # key OVERRIDES the declaration-level value — including overriding it with a blank/falsy one — and
      # an entry that does not carries the declaration's. THE single definition of that precedence, so
      # every question about a shared option ("is this entry gated?", "would it raise?") resolves the
      # two tiers identically. The QUALIFYING test is the caller's, because it differs per key: gates
      # turn on blankness, `strict:` on truthiness.
      def self.entry_effective_option(entry_opts, declaration_options, key)
        nested = entry_opts.is_a?(Hash) ? entry_opts : {}
        nested.key?(key) ? nested[key] : declaration_options[key]
      end

      # Which gate keys EFFECTIVELY gate a single validator entry, given the declaration-level gates
      # (`decl_gates` = the sliced :if/:unless off the whole declaration, already blank-canonicalized).
      # Models AM's per-key precedence STRUCTURALLY — which keys are present/blank — never by evaluating
      # a condition. Blankness is the measured predicate AM applies (`value.blank?` — a Proc/Symbol is
      # never blank; nil/false/""/[] are), so a blank nested value drops the shared gate for that key and
      # is then ignored, leaving the entry UN-gated on it. Declaration-level gates arrive
      # blank-canonicalized, so a present key there is always a real gate. An entry is EFFECTIVELY GATED
      # iff any returned key survives.
      #
      # THE single definition of "can this validator be skipped at runtime", shared by schema reflection
      # and by the declaration-time nil-skip push-down (contract.rb `_type_rejects_nil?`), so both judge
      # the same declaration the same way.
      def self.entry_effective_gate_keys(entry_opts, decl_gates)
        Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS.reject do |key|
          entry_effective_option(entry_opts, decl_gates, key).blank?
        end
      end

      # Whether an entry carries a gate OF ITS OWN — a non-blank nested if:/unless: that can skip just this
      # validator, whatever the rest of the declaration does. Asked through the per-entry gate model above
      # with NO declaration-level gates supplied, which is what "of its own" means: a declaration-level gate
      # skips every validator together, so it is not this entry's. Blankness is AM's own rule (a blank nested
      # gate is a no-op; a Symbol/Proc is never blank), measured because NESTED gates are not canonicalized
      # at declaration the way declaration-level ones are.
      #
      # THE single definition of "can this one entry be skipped on its own", shared by the emptiness axis's
      # deferral test, schema reflection's requiredness-relaxation reasoning, and the nil-skip push-down's
      # test for a type check that stands apart from the rest of its declaration.
      def self.entry_self_gated?(entry_opts) = entry_effective_gate_keys(entry_opts, {}).any?

      # Whether an entry can be skipped at runtime AT ALL — its own nested gates and the declaration-level ones
      # it inherits alike. The question to ask wherever what matters is "does this check run on every call",
      # rather than "can this check be skipped independently of its siblings" (`entry_self_gated?`): a
      # declaration-level gate is not this entry's own, but it stops the entry running just the same.
      #
      # `decl_gates` are the declaration's own `if:`/`unless:`, which must already be blank-canonicalized —
      # true of any bag past `_canonicalize_blank_gates!`, which is every bag a config carries.
      def self.entry_effectively_gated?(entry_opts, decl_gates) = entry_effective_gate_keys(entry_opts, decl_gates).any?

      # Whether a single validator ENTRY's options MENTION a per-validator gate key at all — blank or not
      # (contrast entry_self_gated?, which requires a NON-blank value). A blank nested gate is not inert:
      # per AM's measured per-key merge, a blank nested same-key value OVERRIDES and drops the shared
      # (declaration) gate for that key before AM ignores it — un-gating the entry. So an entry that
      # mentions a gate key no longer inherits the declaration's value FOR THAT KEY, in either direction (a
      # non-blank nested value ties it to a different condition; a blank one un-gates it outright) — which
      # is why key PRESENCE, not effective gatedness, is the right test wherever a declaration-level gate's
      # reach into one entry is being asked rather than that entry's own runtime skippability.
      #
      # `keys:` narrows WHICH gate keys count, because the merge is per key: an entry mentioning a key the
      # declaration does not carry adds a condition of its own on top of the shared ones and so can only
      # narrow itself, while mentioning a key the declaration DOES carry replaces that shared condition and
      # can widen the entry past its siblings. A caller comparing one entry's reach against another's asks
      # only about the shared keys; a caller asking whether an entry stands apart from the declaration at all
      # takes the default.
      #
      # THE single definition, shared by schema reflection's declaration-gate-clause fallback and by the
      # declaration-time nil-skip push-down (contract.rb `_type_rejects_nil?`), so both judge the same
      # declaration the same way.
      def self.entry_mentions_gate_key?(opt, keys: Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
        opt.is_a?(Hash) && keys.any? { |key| opt.key?(key) }
      end

      # The size checks a `length:` entry actually runs, resolved the way ActiveModel's LengthValidator
      # resolves its own options (activemodel 7.2.2.2): `in:`/`within:` expand into `minimum:`/`maximum:` (a
      # beginless/endless range contributing only the bound it has, an exclusive end counting one less), and
      # an entry that is explicitly blank-INtolerant with neither `minimum:` nor `is:` of its own picks up
      # AM's implicit `minimum: 1`. A falsy bound is dropped, mirroring `validate_each`'s own
      # `next unless check_value = options[key]`.
      #
      # THE single definition of "what does this entry check", read by the floor reader below and by the
      # nil-tolerance judgment, so neither can disagree with the other about one declaration.
      def self.declared_length_checks(entry_opts)
        opts = validator_entry_options(entry_opts)
        checks = opts.slice(:is, :minimum, :maximum).select { |_key, bound| bound }
        if (range = opts[:in] || opts[:within]).is_a?(Range)
          checks[:minimum] = range.min if range.begin
          checks[:maximum] = (range.exclude_end? ? range.end - 1 : range.end) if range.end
        end
        checks[:minimum] = 1 if opts[:allow_blank] == false && checks[:minimum].nil? && checks[:is].nil?

        checks
      end

      # The smallest size a `length:` entry admits, read from the checks it runs. A `maximum: 0` names the
      # floor too, by leaving size 0 as the only admissible size. Returns nil when the entry leaves the floor
      # open (a `maximum:` of 1 or more, or no size key at all), and `:unverifiable` for a floor AM resolves
      # per call (a Symbol/Proc).
      #
      # Every lower bound the entry declares is weighed, not just the first one found: `LengthValidator`
      # iterates its CHECKS and adds an error for each that fails, so `is:` and `minimum:` both run and the
      # effective floor is the LARGER of them. Preferring `is:` hid an empty interval — `length: { is: 2,
      # minimum: 3 }` reported 2..2 and declared, while ActiveModel rejects a value of every length (measured),
      # and the emitted node advertised `minItems: 2` as satisfiable. A satisfiable node for a contract that
      # admits nothing is the same emitter/runtime disagreement as its mirror, read the other way round.
      #
      # For a compatible pair the answer is unchanged, which is what makes this a narrowing rather than a new
      # reading: `is: 2, minimum: 1` is still 2, since the `is:` was already the larger.
      #
      # THE single definition of "how small a value may this length: entry be", shared by the emptiness
      # reconciliation at declaration (contract.rb) and by schema reflection's `minItems`/`minProperties`/
      # `minLength` emission, so the runtime floor and the emitted floor cannot disagree.
      def self.declared_length_floor(entry_opts)
        checks = declared_length_checks(entry_opts)

        lowers = [checks[:is], checks[:minimum]].compact
        return :unverifiable unless lowers.all? { |bound| bound.is_a?(Numeric) }

        floor = lowers.max
        max = checks[:maximum]
        return 0 if floor.nil? && max.is_a?(Numeric) && max.zero?

        floor
      end

      # The largest size a `length:` entry admits, read from the checks it runs — the twin of the floor above,
      # off the same `declared_length_checks`, so an `in:`/`within:` range (exclusive end counted one less) and
      # an `is:` (which names both bounds) resolve identically for both. Returns nil when the entry leaves the
      # ceiling open (a `minimum:` alone, or no size key at all), and `:unverifiable` for a ceiling ActiveModel
      # resolves per call (a Symbol/Proc).
      #
      # Blank-tolerance is not consulted, and the floor's careful reasoning about it does not transfer: a
      # tolerated empty value measures 0, which every non-negative ceiling already admits, so a ceiling is exact
      # whether or not an empty value stands the entry aside.
      #
      # Every upper bound is weighed for the same reason the floor weighs every lower one, and by the mirror
      # rule: both checks run, so the effective ceiling is the SMALLER of `is:` and `maximum:`.
      # `length: { is: 2, maximum: 1 }` is satisfied by nothing and used to declare.
      # `Float::INFINITY` — ActiveModel's spelling for "no ceiling" — loses to any real bound beside it, which
      # is what that spelling means.
      #
      # THE single definition of "how large may this length: entry be", read by schema reflection's
      # `maxItems`/`maxProperties`/`maxLength` emission.
      def self.declared_length_ceiling(entry_opts)
        checks = declared_length_checks(entry_opts)

        uppers = [checks[:is], checks[:maximum]].compact
        return :unverifiable unless uppers.all? { |bound| bound.is_a?(Numeric) }

        uppers.min
      end

      # Whether a ceiling read above is one a JSON Schema `maxItems`/`maxProperties`/`maxLength` can carry: a
      # non-negative Integer. `0` counts — it names size 0 as the only admissible size, which is a constraint a
      # caller can act on. `Float::INFINITY` (ActiveModel's spelling for "no ceiling") and a fractional bound
      # (which its LengthValidator refuses outright at validation time) are both uncarryable, exactly as they
      # are for the floor.
      def self.emittable_length_ceiling?(ceiling) = ceiling.is_a?(Integer) && !ceiling.negative?

      # The operators ActiveModel compares a value against, shared by `numericality:` and `comparison:` —
      # `NumericalityValidator`'s COMPARE_CHECKS and `ComparisonValidator`'s are the same five plus
      # `other_than:`, which is deliberately absent here: an inverted operator has no JSON Schema keyword, and
      # the same reasoning keeps it out of PRO-3192's satisfiability judgment.
      NUMERIC_BOUND_KEYS = %i[greater_than greater_than_or_equal_to less_than less_than_or_equal_to equal_to].freeze

      # The bounds a `numericality:`/`comparison:` entry compares against, read from the checks it actually
      # runs — the twin of `declared_length_checks`, and THE single definition of "what does this entry bound",
      # so the runtime bound and the emitted `minimum`/`maximum` cannot disagree about one declaration.
      #
      # `ranged:` is required rather than defaulted, because the answer differs by validator and a caller that
      # omitted it would get a quietly wrong one: `numericality:` resolves an `in:` range (its `RANGE_CHECKS`
      # is `{ in: :in? }`), while `comparison:` has no range check at all — so reading `in:` there would report
      # a bound ActiveModel never enforces.
      #
      # A falsy bound is dropped, mirroring the validators' own `next unless option_value`. `0` is kept: it is
      # a real bound, and only `nil`/`false` are falsy in Ruby.
      def self.declared_numeric_bounds(entry_opts, ranged:)
        opts = validator_entry_options(entry_opts)
        bounds = opts.slice(*NUMERIC_BOUND_KEYS).select { |_key, bound| bound }
        return bounds unless ranged

        range = opts[:in]
        return bounds unless range.is_a?(Range)

        # ActiveModel enforces an `in:` range AND any explicit bound beside it, so the range is INTERSECTED
        # into what the entry already declared rather than assigned over it: `{ greater_than_or_equal_to: 10,
        # in: 0..100 }` is bounded below by 10, not by 0.
        intersect_numeric_bound(bounds, :greater_than_or_equal_to, range.begin) if range.begin
        # An exclusive end is the strict operator rather than a decremented bound: unlike a length, a numeric
        # bound has no "one less" (`1...10` admits 9.999), so the exclusivity has to be carried as itself.
        intersect_numeric_bound(bounds, range.exclude_end? ? :less_than : :less_than_or_equal_to, range.end) if range.end
        bounds
      end

      # THE definition of "two of these bounds, both enforced" — the tighter one survives. A MINIMUM operator
      # keeps the larger bound and a MAXIMUM operator the smaller, which is what enforcing both means.
      # Comparison is guarded: bounds a caller may have written in unrelated classes (a Symbol, a Date beside an
      # Integer) have no ordering, and there the existing bound stands rather than a `<=>` raising inside a
      # declaration.
      MINIMUM_BOUND_KEYS = %i[greater_than greater_than_or_equal_to].freeze

      # What an intersection with no solution resolves to. Not a bound, so `emittable_numeric_bound?` refuses it
      # and nothing is emitted for that side — the honest answer for a contract no value satisfies. Refusing
      # such a declaration outright belongs to the contradiction detectors (PRO-3220); emitting a SATISFIABLE
      # keyword for it, as picking either candidate would, is the one option that is simply wrong.
      CONTRADICTORY_BOUND = :__axn_contradictory_bound__
      private_constant :CONTRADICTORY_BOUND

      # Asked rather than compared against, so the sentinel stays this module's own: reflection reads it through
      # a predicate exactly as it reads every other judgment here, and never names the constant.
      def self.contradictory_bound?(bound) = bound == CONTRADICTORY_BOUND

      def self.intersect_numeric_bound(bounds, key, candidate)
        existing = bounds[key]
        return bounds[key] = candidate if existing.nil?
        return bounds[key] if existing == CONTRADICTORY_BOUND

        # `equal_to` is an equality rather than an ordering, so two different values intersect to nothing at
        # all — there is no "tighter" of the two, and keeping either advertises a value the runtime rejects.
        if key == :equal_to
          return bounds[key] = existing == candidate ? existing : CONTRADICTORY_BOUND
        end

        tighter = begin
          comparison = existing <=> candidate
          if comparison.nil?
            existing
          elsif MINIMUM_BOUND_KEYS.include?(key)
            comparison.negative? ? candidate : existing
          else
            comparison.positive? ? candidate : existing
          end
        rescue StandardError
          existing
        end
        bounds[key] = tighter
      end

      # Whether a bound read above is one a JSON Schema numeric keyword can carry. A `Numeric` that is not
      # finite (`Float::INFINITY`, ActiveModel's spelling for "no bound", and `NaN`) names no number, and a
      # Symbol/Proc bound is resolved per call against the record — the same stand-down a Symbol `length:`
      # bound gets. Restricted to Integer and Float on purpose: a `BigDecimal` or `Rational` bound has no
      # single JSON number form (its `to_json` depends on the consumer's setup), so it stands down rather than
      # emit a value the document might carry as a string.
      # `CONTRADICTORY_BOUND` needs no branch of its own: it is a Symbol, and every Symbol — a per-call bound
      # ActiveModel resolves against the record included — falls to the same refusal.
      def self.emittable_numeric_bound?(bound)
        case bound
        when ::Integer then true
        when ::Float then bound.finite?
        else false
        end
      end

      # Whether a `numericality:` entry restricts its value to whole numbers, which narrows the emitted type
      # from "number" to "integer" even when a wider `type:` token would otherwise decide it.
      #
      # Only a STATIC token answers. ActiveModel resolves this option per call against the record
      # (`resolve_value`, activemodel 7.2.2.2), so a Proc/Symbol that comes back false leaves every non-integer
      # the entry's other options admit still in play — and reading one as a narrowing emitted a node the value
      # it narrowed for cannot occupy: `type: [Integer, Float]` advertised `"integer"` and rejected the Float
      # exposed under it, `type: Float` emptied to `enum: []`, and a string branch carried the integer-literal
      # `pattern`, which rejects the `"1.5"` the validator parses happily. Unknown stands down in BOTH
      # directions, the same refusal a Symbol/Proc numeric bound gets from `emittable_numeric_bound?`.
      #
      # `resolve_value`'s own reach decides what counts as dynamic: a Symbol, and anything answering `#call` —
      # its `else` branch calls a callable too, so testing for Proc alone would miss a callable object.
      def self.declared_only_integer?(entry_opts)
        token = validator_entry_options(entry_opts)[:only_integer]
        return false if token.is_a?(::Symbol) || token.respond_to?(:call)

        token ? true : false
      end

      # The test `only_integer:` actually applies, handed to reflection rather than restated there: the emitted
      # pattern has to agree with the validator that runs, and a copy in the emitter would drift from it in
      # silence. Lives here because this is the layer that owns what ActiveModel means — `schema.rb` requires no
      # part of ActiveModel and must keep resolving every constant it names on its own.
      def self.integer_literal_regexp = ::ActiveModel::Validations::NumericalityValidator::INTEGER_REGEX

      # Whether a `format:` ENTRY would let a nil through. FormatValidator tests `value.to_s` against the
      # pattern (activemodel 7.2.2.2), so a nil is tested as the empty string and the pattern decides — with
      # the polarity flipped by key: `with:` records an error UNLESS the pattern matches, so it tolerates a nil
      # exactly when the pattern matches ""; `without:` records one WHEN it matches, so it tolerates a nil
      # exactly when the pattern does not. `with:` is asked first, as AM asks it.
      #
      # Only a literal Regexp answers: `Regexp#match?` on one runs no user code, while a Proc/Symbol option is
      # resolved against the record at validation time (AM's `resolve_value`) and reflection may never run it
      # — unknown, which resolves to nil-REJECTING. Exact-class, since a subclass could override `match?`.
      # The entry is read in the shape AM acts on, so a bare `format: /re/` is judged as the `with:` it becomes.
      def self.format_admits_nil?(entry_opts)
        opts = validator_entry_options(entry_opts)

        if (with = opts[:with]).instance_of?(Regexp)
          with.match?("")
        elsif (without = opts[:without]).instance_of?(Regexp)
          !without.match?("")
        else
          false
        end
      end

      # Whether a `length:` entry lets a NIL through — a different question from what sizes it admits.
      # ActiveModel compares a nil against one check only: `validate_each` reaches the comparison for a nil
      # when `skip_nil_check?(key)` holds — `key == :maximum && options[:allow_nil].nil? &&
      # options[:allow_blank].nil?` (activemodel 7.2.2.2) — and a nil measures 0 (`nil.to_s.length`), which
      # clears any maximum. Every other check records its error on a nil whatever its bound, so a `minimum: 0`
      # rejects a nil even while admitting size 0, and a range rejects one through the floor it sets.
      #
      # An explicit `allow_nil: false`/`allow_blank: false` turns that skip off, and a truthy one never
      # reaches here (the generic tolerance branch answers first), so the key's presence is what is asked —
      # mirroring `skip_nil_check?`, which is private to the validator instance.
      def self.length_admits_nil?(entry_opts)
        opts = validator_entry_options(entry_opts)
        return false unless opts[:allow_nil].nil? && opts[:allow_blank].nil?

        checks = declared_length_checks(opts)
        checks.key?(:maximum) && !checks.key?(:minimum) && !checks.key?(:is)
      end

      # Whether a floor read by `declared_length_floor` is one a JSON Schema `minItems`/`minProperties`/
      # `minLength` can carry: a positive Integer, the only shape a size constraint takes. THE single
      # definition of "does this floor count", read by schema reflection's emission AND by the emptiness
      # reconciliation, which leans on an author's floor only when the schema can advertise the same number —
      # otherwise the runtime would enforce a floor the schema drops.
      #
      # Two floors are positive yet uncarryable, and neither can hold the emptiness axis: `Float::INFINITY`
      # (ActiveModel's own spelling for "no size passes", which no finite floor expresses) and a fractional
      # one (which ActiveModel refuses as a bound outright — its LengthValidator accepts a non-negative
      # Integer, `Float::INFINITY`, a Symbol or a Proc, and raises otherwise at validation time).
      def self.emittable_length_floor?(floor) = floor.is_a?(Integer) && floor.positive?

      # Delegate unknown methods to the action instance so symbol-referenced validation arguments
      # (e.g. `inclusion: { in: :valid_channels_for_number }`) resolve against the action — for
      # top-level fields and subfields alike.
      def method_missing(method_name, ...)
        action = _action_for_validation
        return super unless action && action.respond_to?(method_name, true) # rubocop:disable Style/SafeNavigation

        action.send(method_name, ...)
      end

      def respond_to_missing?(method_name, include_private = false)
        action = _action_for_validation
        return super unless action

        action.respond_to?(method_name, include_private) || super
      end

      private

      def _action_for_validation = nil
    end

    # Carrier object for errors aggregated ACROSS validator instances (top-level + subfield + model
    # consistency in one settled exception). ActiveModel::Errors renders full messages through its
    # base's class (human_attribute_name), so the base must be an ActiveModel::Validations-bearing
    # object — an action instance isn't one.
    class Aggregate
      include ActiveModel::Validations

      def self.name = "Axn::Validation::Aggregate"
    end
  end
end
