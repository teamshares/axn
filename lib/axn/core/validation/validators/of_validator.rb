# frozen_string_literal: true

require "active_model"

require "axn/internal/cycle_guard"
require "axn/internal/native_methods"
require "axn/internal/shape_graph"

module Axn
  module Validators
    class OfValidator < ActiveModel::EachValidator
      def self.apply_syntactic_sugar(value, _fields)
        return value if value.is_a?(Hash)

        { klass: value }
      end

      # A map names its axes with `keys:`/`values:`, either of which may be left off. An element bag names
      # `klass:` only when that is what it constrains — `of: { shape: … }` is "each element has these members,
      # class unconstrained" — and the declaration guard has already refused a bag constraining none of the
      # three. `of:` is admitted beside `shape:` for completeness rather than because a DECLARED bag can reach
      # it: one carrying `of:` always names a container too (`_inner_of_container!` refuses otherwise), so only
      # a config ASSIGNED onto a class arrives here with an inner contract and no class of its own.
      def check_validity!
        return if options[:container] == ::Hash
        # A bag constrains the position with a class, with what is inside it, or with its own value validators
        # (PRO-3193) — any one of the three is enough, and the declaration guard already refuses a bag with none.
        return if inner_contract_validations(options)

        raise ArgumentError, "must supply :klass" if options[:klass].nil?
      end

      # `allow_nil:`/`allow_blank:` are read as the ELEMENT position's tolerance now (`position_contract`,
      # `PositionContract#tolerates?`), not the field's — so a nil-tolerant position must not excuse a nil
      # FIELD by skipping this validator outright. Not load-bearing on its own either: both branches below
      # `return unless value.is_a?(…)` and no-op on a nil field regardless.
      def validate_each(record, attribute, value)
        options[:container] == ::Hash ? validate_entries(record, attribute, value) : validate_elements(record, attribute, value)
      end

      private

      # The declared container decides which branch runs; the value's own class only decides whether this
      # validator has anything to say about it. TypeValidator owns both mismatches.
      def validate_elements(record, attribute, value)
        return unless value.is_a?(::Array)

        contract = element_contract

        value.each_with_index do |el, i|
          validate_position(record, attribute, contract, el, "element at index #{i}")
        end
      end

      # What ONE unnamed position declares, resolved once per declaration rather than once per element or
      # entry: the classes its value is held to, the message a mismatch reports, and the inner contract it
      # carries (with the validator class built from it). An Array's element position IS the bag `of:`
      # canonicalized into these options, and each of a map's axes holds a bag of exactly the same grammar —
      # so one resolver serves all three and none of them can drift from the others.
      #
      # `klass:` is deliberately absent from `contents`, because the type check is performed by
      # `validate_position` and its message ("element at index 0 is not a String" — no colon) differs in
      # punctuation from a delegated one, which is prefixed with a colon. `contents` is nil when the position
      # constrains only a class, which is the overwhelmingly common case and the one that must allocate nothing.
      PositionContract = Data.define(:klasses, :message, :contents, :validator_class, :contents_node, :tolerance) do
        # Whether this position admits the value without asking anything else of it — the positional reading of
        # `allow_nil:`/`allow_blank:`, which is what those keys mean at a named shape member too.
        #
        # What this stands down is the position's OWN `klass:` check, and it stands it down for a NIL only —
        # mirroring `TypeValidator`, which is the check a named position runs and which excuses a nil alone
        # (`value.nil? && (allow_nil || allow_blank)`). Measured at a field: `type: String, allow_blank: true`
        # accepts `""` and `"   "` because they ARE Strings, accepts nil because the flag excuses it, and still
        # rejects `false` and `[]` as "is not a String" — even though ActiveModel's own `EachValidator` would
        # skip the validator outright for every one of those, `false` included. axn's type check deliberately
        # does not follow AM there, so neither does a position's.
        #
        # The position's OTHER checks are not decided here at all: the bag's value validators carry the
        # tolerance as their declaration tier (`inner_contract_validations`) and ActiveModel applies its own
        # blank-skip to each of them, which is what lets a value class defining domain blankness be answered at
        # a position exactly as it is at a named one, and what lets an entry override the position per key.
        def tolerates?(value)
          nil.equal?(value) && !!(tolerance[:allow_nil] || tolerance[:allow_blank])
        end
      end
      private_constant :PositionContract

      # The element position's contract, read off the validator's own options — which ARE the element bag.
      def element_contract = @element_contract ||= position_contract(options)

      # One axis of a map. Memoized per axis for the reason the element contract is: a validator instance is
      # built once per declaration and lives for the life of the process, so a per-entry rebuild would build a
      # validator class per entry of every Hash validated.
      def axis_contract(axis)
        @axis_contracts ||= {}
        @axis_contracts[axis] ||= position_contract(options[axis])
      end

      def position_contract(declared)
        bag = Axn::Internal::ShapeGraph.hash_or_nil(declared)
        return bare_type_contract(declared) if nil.equal?(bag)

        contents = inner_contract_validations(bag)
        PositionContract.new(
          # `ShapeGraph.type_tokens`, not `Kernel#Array`: `bag[:klass]` is the caller's own declared token, and
          # this classifies the DECLARATION rather than an input value — reflection already reads it through
          # the same seam (`Schema.declared_type_tokens`), and a validator dispatching the token's own `to_ary`
          # here would hold every element to a class reflection never advertised (PRO-3233).
          klasses: Axn::Internal::ShapeGraph.type_tokens(bag[:klass]),
          message: bag[:message],
          contents:,
          # Built once here, exactly as ShapeValidator caches its per-member classes.
          validator_class: contents && Axn::Validation::ContainerContents.validator_class_for(
            field: :__axn_contents__, validations: contents,
          ),
          # The child this position's descent is about to validate against, which is the identity a cyclic
          # graph brings back around (see `guard_contents_descent`). Nil for a bag whose `contents` are only
          # value validators (PRO-3193), which has no child at all — and the guard needs no special case for
          # that: it keys the pair BY IDENTITY and pops on the way out, so nil is a stable key like any other,
          # and a validator-only bag is a LEAF, so no ancestry can form through it for the guard to detect.
          # Measured: identical behaviour with and without a bypass, at every depth up to the nesting bound.
          contents_node: contents && (bag[:of] || bag[:shape]),
          tolerance: Axn::Validation::Base.tolerance_options(bag),
        )
      end

      # A position naming a bare type — or naming nothing at all, which is an undeclared axis — constrains a
      # class and nothing else, and must allocate nothing beyond that.
      def bare_type_contract(declared)
        PositionContract.new(klasses: Axn::Internal::ShapeGraph.type_tokens(declared), message: nil, contents: nil,
                             validator_class: nil, contents_node: nil, tolerance: {})
      end

      # Everything the position is held to, as a VALIDATIONS bag — the two recursion edges (`of:`/`shape:`) and
      # the value validators the bag carries (PRO-3193). Nil when it carries none of them.
      #
      # Derived by SUBTRACTING what describes the position (`klass:` is the type check `matches_axis?` runs,
      # `message:` names it, `container:`/`shaped_keys:` are axn's own derivations, `keys:`/`values:` are the
      # map's axes handled by `validate_entries`) rather than by picking out the keys to forward. Picking them
      # out is what made this method the silent-ignore hole PRO-3165 closed at the grammar: a key the whitelist
      # admits but this method does not forward declares cleanly, reaches ActiveModel through nothing, and
      # constrains nothing — so the two lists have to be one list, and subtraction makes them one.
      #
      # The shared ActiveModel options come out through `validator_entries`, which is what "these are not
      # validators" already means everywhere else. The position's TOLERANCE leaves with them, and deliberately
      # does not travel into the forwarded contents: `validate_position` stands the whole position down for a
      # tolerated value in one place, rather than re-expressing the same fact as a flag on every forwarded
      # entry.
      def inner_contract_validations(bag)
        entries = Axn::Validation::Base.validator_entries(bag)
        contents = entries.reject do |key, value|
          Axn::Internal::ShapeGraph::POSITION_DESCRIPTION_KEYS.include?(key) || !value
        end
        return nil if contents.empty?

        # The position's tolerance rides along as the DECLARATION tier of the contract these contents become, so
        # ActiveModel resolves it against each entry exactly as it does at a named position:
        # `defaults.merge(_parse_validates_options(options))`, which lets an entry override the position per key.
        # Standing the whole position down instead reimplemented that precedence and got it wrong in the one case
        # where the two tiers disagree — measured, `of: { klass: String, format: { with: /x/, allow_nil: false },
        # allow_nil: true }` skipped the `format:` that had just refused the exemption, while the equivalent named
        # member ran it and rejected the nil.
        #
        # Only a TRUE tolerance is forwarded. The pair is stated explicitly on every bag, `false` included, to keep
        # a field's tolerance from reaching the position — and forwarding those `false`s would push them onto every
        # entry as a declaration default, overriding nothing but re-stating a default ActiveModel already holds.
        contents.merge(Axn::Validation::Base.true_tolerance_options(bag))
      end

      # One position of one value: its own type check, then whatever its inner contract says about what is
      # inside it.
      #
      # A position that TOLERATES the value stands down its own TYPE check — the class it names is the thing the
      # position itself asserts, and `allow_nil:`/`allow_blank:` are what excuse a value from it. It does NOT
      # stand down the CONTENTS: those carry the same tolerance as their declaration tier
      # (`inner_contract_validations`) and are judged by ActiveModel, which lets an individual entry override the
      # position per key. Skipping them here instead would override the entry with the position, inverting AM's
      # precedence — measured against the named position that mirrors this one.
      #
      # The type verdict does NOT gate the contents check either — a wrong-typed element still reports what could
      # not be read out of it, which is what an author fixing a payload needs.
      #
      # A custom `message:` replaces the type description but the POSITION is always reported — an ordinal is
      # the only locating info an unnamed position has. Built only on the failure path.
      def validate_position(record, attribute, contract, value, position)
        record.errors.add(attribute, "#{position} #{position_mismatch(contract)}") if !contract.tolerates?(value) && !matches_axis?(value, contract.klasses)
        return if nil.equal?(contract.contents)

        add_contents_errors(record, attribute, contract, value, "#{position}: ")
      end

      def position_mismatch(contract) = contract.message || describe_mismatch(contract.klasses)

      # Descending into a position's own contents is the step that can recurse forever, so it is the step that
      # is bounded — on the two terms every walk of a graph a class merely HOLDS is bounded on, and for the
      # reason `ShapeValidator#guard_descent` is bounded on them. The declaration walk refuses both a cyclic and
      # an over-deep `of:` graph, but a field config ASSIGNED onto a class (`internal_field_configs=`) passed no
      # declaration walk and carries whatever its author built. Measured without this guard: a self-referential
      # bag on an assigned config, handed `a = []; a << a`, settled as an `exception` outcome carrying
      # `SystemStackError` — outside `StandardError`, so it escapes the rescue meant to settle it.
      #
      # The pair is (value, bag) for the reason the shape walk's is (value, members): this recursion descends a
      # contract and a value in lockstep, so the same value legitimately reappears under a DIFFERENT bag with
      # its own contents still to check, and value-only ancestry would drop those verdicts. Keyed on the CHILD
      # bag rather than on `options`, because one validator class is built per level so `options` is a fresh
      # Hash each time, while a cyclic graph hands back the same child bag — which is the identity that repeats.
      # A generative graph repeats nothing and falls to the depth bound instead.
      #
      # The depth counter is the SAME one `ShapeValidator` spends, read off and written back through the
      # ancestry both validators thread, so an `of:` rung inside a `shape:` inside an `of:` costs three levels
      # rather than one level three times — the runtime mirror of the single budget the declaration walk keeps
      # across both edges. The comparison is `>`, so a graph whose deepest rung sits exactly AT the cap — which
      # declares legally — still reaches its leaf validators.
      def guard_contents_descent(value, ancestry, contents_node)
        depth = ancestry ? ancestry.depth : 0
        raise ArgumentError, Axn::Internal::ShapeGraph.inner_contract_too_deep_message if depth > Axn::Internal::ShapeGraph::MAX_NESTING

        # `contents_node` is the child this descent is about to validate against — the nested `of:` bag, or the
        # `shape:` node where that is the only edge the position has. Never nil: a nil key would pair every
        # shape-only position with every other, and the second would be dropped as a repeat. It is the
        # POSITION's own child rather than this validator's, so a map's two axes cycle-guard independently.
        Axn::Internal::CycleGuard.guard_pair(value, contents_node, ancestry&.seen, on_cycle: nil) do |seen|
          yield Axn::Internal::CycleGuard::Ancestry.new(seen:, depth: depth + 1)
        end
      end

      def add_contents_errors(record, attribute, contract, value, prefix)
        guard_contents_descent(value, record.send(:_shape_ancestry_for_validation), contract.contents_node) do |ancestry|
          errors = Axn::Validation::Fields.errors_for(
            contract.validator_class,
            source: value,
            validations: contract.contents,
            action: record.send(:_action_for_validation),
            # A shape member's own `method_call:` opt-in is honored by ShapeValidator per member; nothing at
            # this level may re-permit dispatch on the caller's object.
            permit_method_call: false,
            shape_ancestry: ancestry,
          )
          # The classification tags travel with the message. `ShapeValidator` tags each member error with that
          # member's own `user_facing:` intent, and settlement classifies per tag — an UNTAGGED error is the
          # field's own (`Executor#_own_errors`), so re-adding by message alone made a member at an unnamed
          # position inherit the field's `user_facing:` where its named twin one level up does not: an un-opted
          # member published the message field-level semantics withhold. Only the two classification keys are
          # forwarded; everything else in `options` belongs to the validator that raised it.
          errors.each do |error|
            record.errors.add(attribute, "#{prefix}#{error.message}",
                              **error.options.slice(:axn_shape_member, :axn_member_user_facing))
          end
        end
      end

      # Both axes are reported independently: a map whose keys and values are both wrong has two things to
      # fix, and the entry's position locates both. An axis left undeclared constrains nothing, and an axis
      # holding a BAG is a contract of its own that runs through the same position machinery an Array's element
      # does — its class check reports here, and its `of:`/`shape:` contents under a positional prefix.
      #
      # That position is the ONLY locating token the message carries, and the key deliberately is not. A
      # validation message is built here and settled unredacted: it reaches `result.exception.message` and the
      # logged line without passing through `contract/redaction.rb`, so a `sensitive:` map naming its own keys
      # would publish exactly what the declaration asked to be masked. Value-free is the same rule the element
      # branch's index already answers to and the one `TypeValidator` states for its own messages. A Hash
      # enumerates in insertion order, so the index names the entry the caller wrote.
      def validate_entries(record, attribute, value)
        return unless value.is_a?(::Hash)

        keys = axis_contract(:keys)
        values = axis_contract(:values)
        exempt = options[:shaped_keys] || Axn::Internal::ShapeGraph::NO_SHAPED_KEYS
        index = 0

        # Traversed through a BOUND `Hash#each` so a subclass cannot decide which entries get validated — nor,
        # since nothing here renders a key, which entries get to run their own code while being named.
        Axn::Internal::ShapeGraph.each_entry(value) do |key, entry|
          # A key the shape beside this map names is emitted as a `properties` entry, which
          # `additionalProperties` does not govern — so the map contract does not govern it either, on BOTH
          # axes. The ordinal still advances: it names the entry's position in what the caller wrote, not its
          # position among the entries this happens to check.
          unless exempt_key?(key, exempt)
            validate_position(record, attribute, keys, key, "key at index #{index}")
            validate_position(record, attribute, values, entry, "value at index #{index}")
          end
          index += 1
        end
      end

      SYMBOL_NAME = ::Symbol.instance_method(:name)
      STRING_EQ = ::String.instance_method(:==)
      private_constant :SYMBOL_NAME, :STRING_EQ

      # A shape member's key is matched in either form, because extraction accepts both
      # (`FieldResolvers.extract_or_nil` reads a Hash by symbol or by string) and JSON input is string-keyed —
      # a Symbol-only comparison would silently stop exempting for the commonest payload shape there is. Both
      # sides are compared through BOUND base implementations, so a String subclass answering `==` for its own
      # purposes cannot decide whether a key is governed. Anything that is neither is a key no member names.
      def exempt_key?(key, exempt)
        return false if exempt.empty?

        case key
        when ::Symbol then exempt.include?(key)
        when ::String then exempt.any? { |member| STRING_EQ.bind_call(key, SYMBOL_NAME.bind_call(member)) }
        else false
        end
      end

      def matches_axis?(value, klasses)
        klasses.empty? || klasses.any? { |k| TypeValidator.value_matches?(value, klass: k) }
      end

      # Every declared type named through the shared seam rather than interpolated: a declared class whose
      # `to_s` raises would otherwise replace this validation failure with its own exception, settling a
      # contract violation as an `exception` outcome and reporting bad input as an internal error.
      def describe_mismatch(klasses)
        labels = klasses.map { |klass| Axn::Internal::Rendering.type_label(klass) }
        labels.size == 1 ? "is not a #{labels.first}" : "is not one of #{labels.join(', ')}"
      end
    end
  end
end
