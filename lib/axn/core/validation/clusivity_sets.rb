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
        return opt unless opt.is_a?(Hash)

        key = declared_set_key(opt, keys:)
        key && opt[key]
      end

      # WHICH of `keys:` names the set, for an entry in the hash long form — the first one holding a TRUTHY
      # value, which is the precedence ActiveModel itself applies (`@delimiter ||= options[:in] ||
      # options[:within]`, activemodel clusivity.rb). Presence is the wrong question and the difference is
      # reachable: `{ in: nil, within: Set[1] }` carries `:in` while ActiveModel validates against `:within`,
      # so a canonicalization keyed on presence would rewrite nothing and leave that spelling deciding
      # membership by `hash`/`eql?` while every reader here judged the `within` set by `==` — the very
      # divergence the rewrite exists to remove, surviving in one spelling.
      #
      # Shared with the collection reader above rather than respelled, so the two cannot come to disagree
      # about which of the two keys a declaration named.
      def declared_set_key(opt, keys: %i[in within])
        keys.find { |key| opt[key] }
      end

      # The MEMBERS of a clusivity set, when they are members axn may read: a literal in-memory Array or Set, or
      # a Hash (whose `include?` tests KEYS, so the keys are the members). Nil — "can't tell" — for everything
      # else, because a judgment on a set must stay side-effect-free: a dynamic collection (a Symbol or Proc
      # resolved against the record at validation time, an `ActiveRecord::Relation` whose `include?` would query
      # the database) is never read, and neither is an Array SUBCLASS, which could override the traversal.
      # Exact-class throughout, for the reason reflection's own read is (PRO-2944) — established through
      # `Identity.class_of` and compared by identity, so the collection is never asked what it is, and a Hash's
      # keys come out through a bound native reader rather than a `keys` the caller may own.
      #
      # THE single definition of "which members can be judged", shared by the nil-membership judgment below and
      # by the declaration-time satisfiability guard, so the two cannot read one declaration differently.
      def literal_set_members(opt, keys: %i[in within])
        collection = declared_set_collection(opt, keys:)
        return nil if possibly_resolved_per_call?(collection)

        members = Axn::Internal::Identity.class_of(collection).equal?(::Hash) ? HASH_KEYS_READER.bind_call(collection) : collection
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
        klass = Axn::Internal::Identity.class_of(collection)
        klass.equal?(::Array) || (defined?(Set) && klass.equal?(::Set))
      end

      # Whether ActiveModel might RESOLVE this collection per call rather than compare against the members it
      # holds. `Clusivity#resolve_value` runs a Proc, sends a Symbol, and — in its final branch — calls any
      # value answering `respond_to?(:call)`, handing the result to `include?`. A collection it resolves names
      # no static members at all: what it compares against is decided per record.
      #
      # TWO predicates rather than one, and the split is the point. `respond_to?` is the question ActiveModel
      # asks, and it is the one question axn may not ask — dispatching it lets a caller's `respond_to_missing?`
      # decide whether their own set gets judged, while the class is still being defined. So axn approximates
      # it by OWNERSHIP, and an approximation of a boolean has doubtful cases: a `call` reached only through
      # `method_missing` is indistinguishable, without dispatch, from a `method_missing` that does not answer to
      # `call` at all — measured, both leave the method table empty while ActiveModel answers true for one and
      # false for the other.
      #
      # The two decisions that turn on it need those doubtful cases to fall OPPOSITE ways, which is why one
      # predicate cannot serve both:
      #
      #   * READING the members. Doubt must answer "do not read": reading a set the runtime never compares
      #     against makes a guard refuse a contract that works, and that is the one error a declaration-time
      #     guard may not make. Standing down instead costs a refusal that would have been earned.
      #   * Exempting it from the ALIASING refusal. Doubt must answer "do not exempt": a collection whose
      #     members ARE the contract, stored by reference, lets the caller change an already-declared class by
      #     mutating what they still hold. Refusing instead costs an author a `freeze`, which the message names.
      #
      # Permissive only where it has to be: certainty plus the shapes that cannot be decided without dispatch.
      # Visibility IS decidable from the method table, so a NON-public `call` is not a doubtful case at all —
      # ActiveModel will not call it, the container compares against its own members, and reading them is both
      # safe and the only way the refusals they earn keep firing.
      def possibly_resolved_per_call?(collection)
        certainly_resolved_per_call?(collection) || own_dispatch_hooks?(collection)
      end

      # Strict: only a PUBLIC `call` in the method table, which is exactly what `respond_to?(:call)` answers
      # true for without consulting a hook (measured across a public, private and `method_missing`-backed
      # `call`). A private one is found by the table but never called by ActiveModel, so a collection carrying
      # one is a static set like any other and must not slip past the aliasing refusal.
      def certainly_resolved_per_call?(collection)
        owner = Axn::Internal::NativeMethods.method_owner(collection, :call)
        !owner.nil? && Axn::Internal::NativeMethods.public_instance_method?(owner, :call)
      end

      # Whether the collection's method table is the whole truth about it. Ruby owns both hooks for an ordinary
      # value (`BasicObject#method_missing`, `Kernel#respond_to_missing?`), so a container carrying nothing but
      # an unrelated helper keeps an authoritative table — which is what preserves the refusals a decorated but
      # genuinely static set earns.
      def own_dispatch_hooks?(collection)
        DISPATCH_HOOKS.any? do |hook|
          owner = Axn::Internal::NativeMethods.method_owner(collection, hook)
          owner && NATIVE_DISPATCH_HOOK_OWNERS.none? { |native| native.equal?(owner) }
        end
      end

      # The hooks through which a name absent from the method table can still be dispatched, and the owners
      # Ruby itself supplies them from — anything else means the caller took one over.
      DISPATCH_HOOKS = %i[method_missing respond_to_missing?].freeze
      NATIVE_DISPATCH_HOOK_OWNERS = [::BasicObject, ::Kernel, ::Object].freeze

      # Whether `respond_to_missing?` alone is the caller's own — the ONE hook `Kernel#respond_to?` actually
      # consults. `own_dispatch_hooks?` above checks `method_missing` too, because a `call`/`include?` a caller
      # only *dispatches* through `method_missing` is real either way that predicate's doubt falls — but
      # `respond_to?` never asks `method_missing` at all, so a `method_missing` override with no matching
      # `respond_to_missing?` leaves `respond_to?` answering its INHERITED (always-false) verdict for every
      # absent name — deterministically, not doubtfully. `usable_clusivity_delimiter?` mirrors
      # `check_validity!`, which is built entirely out of `respond_to?` checks, so it is this narrower
      # predicate it needs: doubt may only survive where `respond_to?`'s own answer actually could.
      def own_respond_to_missing_hook?(collection)
        owner = Axn::Internal::NativeMethods.method_owner(collection, :respond_to_missing?)
        owner && NATIVE_DISPATCH_HOOK_OWNERS.none? { |native| native.equal?(owner) }
      end

      # The two validators that name a set of values the field's own value is compared AGAINST. THE single
      # definition, so the canonicalization below and the declaration guards (contract.rb `CLUSIVITY_KEYS`)
      # cannot come to name different validators. `acceptance:` is deliberately not one of them: it names its
      # set under `accept:` and reads it through `Array()`, which already compares by `==`.
      CLUSIVITY_KEYS = %i[inclusion exclusion].freeze

      # Where a clusivity entry's set sits in the hash long form. `accept:` is absent for the reason above.
      CLUSIVITY_SET_KEYS = %i[in within].freeze

      # The reader that yields each hash-keyed container's MEMBERS — a Hash's keys, which is what its `include?`
      # tests, and a Set's elements. Unbound and bound per call, so the members are read by Ruby's own
      # implementation and never by a `keys`/`to_a` the caller put on the object.
      HASH_KEYS_READER = ::Hash.instance_method(:keys)

      HASH_KEYED_MEMBER_READERS = [
        [::Hash, HASH_KEYS_READER],
        (defined?(Set) ? [::Set, ::Set.instance_method(:to_a)] : nil),
      ].compact.freeze

      # A collection whose `include?` is keyed by HASH IDENTITY rather than by `==`, read out as its members —
      # or nil for one this must not rewrite: one that already compares by `==` (an Array), one naming a span
      # rather than members (a Range), one that is not axn's to read (a Symbol or Proc resolved per call, an
      # `ActiveRecord::Relation`, a SUBCLASS whose traversal is its own), and one that answers ANYTHING with
      # code of its own.
      #
      # Nothing here dispatches on the caller's object. The class is established through `Identity.class_of`
      # (a bound `Kernel#class`) and compared by identity, and the members come out through an unbound native
      # reader — because this decides how a declaration READS, so a singleton `instance_of?`, `keys` or `to_a`
      # would otherwise let caller code suppress the rewrite, raise while the action class is still being
      # defined, or substitute members and silently rewrite the contract.
      #
      # The ownership stand-down is the same rule the option copy applies to an Array container
      # (`ShapeGraph.detached_option_array`), asked through the same walk: a container's own behaviour is part
      # of what a declaration MEANS, so one carrying its own `include?` keeps deciding its own membership
      # rather than having axn answer for it.
      def hash_keyed_set_members(collection)
        klass = Axn::Internal::Identity.class_of(collection)
        _, reader = HASH_KEYED_MEMBER_READERS.find { |candidate, _| candidate.equal?(klass) }
        return nil if reader.nil?
        return nil unless Axn::Internal::NativeMethods.own_container_methods(collection, klass).empty?

        reader.bind_call(collection)
      end

      # Whether the collection is one of those containers AT ALL, regardless of whether its members may be read
      # out. Kept separate from the reader above because the two answer different questions and only one of them
      # needs the caller's traversal: WHERE a set is written is a question about the spelling, while WHAT its
      # members are is a question about the container's own code.
      def hash_keyed_container?(collection)
        klass = Axn::Internal::Identity.class_of(collection)
        HASH_KEYED_MEMBER_READERS.any? { |candidate, _| candidate.equal?(klass) }
      end

      # Rewrites a clusivity set written in a hash-keyed container into its members, so ONE equality decides
      # membership wherever the declaration is read (PRO-3319).
      #
      # `Clusivity` calls the collection's own `include?`, so the CONTAINER decides which equality applies: an
      # Array compares with `==` and crosses the numeric family (`[1].include?(BigDecimal("1"))` is true), while
      # a Set and a Hash look the member up by `hash` + `eql?`, which never crosses one. Reading the members out
      # here is what leaves the runtime, the declaration guards and the emitted `enum` judging one set rather
      # than three — by construction, not by keeping three readings in agreement.
      #
      # The members are read into a NEW Array and merged into a NEW options Hash, so neither the caller's
      # collection nor their bag becomes the declaration's storage.
      #
      # Mutates `validations`, and only for a key it actually rewrites. A falsy entry is a disabled validator
      # ActiveModel skips, which names no set at all.
      def canonicalize_clusivity_sets!(validations, where: nil)
        graph = Axn::Internal::ShapeGraph
        CLUSIVITY_KEYS.each do |key|
          next unless graph.carries_key?(validations, key)

          entry = validations[key]
          next unless entry

          canonical = canonical_clusivity_entry(entry, key:, where:)
          validations[key] = canonical unless canonical.equal?(entry)
        end
      end

      # A hash-keyed container axn may not read its members out of, and may not copy either, is REFUSED rather
      # than stored — the aliasing rule, with the same exception and the same escape the option copy already
      # applies to an Array container (`ShapeGraph.detached_option_array`).
      #
      # A declared contract must be axn's own, so a set the caller still holds and can still mutate would
      # change an already-declared class retroactively: appending `2` to it makes a value the contract rejected
      # start passing. Copying is not open here for the reason it is not open there — `dup` drops the singleton
      # class, so the copy would answer membership differently from the object that was declared — and reading
      # the members out is exactly what the container's own code has ruled out.
      #
      # FROZEN is the exception and the escape: nothing can mutate it afterwards, which is the same property a
      # copy would buy, so a frozen one is stored as the caller's object and keeps answering its own membership.
      #
      # Asked of BOTH spellings. Refusing only the shorthand would leave `inclusion: set` refused while
      # `inclusion: { in: set }` declared and aliased — one declaration, two answers, which is the split this
      # whole rewrite exists to remove.
      def reject_unreadable_mutable_container!(collection, key, where)
        return if Axn::Internal::NativeMethods.frozen?(collection)

        klass = Axn::Internal::Identity.class_of(collection)
        own = Axn::Internal::NativeMethods.own_container_methods(collection, klass)
        return if own.empty?

        raise ArgumentError,
              "the #{key}: set#{where ? " on #{where}" : ''} (of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(collection)}) defines methods " \
              "of its own (#{Axn::Internal::ShapeGraph.describe_own_methods(own)}), so axn can neither read its " \
              "members out nor copy it. A declared contract is axn's own, so that mutating what you still hold " \
              "cannot change it afterwards — and reading the members would run your code, while `dup` drops the " \
              "singleton class and would answer membership differently from what you declared. Supply a plain " \
              "Set or Array, or freeze this container (a frozen one is stored as-is, since nothing can mutate " \
              "it afterwards)."
      end

      # The three methods ActiveModel's own `Clusivity#check_validity!` accepts a delimiter through —
      # `include?` (a collection), `call` (a Proc/lambda or any other callable), `to_sym` (accepted by
      # `respond_to?(:to_sym)` alone, though `resolve_value` never calls it — see `usable_clusivity_delimiter?`
      # below for why that gap matters). THE single definition, so the refusal below can never name a
      # delimiter ActiveModel's OWN check_validity! would in fact accept.
      CLUSIVITY_DELIMITER_METHODS = %i[include? call to_sym].freeze

      # Whether `name` is in `collection`'s method table as a PUBLIC method — the ownership mirror of
      # `respond_to?(name)` (public-only, which is what `check_validity!` itself asks), read the way
      # `certainly_resolved_per_call?` already reads it for `:call` alone: through the OWNER the method table
      # names, never by dispatching `respond_to?` on the caller's object.
      def public_method_owner?(collection, name)
        owner = Axn::Internal::NativeMethods.method_owner(collection, name)
        !owner.nil? && Axn::Internal::NativeMethods.public_instance_method?(owner, name)
      end

      # Whether `collection` can even ANSWER `respond_to?` at all — the one prerequisite every branch below
      # assumes and none of them may override. `check_validity!` probes the delimiter with
      # `delimiter.respond_to?(:include?) || delimiter.respond_to?(:call) || delimiter.respond_to?(:to_sym)` —
      # an EXPLICIT-receiver call, so it needs a PUBLIC `respond_to?`, not merely one present in the table. A
      # value rooted at `BasicObject` with nothing added has no `respond_to?` at all, and a class that narrows
      # the inherited one to `private`/`protected` (unusual, but not unreachable) has one the table finds but
      # `delimiter.respond_to?(...)` still cannot reach — both raise `NoMethodError` from that very first probe
      # regardless of what `include?`/`call` the object itself defines. That is CERTAIN failure, readable
      # without dispatch (the same owner-plus-visibility read `public_method_owner?` uses for every other
      # name), not the doubtful case the rest of this method exists to permit through — so it is checked first
      # and unconditionally.
      def respond_to_reachable?(collection)
        public_method_owner?(collection, :respond_to?)
      end

      # Whether ActiveModel's `Clusivity#check_validity!` would accept this as a delimiter — mirrored by
      # OWNERSHIP rather than by dispatching `respond_to?` on the caller's object, for the reason
      # `certainly_resolved_per_call?` gives. A collection carrying its own `respond_to_missing?` is undecidable
      # without running it, and DOUBT MUST ANSWER "usable": refusing it would refuse a declaration ActiveModel —
      # and the runtime — accepts, which is the one error a declaration-time guard may not make.
      #
      # Checked NARROWER than `own_dispatch_hooks?` above: `respond_to_missing?` alone, never `method_missing`.
      # `check_validity!` is built entirely out of `respond_to?` checks, and `respond_to?` consults only
      # `respond_to_missing?` when a name is absent from the table — `method_missing` never enters into it. A
      # collection overriding `method_missing` for some unrelated dynamic API, with no matching
      # `respond_to_missing?`, still answers `respond_to?(:include?)`/`:call`/`:to_sym` false through the
      # INHERITED (always-false) `respond_to_missing?` — deterministically, not doubtfully — so
      # `check_validity!` raises regardless of what `method_missing` would have done if actually reached.
      # Standing down for `method_missing` alone would let exactly that object declare cleanly and then raise
      # ActiveModel's own `ArgumentError` on every call, the shape this guard exists to close (measured).
      #
      # `to_sym` is judged differently from the other two, because `check_validity!` and the runtime it guards
      # disagree about what it means: `check_validity!` accepts anything answering `respond_to?(:to_sym)`, but
      # `resolve_value` never calls that method — it dispatches on `case value when Symbol` (`is_a?(Symbol)`),
      # and a value that fails that falls through to `value.include?(record_value)` instead. An object with a
      # public `to_sym` that is not itself a Symbol clears `check_validity!` on that gap and then raises
      # `NoMethodError` from `include?` on every call — the exact declares-cleanly-then-raises shape this guard
      # exists to close, reached through a seam in ActiveModel's own two checks rather than around them. Judged
      # by IDENTITY (`Identity.class_of`, never `is_a?`, for the reason every predicate here is): `Symbol` takes
      # no subclass (`Symbol.allocate` raises `TypeError`), so there is no override this could miss.
      def usable_clusivity_delimiter?(collection)
        return false unless respond_to_reachable?(collection)
        return true if own_respond_to_missing_hook?(collection)
        return true if Axn::Internal::Identity.class_of(collection).equal?(::Symbol)

        (CLUSIVITY_DELIMITER_METHODS - %i[to_sym]).any? { |name| public_method_owner?(collection, name) }
      rescue StandardError
        true
      end

      # Whether the `include?` ActiveModel would actually CALL is String's own. A String answers `include?`
      # (so `usable_clusivity_delimiter?` above is true for it, and `check_validity!` declares it clean), but
      # it is the one common delimiter whose membership test is not membership at all: `String#include?` is a
      # SUBSTRING test, and raises `TypeError` for any value that is not itself a String. So `type: Integer,
      # inclusion: { in: "12" }` declares cleanly and raises on every call — the same shape this guard exists
      # to close, just past the one check that lets everything else through.
      #
      # Asked by OWNERSHIP, not by class: a String SUBCLASS that has not overridden `include?` inherits the
      # same substring behaviour and is refused on the same terms, while one that overrides it decides its own
      # membership and is exempt — the same rule `certainly_resolved_per_call?` applies to `call`.
      def string_keyed_delimiter?(collection)
        Axn::Internal::NativeMethods.method_owner(collection, :include?).equal?(::String)
      rescue StandardError
        false
      end

      # No delimiter at all: a long-form entry naming neither `in:` nor `within:` a TRUTHY value (an empty
      # Hash, one carrying only `message:`/`if:`/…, or one whose only size key is falsy) reaches
      # `check_validity!` with `delimiter` resolved to `nil`, which answers none of `include?`/`call`/`to_sym`
      # and raises ActiveModel's own `ArgumentError` on EVERY call — the declares-cleanly-then-always-raises
      # shape this guard exists to close, reported separately from the case below because there is no
      # offending VALUE to describe.
      def reject_missing_clusivity_delimiter!(key, where)
        raise ArgumentError,
              "#{key}: on #{where} names no set at all — neither `in:` nor `within:` carries a value. " \
              "Declared, the class defines cleanly and every call raises ActiveModel's own `ArgumentError: An " \
              "object with the method #include? or a proc, lambda or symbol is required, and must be supplied " \
              "as the :in (or :within) option of the configuration hash` from Clusivity#check_validity! " \
              "instead. Name the set: an Array or Range of members, a Symbol naming an action method that " \
              "returns one, or a Proc/lambda called with the record."
      end

      # A delimiter ActiveModel's own `Clusivity#check_validity!` cannot use at all. Described BY CLASS,
      # never by `inspect`: this is an error-reporting path over the caller's own value, and dispatching its
      # `inspect` here would let it replace this ArgumentError with whatever IT raises instead — the same
      # reason `reject_unreadable_mutable_container!` above and `_reject_invalid_length_bounds!` (contract.rb)
      # read a caller value the same way.
      def reject_unusable_clusivity_delimiter!(collection, key, where)
        raise ArgumentError,
              "#{key}: on #{where} names a set of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(collection)}, which " \
              "ActiveModel cannot use — declared, the class defines cleanly and every call raises ActiveModel's " \
              "own `ArgumentError: An object with the method #include? or a proc, lambda or symbol is " \
              "required, and must be supplied as the :in (or :within) option of the configuration hash` from " \
              "Clusivity#check_validity! instead. Name an Array or Range of members, a Set or Hash (whose keys " \
              "are read as members), a Symbol naming an action method that returns a collection, or a " \
              "Proc/lambda called with the record."
      end

      # A String delimiter — declares cleanly (a String answers `include?`) and raises on every call anyway;
      # see `string_keyed_delimiter?` for why.
      def reject_string_clusivity_delimiter!(collection, key, where)
        raise ArgumentError,
              "#{key}: on #{where} names a String as its set (of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(collection)}). A String " \
              "answers membership by SUBSTRING, and raises `TypeError` for any value that is not itself a " \
              "String — so declared, the class defines cleanly and every call raises unless the field's own " \
              "value is a String. Name the members instead (`%w[a b c]`), or use `format:` for a " \
              "substring/pattern check."
      end

      # ONE clusivity entry, canonicalized. The bare shorthand becomes the long form its members belong in:
      # ActiveModel's `_parse_validates_options` maps only a Range or an Array to `{ in: }` and everything else
      # to `{ with: }`, which reaches `check_validity!` with no delimiter and raises on every call — so every
      # bare delimiter ActiveModel could otherwise use (a Proc, a Symbol, a plain `include?`-answering object,
      # a Set subclass) is wrapped into the long form here, exactly as the Set/Hash case already was
      # (PRO-3319). One that ActiveModel could never use, in either spelling, is refused instead (PRO-3326).
      #
      # The entry is returned unchanged — by identity, which is how the caller knows not to write — whenever
      # there is nothing to rewrite: a collection axn may not read (frozen, so stored as declared), or a long
      # form already naming a usable set.
      def canonical_clusivity_entry(entry, key: :inclusion, where: nil)
        graph = Axn::Internal::ShapeGraph
        options = graph.hash_or_nil(entry)

        if nil.equal?(options)
          members = hash_keyed_set_members(entry)
          return { in: members } if members

          if hash_keyed_container?(entry)
            # A container whose members must not be read still needs the long form, and does not need reading
            # to get it: the shorthand is a SPELLING that ActiveModel maps only for a Range or an Array, so
            # leaving a bare Set as written sent it to `with:` and raised `ArgumentError` on every call.
            # Wrapping the collection itself keeps its own `include?` answering membership while making the
            # spelling valid.
            reject_unreadable_mutable_container!(entry, key, where) unless certainly_resolved_per_call?(entry)
            return { in: entry }
          end

          reject_unusable_clusivity_delimiter!(entry, key, where) unless usable_clusivity_delimiter?(entry)
          reject_string_clusivity_delimiter!(entry, key, where) if string_keyed_delimiter?(entry)

          return { in: entry }
        end

        set_key = declared_set_key(options, keys: CLUSIVITY_SET_KEYS)
        reject_missing_clusivity_delimiter!(key, where) if set_key.nil?

        collection = options[set_key]
        members = hash_keyed_set_members(collection)
        return options.merge(set_key => members) if members

        if hash_keyed_container?(collection)
          reject_unreadable_mutable_container!(collection, key, where) unless certainly_resolved_per_call?(collection)
          return entry
        end

        reject_unusable_clusivity_delimiter!(collection, key, where) unless usable_clusivity_delimiter?(collection)
        reject_string_clusivity_delimiter!(collection, key, where) if string_keyed_delimiter?(collection)

        entry
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
