# frozen_string_literal: true

module Axn
  module Validation
    # How axn reads the SET a clusivity validator compares a value against, and the one rewrite it applies to
    # that set at declaration. Extended into `Validation::Base`, which is the surface every consumer reaches
    # these through — the declaration guards and schema reflection both ask `Base` — so this is a home for the
    # concern rather than a second entry point to it.
    #
    # `inclusion:`/`exclusion:` are the two validators whose membership is decided by the COLLECTION's own
    # `include?` rather than by an operator, which is what made the container a semantic choice, and what makes
    # this cluster worth naming.
    module ClusivitySets
      # WHERE a clusivity set lives, for one validator entry: under one of `keys:` in the hash long form
      # (`in:`/`within:` for inclusion/exclusion, `accept:` for acceptance), or the bare collection itself in
      # the shorthand (`inclusion: %w[a b]`). The two enforce the same set at runtime, so every consumer reads
      # them identically. THE single definition of that location, shared by the nil-membership judgment below,
      # the declaration-time satisfiability guard (contract.rb `_reject_unsatisfiable_value_constraints!`), and schema
      # reflection's `enum` (`Schema.inclusion_enum_values`), so no two can disagree about which collection one
      # entry names.
      def declared_set_collection(opt, keys: %i[in within])
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
      def literal_set_members(opt, keys: %i[in within])
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
      def literal_set_collection?(collection)
        collection.instance_of?(::Array) || (defined?(Set) && collection.instance_of?(::Set))
      end

      # The two validators that name a set of values the field's own value is compared AGAINST. THE single
      # definition, so the canonicalization below and the declaration guards (contract.rb `CLUSIVITY_KEYS`)
      # cannot come to name different validators. `acceptance:` is deliberately not one of them: it names its
      # set under `accept:` and reads it through `Array()`, which already compares by `==`.
      CLUSIVITY_KEYS = %i[inclusion exclusion].freeze

      # Where a clusivity entry's set sits in the hash long form. `accept:` is absent for the reason above.
      CLUSIVITY_SET_KEYS = %i[in within].freeze

      # A collection whose `include?` is keyed by HASH IDENTITY rather than by `==`, read out as its members —
      # or nil for one that already compares by `==` (an Array), names a span rather than members (a Range), or
      # is not axn's to read (a Symbol or Proc resolved per call, an `ActiveRecord::Relation`, a SUBCLASS whose
      # traversal is its own).
      #
      # A Hash's members are its keys, which is what its `include?` tests.
      #
      # Exact-class (`instance_of?`) for the reason every other set read here is: a descendant could override
      # the traversal this reads through, and axn does not run a caller's code to canonicalize a declaration.
      def hash_keyed_set_members(collection)
        return collection.keys if collection.instance_of?(::Hash)
        return collection.to_a if defined?(Set) && collection.instance_of?(::Set)

        nil
      end

      # Rewrites a clusivity set written in a hash-keyed container into its members, so ONE equality decides
      # membership wherever the declaration is read (PRO-3319).
      #
      # `Clusivity` calls the collection's own `include?`, so the container used to choose the equality: an
      # Array compares with `==` and crosses the numeric family (`[1].include?(BigDecimal("1"))`), while a Set
      # and a Hash look the value up by `hash` + `eql?` and do not. That made the same literal enforce two
      # different contracts depending on how it was spelled, left the declaration guards judging one of the two
      # readings, and dropped the set from the emitted `enum` (which admits only an Array).
      #
      # It was not even a STABLE reading. A Ruby Hash of eight or fewer entries keeps only an 8-bit hint of each
      # key's hash and falls through to `eql?` when the hint matches; `BigDecimal#eql?` is aliased to `#==`, so
      # `Set[1].include?(BigDecimal("1"))` was true in roughly one process in 256, decided by the hash seed, and
      # false again once the set passed eight members.
      #
      # Canonicalizing at declaration is what makes the guards, the runtime and the schema agree by
      # construction rather than by coincidence — they all read the same Array. The members are read into a NEW
      # Array and merged into a NEW options Hash, so neither the caller's collection nor their bag becomes the
      # declaration's storage.
      #
      # Mutates `validations`, and only for a key it actually rewrites. A falsy entry is a disabled validator
      # ActiveModel skips, which names no set at all.
      def canonicalize_clusivity_sets!(validations)
        graph = Axn::Internal::ShapeGraph
        CLUSIVITY_KEYS.each do |key|
          next unless graph.carries_key?(validations, key)

          entry = validations[key]
          next unless entry

          canonical = canonical_clusivity_entry(entry)
          validations[key] = canonical unless canonical.equal?(entry)
        end
      end

      # ONE clusivity entry, canonicalized. The bare shorthand becomes the long form its members belong in —
      # ActiveModel's own `_parse_validates_options` maps only a Range or an Array to `{ in: }`, so a bare Set
      # became `{ with: … }`, reached `check_validity!` with no delimiter at all, and raised on EVERY call.
      #
      # The entry is returned unchanged — by identity, which is how the caller knows not to write — whenever
      # there is nothing to rewrite: an Array or Range set, a collection axn may not read, or a long form
      # naming no set at all.
      def canonical_clusivity_entry(entry)
        graph = Axn::Internal::ShapeGraph
        options = graph.hash_or_nil(entry)

        if nil.equal?(options)
          members = hash_keyed_set_members(entry)
          return members.nil? ? entry : { in: members }
        end

        key = CLUSIVITY_SET_KEYS.find { |candidate| graph.carries_key?(options, candidate) }
        return entry if key.nil?

        members = hash_keyed_set_members(options[key])
        members.nil? ? entry : options.merge(key => members)
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
      def set_includes_nil?(opt, keys: %i[in within])
        return false if declared_set_collection(opt, keys:).is_a?(Range)

        members = literal_set_members(opt, keys:)
        return nil if members.nil?

        members.any? { |element| element.equal?(nil) }
      rescue StandardError
        nil
      end
      # rubocop:enable Style/ReturnNilInPredicateMethodDefinition
    end
  end
end
