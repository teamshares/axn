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

      # ActiveModel's shared "default" validator options — keys that ride alongside validator entries
      # in a `validates` call but are NOT validators themselves (if:/unless:/on:/strict:/allow_blank:/
      # allow_nil:). Exposed so the tolerance push-down (contract.rb) can hold them OUT of the
      # per-validator scalar normalization — merging tolerance into `strict: true`, say, would rewrite
      # it to a Hash and break strict raising. Reuses AM's own canonical list so the set can't drift.
      def self.shared_validation_option_keys = _validates_default_keys

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
      # which ActiveModel skips), one scoped to a validation context (it never runs, so it rejects
      # nothing), `absence` (nil is always
      # "absent"), `acceptance` unless explicitly `allow_nil: false` (ActiveModel's acceptance is allow_nil
      # by default), a Hash allowing nil/blank, `confirmation` (ActiveModel compares only when the
      # `<attr>_confirmation` accessor is non-nil, so the check adds no error of its own on a nil), a
      # maximum-only `length:` (the one check ActiveModel compares a nil against, and a nil's measured size of
      # 0 clears any maximum — see length_admits_nil?), a `format:` whose literal pattern admits the empty
      # string a nil is tested as (see format_admits_nil?), a `type:` at least one of whose declared klasses nil
      # is an instance of (TypeValidator then reports no defect, so the nil is no type violation at all), an
      # `exclusion` set not containing nil, or an `inclusion` set that explicitly contains nil. Any other
      # active validator — including a bare `true` (e.g. `numericality: true`) — rejects nil.
      #
      # This is the question requiredness and nullability both turn on, asked identically by schema
      # reflection and by a field config's own `optional?` so the two can never disagree about the same
      # declaration.
      def self.nil_accepted?(validations)
        # Judge only the REAL validators: ActiveModel's shared options (if:/unless:/on:/strict:/
        # allow_blank:/allow_nil:) ride in the validations hash but aren't validators, so a restored
        # `strict: true` under a tolerance flag must not read as a nil-rejecting validator and wrongly
        # mark the field required. The judgment is static-maximal: gated validators are counted as if
        # their gates were open (a condition can only relax enforcement at runtime, never tighten it) — a
        # context-scoped entry is different in kind, running on no call at all, and counts for nothing.
        v = validator_entries(validations)
        return true if v.empty?

        # The shared options are stripped from the ENTRY set but still govern how each entry runs, so they are
        # handed to the per-entry judgment rather than discarded: `validates` applies a declaration-wide
        # `allow_nil:`/`allow_blank:` to every validator in the call.
        declaration_options = validations.slice(*shared_validation_option_keys)
        v.all? { |key, opt| nil_tolerant_validation?(key, opt, declaration_options) }
      end

      # `declaration_options` are the shared options the entry rides alongside — required rather than defaulted,
      # so a caller cannot omit the tier that decides several of these answers and get a quietly wrong one.
      def self.nil_tolerant_validation?(key, opt, declaration_options)
        return true unless opt # a disabled validator (falsy `opt` — `false`/`nil`); ActiveModel skips it
        return true if entry_context_scoped?(opt)
        return true if entry_tolerates_nil?(opt, declaration_options)
        return true if key == :absence
        return true if key == :acceptance && acceptance_admits_nil?(opt)
        return true if key == :confirmation
        return true if key == :format && format_admits_nil?(opt)
        return true if key == :length && length_admits_nil?(opt)
        return true if key == :type && type_admits_nil?(opt)
        return true if key == :exclusion && set_includes_nil?(opt) == false
        return true if key == :inclusion && set_includes_nil?(opt) == true

        false
      end

      # Whether an entry runs nil-tolerant, at either tier `validates` resolves: its OWN `allow_nil:`/
      # `allow_blank:` if it carries one, otherwise the declaration-wide value, which AM applies to every
      # validator in the call. Read through the shared per-entry precedence model, so this answers the same
      # way the gate and `strict:` questions do — and truthiness decides, so a hash-level `allow_nil: false`
      # confers nothing and an entry's own `false` overrides a declaration-wide `true`.
      def self.entry_tolerates_nil?(entry_opts, declaration_options)
        %i[allow_nil allow_blank].any? { |key| entry_effective_option(entry_opts, declaration_options, key) }
      end

      # Whether a validator ENTRY is scoped to an ActiveModel validation CONTEXT — an `on:` inside the
      # entry's own options — which makes it permanently inert: `Fields.errors_for` calls `valid?` with no
      # context, so the entry runs on no call at all and whatever it would have rejected is vacuous. Only
      # the key's presence is asked: any `on:` disables the entry, whatever its value.
      #
      # Distinct from an if:/unless: GATE, which a given call MAY run: reflection counts a gated entry as if
      # its gate were open (static-maximal — stricter than a closed-gate runtime, and safe), while a
      # context-scoped entry has no call on which it applies. THE single definition, shared by the
      # declaration-time nil-skip push-down, the emptiness axis's deferral test, and schema reflection's
      # floor emission. (Not to be confused with a DECLARATION-level `on:`, which is axn's subfield parent
      # and never reaches a validator entry.)
      def self.entry_context_scoped?(entry_opts) = entry_opts.is_a?(Hash) && entry_opts.key?(:on)

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
      def self.type_admits_nil?(entry_opts)
        klasses = Array(entry_opts.is_a?(Hash) ? entry_opts[:klass] : entry_opts)
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
        # The set is the collection under one of `keys` (hash long form) or the bare collection itself
        # (shorthand — inclusion: %w[a b], exclusion: [nil, "x"]); the two are equivalent at runtime, so
        # nil-membership is judged the same for both.
        collection = opt.is_a?(Hash) ? keys.filter_map { |key| opt[key] }.first : opt
        return false if collection.is_a?(Range)

        # A Hash is a collection ActiveModel accepts, and its `include?` tests KEYS — so the keys are the
        # members whose nil-membership is asked, judged by the same identity rule as any other set.
        members = collection.instance_of?(Hash) ? collection.keys : collection
        return nil unless members.instance_of?(Array) || (defined?(Set) && members.instance_of?(Set))

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
      # deferral test and by schema reflection's requiredness-relaxation reasoning.
      def self.entry_self_gated?(entry_opts) = entry_effective_gate_keys(entry_opts, {}).any?

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
      # THE single definition of "how small a value may this length: entry be", shared by the emptiness
      # reconciliation at declaration (contract.rb) and by schema reflection's `minItems`/`minProperties`/
      # `minLength` emission, so the runtime floor and the emitted floor cannot disagree.
      def self.declared_length_floor(entry_opts)
        checks = declared_length_checks(entry_opts)

        floor = checks[:is] || checks[:minimum]
        max = checks[:maximum]
        return 0 if floor.nil? && max.is_a?(Numeric) && max.zero?
        return :unverifiable unless floor.nil? || floor.is_a?(Numeric)

        floor
      end

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
