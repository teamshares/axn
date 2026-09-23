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
      # true for without consulting a hook — PROVIDED `respond_to?` itself is native and untouched. A private
      # one is found by the table but never called by ActiveModel, so a collection carrying one is a static
      # set like any other and must not slip past the aliasing refusal.
      #
      # This is OWNERSHIP of `call` alone, not routing certainty: an overridden `respond_to?` can hide a real
      # public `call` behind a `false` answer for `:call` specifically, routing `resolve_value` to `include?`
      # instead. A caller asking "is `resolve_value` CERTAIN to route through `.call`" — which is what the
      # ALIASING exemptions below need, since doubt there must answer "do not exempt" — wants
      # `certainly_routed_to_call?` instead. This narrower, ownership-only predicate remains correct for its
      # OTHER two callers precisely because they need the opposite doubt direction: `possibly_resolved_per_
      # call?` (member-reading, doubt answers "do not read" — a real `call`, however `respond_to?` might
      # route around it, is reason enough to leave the object unread) and `dynamically_resolved_per_call?`
      # (the String-refusal exemption, doubt answers "do not refuse" — the same favorable direction
      # `certainly_routed_to_call?` would only narrow unnecessarily) (Codex, PR #288).
      def certainly_resolved_per_call?(collection)
        owner = Axn::Internal::NativeMethods.method_owner(collection, :call)
        !owner.nil? && Axn::Internal::NativeMethods.public_instance_method?(owner, :call)
      end

      # Whether `resolve_value` is CERTAIN to route through `.call` — `certainly_resolved_per_call?`'s real
      # public `call`, PLUS confirmation that `respond_to?` itself is untouched (`!own_respond_to_hook?`), so
      # nothing can make `resolve_value`'s `value.respond_to?(:call)` answer anything but the truthful `true`
      # a real `call` earns. This is the predicate the ALIASING exemptions below need — a Proc/lambda's
      # behavior genuinely cannot be mutated after creation the way a container's elements can, which is why
      # `certainly_resolved_per_call?` alone used to seem sufficient, but that reasoning only holds when
      # `resolve_value` is GUARANTEED to reach `.call` at all: an unfrozen object with a real `call` AND a
      # real `include?`, whose `respond_to?` is overridden to hide `:call` specifically, is certainly NOT
      # exempt from the freeze requirement — `resolve_value` routes it through the mutable `include?` for
      # certain, and mutating the still-held object after declaring changes membership retroactively (Codex,
      # PR #288, fresh evidence after the earlier call-routing fix: "only the usability path accounts for the
      # overridden probe — the new aliasing exemptions still use the old table-only certainty predicate").
      def certainly_routed_to_call?(collection)
        certainly_resolved_per_call?(collection) && !own_respond_to_hook?(collection)
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

      # Whether `respond_to?` ITSELF is the caller's own, distinct from `respond_to_missing?` above.
      # `check_validity!` calls `delimiter.respond_to?(...)` directly, and Ruby dispatches WHICHEVER
      # implementation the caller's class defines — a caller who overrides `respond_to?` outright (rather
      # than going through the conventional `respond_to_missing?` hook) governs its own answer just as
      # completely, and just as undecidably without running it. DOUBT MUST ANSWER "usable" here for the same
      # reason it does for `respond_to_missing?` (Codex, PR #288).
      #
      # A NIL owner is a THIRD case, not a "no" — `respond_to?` can be unreachable through the normal table
      # (narrowed to private/protected, or `undef_method`'d outright) and STILL be what actually answers
      # `delimiter.respond_to?(...)`, because Ruby routes a call it cannot dispatch normally through
      # `method_missing` regardless of why the normal dispatch failed (`respond_to_reachable?` already
      # depends on this same fact). So a nil owner defers to whether `method_missing` is the caller's own: if
      # it is, the probe is answered by CALLER code either way and stays doubtful; if it is not, `respond_to?`
      # is either absent or plain Kernel's own, and `respond_to_reachable?` having already passed means the
      # ONLY way it did is a public `respond_to?` this method already found — so a bare `nil` here, with no
      # `method_missing`, cannot be reached from `usable_clusivity_delimiter?` at all (Codex, PR #288, a
      # second case beyond the private-`respond_to?`-plus-`method_missing` one already fixed).
      def own_respond_to_hook?(collection)
        owner = Axn::Internal::NativeMethods.method_owner(collection, :respond_to?)
        return own_method_missing_hook?(collection) if owner.nil?

        NATIVE_DISPATCH_HOOK_OWNERS.none? { |native| native.equal?(owner) }
      end

      # Whether `method_missing` alone is the caller's own — the ONE hook that can actually catch a message
      # Ruby's normal dispatch (`public_send`, an ordinary `.call`) fails to find in the method table. Neither
      # `respond_to?` nor `respond_to_missing?` participates in dispatch at all — they only decide what
      # `respond_to?` REPORTS, which a caller-owned override of either makes undecidable (see
      # `own_respond_to_missing_hook?`/`own_respond_to_hook?`), but that doubt is worthless on its own: an
      # object claiming to answer `:include?` through an overridden `respond_to?`/`respond_to_missing?`, with
      # NEITHER hook actually catching the call, still raises `NoMethodError` from the real dispatch — for
      # CERTAIN, not doubtfully, since `method_missing` absent (native) means nothing stands between the miss
      # and the raise. So a doubtful `respond_to?` answer may only stand in for a real `include?`/`call` when
      # `method_missing` is ALSO the caller's own (Codex, PR #288).
      def own_method_missing_hook?(collection)
        owner = Axn::Internal::NativeMethods.method_owner(collection, :method_missing)
        owner && NATIVE_DISPATCH_HOOK_OWNERS.none? { |native| native.equal?(owner) }
      end

      # Whether ActiveModel might dispatch `.call` on this collection AT ALL — certainly, through a real public
      # `call`, or DOUBTFULLY, through an overridden `respond_to?`/`respond_to_missing?` that might answer true
      # for `:call` — PROVIDED `method_missing` is there to catch the dispatch if it happens; a doubtful
      # `respond_to?(:call)` answer with no `method_missing` to back it still raises `NoMethodError` for
      # certain, per `own_method_missing_hook?` above. THE single question `string_keyed_delimiter?` needs:
      # would `resolve_value`'s `respond_to?(:call)` check route this collection to `.call` before its own
      # `include?` (substring or otherwise) is ever reached.
      def dynamically_resolved_per_call?(collection)
        certainly_resolved_per_call?(collection) ||
          ((own_respond_to_missing_hook?(collection) || own_respond_to_hook?(collection)) &&
            own_method_missing_hook?(collection))
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

      # Whether `name` is in `collection`'s method table as a PUBLIC method — the ownership mirror of
      # `respond_to?(name)` (public-only, which is what `check_validity!` itself asks), read the way
      # `certainly_resolved_per_call?` already reads it for `:call` alone: through the OWNER the method table
      # names, never by dispatching `respond_to?` on the caller's object.
      def public_method_owner?(collection, name)
        owner = Axn::Internal::NativeMethods.method_owner(collection, name)
        !owner.nil? && Axn::Internal::NativeMethods.public_instance_method?(owner, name)
      end

      # Whether `collection`'s OWN `name` — already established owned via `public_method_owner?` (or, for a
      # Range's `begin`/`end`, owned by ANYONE at all, native or overridden) — can be called with EXACTLY
      # `count` positional arguments. Every prerequisite this file dispatches on the caller's object is called
      # with a FIXED count, and none of them gets the arity adaptation `resolve_value`'s Proc branch gives its
      # own callable (`value.arity == 0 ? value.call : value.call(record)`) — a real, public method matching
      # neither the exact count nor a `:rest` still raises `ArgumentError` on the very first genuine dispatch,
      # however correctly it answers `respond_to?`/ownership otherwise (Codex, PR #288, across two rounds:
      # `include?`/`cover?`/`call` first, then `respond_to?`/`is_a?`/`public_send`/Range `begin`/`end`, "the
      # analogous ... failure").
      #
      # The fixed counts, so a caller reads them straight off the real call sites rather than re-deriving:
      # `respond_to?(:include?)` and `enumerable.is_a? Range` are each ONE; `members.public_send(name,
      # value)` is TWO; `enumerable.begin`/`.end` are ZERO.
      #
      # Read from `UnboundMethod#parameters`, never by calling it. A `:keyreq` makes ANY positional count
      # insufficient on its own (a required keyword still goes unsupplied); a `:rest` accepts any count
      # (this is what lets `Proc#call`'s own `(*args)` — and any object whose `call` matches that shape —
      # clear the one-argument check unconditionally, matching `resolve_value`'s actual leniency there);
      # otherwise `count` must fall within `:req` through `:req + :opt`.
      def accepts_positional_args?(collection, name, count)
        method = Axn::Internal::NativeMethods.declared_method(collection, name)
        return false if method.nil?

        params = method.parameters
        return false if params.any? { |type, _| type == :keyreq }
        return true if params.any? { |type, _| type == :rest }

        required = params.count { |type, _| type == :req }
        optional = params.count { |type, _| type == :opt }
        required <= count && (required + optional) >= count
      end

      def accepts_single_positional_arg?(collection, name) = accepts_positional_args?(collection, name, 1)

      # Whether `collection` can even ANSWER `respond_to?` at all — the one prerequisite every branch below
      # assumes and none of them may override. `check_validity!` probes the delimiter with
      # `delimiter.respond_to?(:include?) || delimiter.respond_to?(:call) || delimiter.respond_to?(:to_sym)` —
      # an EXPLICIT-receiver call, so a PUBLIC `respond_to?` answers it for CERTAIN. A value rooted at
      # `BasicObject` with nothing added has no `respond_to?` at all, and a class that narrows the inherited
      # one to `private`/`protected` (unusual, but not unreachable) has one the table finds but
      # `delimiter.respond_to?(...)` still cannot reach that way — EXCEPT Ruby routes a call Ruby cannot
      # dispatch normally (an absent method, or a private one reached with an explicit receiver) through
      # `method_missing` regardless of why the normal dispatch failed, so a caller-owned `method_missing` that
      # cooperates with an otherwise-unreachable `respond_to?` genuinely answers the probe (measured: a private
      # `respond_to?` alongside a `method_missing` that handles the `:respond_to?` message dispatches to
      # `method_missing`, not `NoMethodError`). DOUBTFUL in that case — axn cannot know whether the
      # `method_missing` actually cooperates — so DOUBT MUST ANSWER "usable" the same as every other hook here.
      # Only the absence of BOTH a public `respond_to?` AND a `method_missing` to catch the miss is CERTAIN
      # failure, readable without dispatch, and refused unconditionally (Codex, PR #288).
      #
      # A real, public, OWNED `respond_to?` is what Ruby dispatches `delimiter.respond_to?(:include?)` to —
      # `method_missing` is never consulted once a real method answers, so a zero-arg `def respond_to? =
      # true` (real, public, and — being arity-agnostic about WHAT it answers for — indistinguishable from a
      # correct one by every check above) is certain `ArgumentError`, regardless of whatever `method_missing`
      # might otherwise do (same precedence as `include?`/`cover?`/`call`, Codex, PR #288).
      #
      # A real, public `respond_to?` owned by `::Kernel` ITSELF (native, untouched) is a SPECIAL case within
      # that: its own C implementation is what runs `delimiter.respond_to?(:include?)`, and for any name
      # absent from the table it internally dispatches `respond_to_missing?(name, false)` — TWO args — before
      # answering. A caller-owned `respond_to_missing?` with the wrong arity (`def respond_to_missing? =
      # true`, missing the conventional `(name, include_all = false)` signature) is real, public, and answers
      # every ownership check here, and then breaks `check_validity!`'s VERY FIRST probe with `ArgumentError`
      # — before `usable_clusivity_delimiter?` ever reaches the dynamic-call-route question that reads this
      # same ownership (Codex, PR #288, fresh evidence after the prior hook-arity fix: "the current code
      # validates method_missing but never the owned respond_to_missing?"). Irrelevant when `respond_to?`
      # ITSELF is overridden (a non-`::Kernel` owner) — an override answers the probe on its own terms and
      # need not consult `respond_to_missing?` at all, which is not axn's to police (out of scope, the same
      # as every other caller-code behavior this file declines to simulate).
      def respond_to_reachable?(collection)
        if public_method_owner?(collection, :respond_to?)
          return false unless accepts_single_positional_arg?(collection, :respond_to?)
          return true unless Axn::Internal::NativeMethods.method_owner(collection, :respond_to?).equal?(::Kernel)
          return true unless own_respond_to_missing_hook?(collection)

          accepts_positional_args?(collection, :respond_to_missing?, 2)
        else
          method_missing_accepts?(collection, 2)
        end
      end

      # Whether `method_missing` — already established as the caller's own via `own_method_missing_hook?` —
      # can accept the EXACT positional argument count Ruby invokes it with for a given failed dispatch:
      # `method_missing(missed_name, *original_args)`, so a probe with `count` total arguments (the missed
      # name plus `count - 1` originals) is what a caller's `method_missing` must actually accept, not merely
      # exist. Every doubtful-hook fallback in this file needs this, one `count` per real call site:
      # `respond_to?(:include?)`'s fallback is `method_missing(:respond_to?, :include?)` (2); `is_a?`'s is
      # `method_missing(:is_a?, Range)` (2); `public_send`'s is `method_missing(:public_send, name, value)`
      # (3); `include?`/`cover?`'s is `method_missing(:include?/:cover?, value)` (2); Range `begin`/`end`'s is
      # `method_missing(:begin)`/`method_missing(:end)` (1, no originals); a literal Proc's `arity` fallback
      # is `method_missing(:arity)` (1) and its `call` fallback is `method_missing(:call)`/`method_missing(
      # :call, record)` (1 or 2, matching `proc_call_usable?`'s own count-per-branch). A `method_missing`
      # accepting fewer (`def method_missing(name) = ...`, a plausible authoring mistake, missing the
      # conventional `*args` splat) raises `ArgumentError` on that very dispatch, before the hook ever gets a
      # chance to answer (Codex, PR #288, across two rounds: the `respond_to?` fallback first, then every
      # other doubtful-hook fallback in the file, "this dynamic route still checks hook ownership without
      # checking that the hook accepts the missed name plus runtime argument").
      def method_missing_accepts?(collection, count)
        own_method_missing_hook?(collection) && accepts_positional_args?(collection, :method_missing, count)
      end

      # Whether `collection` is a literal Proc — by ANCESTRY, matching every other "is this a built-in
      # shape" classification in this file (Range, Array), never `is_a?`. `resolve_value`'s `case value; when
      # Proc` is `Module#===`, a C-level ancestry check that does not dispatch on the value either, so this
      # mirrors it exactly (the same reasoning `_parse_validates_options`'s own `case`/`when Range, Array`
      # earns the same treatment already documented on `native_bare_clusivity_delimiter?`).
      def literal_proc?(collection)
        Axn::Internal::NativeMethods.includes_module?(Axn::Internal::Identity.class_of(collection), ::Proc)
      end

      # `Proc#arity` itself, unbound — for reading a Proc's OWN true arity, never the caller's possibly
      # overridden version, the same "native reader over the caller's own" pattern `RANGE_BEGIN`/`RANGE_END`
      # already apply to a Range's bound: safe to bind and read (no caller code runs) ONLY once ownership
      # confirms `arity` is Ruby's own C implementation rather than a singleton override, exactly as that
      # pair are only trusted once `method_owner(collection, :begin/:end).equal?(::Range)` confirms the same.
      PROC_ARITY = ::Proc.instance_method(:arity)

      # Whether a literal Proc's dispatch actually succeeds. `resolve_value`'s Proc branch is `value.arity ==
      # 0 ? value.call : value.call(record)` — TWO calls, in order, BOTH with a receiver-explicit, undoubted
      # arity ActiveModel decides for itself rather than adapting to whatever `certainly_resolved_per_call?`
      # would otherwise assume:
      #
      #   1. `arity` is invoked with ZERO arguments, ALWAYS, to decide which branch to take. A real, public,
      #      OWNED `arity` requiring one is certain `ArgumentError` before `call` is ever reached — the
      #      generic prerequisite-arity treatment applied to a NEW prerequisite (Codex, PR #288).
      #   2. `call` is then invoked with EXACTLY the argument count that `arity` selects: zero if it answers
      #      zero, one otherwise — never "whichever, doubtfully" once `arity`'s value can be TRUSTED. `arity`
      #      is trustworthy precisely when its owner is confirmed `::Proc` itself (Ruby's own C accessor onto
      #      the Proc's internal arity, not a singleton override) — the same ownership-equality gate
      #      `range_cover_resolution` already applies before trusting `begin`/`end`'s VALUE, reused here for
      #      `arity`'s. Read via the bound native `PROC_ARITY`, never the caller's own (possibly overridden)
      #      `.arity`, so this never dispatches on the caller's object even while trusting the result.
      #      Matching the SELECTED count exactly — not "either" — is what a mismatched singleton (a zero-arity
      #      Proc with a one-arg singleton `call`, or the reverse) now correctly refuses: only ONE of the two
      #      branches `resolve_value` could take is ever reachable, and it must be the right one (Codex, PR
      #      #288: "validate only the argument count it selects; reserve the permissive result for an
      #      overridden reader whose value is genuinely unknowable").
      #   3. An OVERRIDDEN `arity` (real, correct-arity, but not `::Proc`'s own) leaves the selected count
      #      genuinely unknowable without dispatching the caller's override — DOUBT, so `call` is accepted
      #      reachable with EITHER count, matching every other undecidable case in this file (this is what
      #      let a zero-arity Proc with a matching zero-arg singleton `call` through in the first place,
      #      Codex, PR #288, the earlier singleton-narrowed-Proc finding).
      #
      # Every real-method check is real-method-first, method_missing-backed-only-as-fallback (with the exact
      # argument count `method_missing` would actually be invoked with — `method_missing(:arity)` for #1,
      # `method_missing(:call)`/`method_missing(:call, record)` for #2/#3), the same precedence and the same
      # hook-arity discipline as every other prerequisite in this file: a real method always wins Ruby's
      # dispatch, and a fallback hook must itself accept what it will be invoked with (Codex, PR #288).
      def proc_call_usable?(collection)
        arity_owner = Axn::Internal::NativeMethods.method_owner(collection, :arity)

        if arity_owner.nil?
          return false unless method_missing_accepts?(collection, 1)

          return call_reachable_with_either_arity?(collection)
        end

        return false unless Axn::Internal::NativeMethods.public_instance_method?(arity_owner, :arity)
        return false unless accepts_positional_args?(collection, :arity, 0)

        if arity_owner.equal?(::Proc)
          call_reachable_with_arg_count?(collection, PROC_ARITY.bind_call(collection).zero? ? 0 : 1)
        else
          call_reachable_with_either_arity?(collection)
        end
      end

      # `call` reachable with EXACTLY `count` positional arguments — real-method-first (any signature
      # accepting `count`), `method_missing`-backed as fallback with the EXACT total arity Ruby would invoke
      # it with for that call (`count` originals plus the `:call` message name itself).
      def call_reachable_with_arg_count?(collection, count)
        if public_method_owner?(collection, :call)
          accepts_positional_args?(collection, :call, count)
        else
          method_missing_accepts?(collection, count + 1)
        end
      end

      # `call` reachable with EITHER zero or one argument — for the cases where `arity`'s own selected count
      # cannot be trusted without dispatching the caller's object.
      def call_reachable_with_either_arity?(collection)
        call_reachable_with_arg_count?(collection, 0) || call_reachable_with_arg_count?(collection, 1)
      end

      # Whether ActiveModel's `Clusivity#check_validity!` would accept this as a delimiter AND the runtime
      # would actually dispatch it without raising — TWO questions, because they can disagree, and both must
      # clear for a declaration to be genuinely usable:
      #
      #   1. Would `check_validity!`'s `respond_to?(:include?) || respond_to?(:call) || respond_to?(:to_sym)`
      #      answer true? Mirrored by OWNERSHIP rather than by dispatching `respond_to?` on the caller's
      #      object. A collection carrying its own `respond_to_missing?` OR its own `respond_to?` is
      #      undecidable without running it — `respond_to?` is answered by whichever of the two the caller's
      #      class overrides, `respond_to_missing?` for the conventional hook, `respond_to?` itself when
      #      overridden directly — and DOUBT MUST ANSWER "usable" for THIS question alone: refusing it would
      #      refuse a declaration `check_validity!` might in fact accept.
      #   2. Would the ACTUAL member dispatch (`members.include?`/`.cover?` via `public_send`, or `.call` if
      #      `resolve_value` routes there first) reach something rather than raise `NoMethodError`? THIS is
      #      governed entirely by `method_missing` (or a real method) — `respond_to?`/`respond_to_missing?`
      #      participate in NEITHER `public_send`'s dispatch nor an ordinary `.call`, so a doubtful "yes" from
      #      question 1 is worthless here on its own: an object whose `respond_to_missing?` claims `:include?`
      #      with no `method_missing` to catch the actual call still raises `NoMethodError` on EVERY call, for
      #      CERTAIN — declares cleanly, breaks on every call, the shape this guard exists to close (Codex, PR
      #      #288). So a doubtful hook from question 1 only stands in for question 2 when `method_missing` is
      #      ALSO the caller's own.
      #
      # `method_missing` alone answers NEITHER question: it grants no doubt about question 1 (checked
      # explicitly, matches `own_respond_to_missing_hook?`'s own reasoning), so a collection overriding only
      # `method_missing`, with neither `respond_to?` hook overridden and nothing else real, is refused by the
      # final `return false` — `check_validity!` raises regardless of what `method_missing` would have done if
      # actually reached (measured).
      #
      # A real public `include?`/`call` answers BOTH questions on its own (certain, no hook needed either
      # way), which is why they short-circuit ahead of the hook checks. `to_sym` is different from both: a
      # genuinely public `to_sym` answers question 1 on its own (`respond_to?(:to_sym)` needs no doubtful hook
      # — it is really there), but says NOTHING about question 2, since `resolve_value` never calls `to_sym` at
      # all — it dispatches on `case value when Symbol` (`is_a?(Symbol)`, judged by IDENTITY via
      # `Identity.class_of`, never `is_a?`, since `Symbol` takes no subclass and so cannot be missed this way),
      # and a value that fails that falls through to `members = value` then `value.include?(record_value)`.
      # So a public `to_sym` alone still needs question 2 answered separately: certain via a real
      # `include?`/`call` (already covered above), or doubtful via `method_missing` (which is why it is
      # checked again at the very end, alongside the two `respond_to?` hooks it can stand in for once
      # `method_missing` backs it).
      #
      # A THIRD question, distinct from both above, only for a delimiter that reaches `members = value`
      # UNCHANGED (a Symbol/Proc/real-callable is resolved to something ELSE first, so neither question below
      # is about the declared object at all — see `enumerable_is_a_reachable?`/`public_send_reachable?`): would
      # `Clusivity#inclusion_method`'s `enumerable.is_a? Range` and `WholeValueClusivity#include?`'s
      # `members.public_send(...)` — both ORDINARY calls with an explicit receiver, dispatched on EVERY such
      # delimiter regardless of what it turns out to be — reach something rather than raise `NoMethodError`
      # before `include?`/`cover?` are ever consulted? Checked BEFORE `range_usable?` and the fallback branch,
      # since both calls happen ahead of either (Codex, PR #288, two more findings after the `is_a?`
      # classification fix: reachability is a different question from whether an override can be trusted).
      #
      # A FOURTH question, checked as an unconditional hard failure rather than falling through to the
      # `method_missing` fallback below: whenever a real, public, OWNED `call`/`include?` exists at all, Ruby
      # dispatches straight to it — `method_missing` is consulted only when normal dispatch finds NOTHING, so
      # a real method with the WRONG arity is a certain `ArgumentError`, never something a coincidental
      # `method_missing` elsewhere on the object could rescue (it would never be reached). So this is checked
      # before, and independent of, `own_method_missing_hook?` — unlike every doubtful hook above, there is no
      # doubt here to resolve in favor of usable (Codex, PR #288).
      #
      # A FIFTH question, prior to and gating the fourth: is it even CERTAIN which of the two routes
      # `resolve_value` takes at all? Its "else" branch asks `value.respond_to?(:call)` — an ordinary call
      # Ruby dispatches to WHICHEVER `respond_to?` the caller's class defines, same as `check_validity!`'s own
      # probe. A real public `call` makes that answer true FOR CERTAIN only when `respond_to?` ITSELF is
      # untouched (native `Kernel#respond_to?` checks the real method table first, so `respond_to_missing?`
      # is never even consulted for a name already present) — an overridden `respond_to?` governs the answer
      # just as completely as it does for `check_validity!`'s probe, and could hide a real `call` behind a
      # `false`, routing to `include?` instead (measured: a valid `include?`, a real but WRONG-arity `call`,
      # and a `respond_to?` override answering `false` for `:call` declares and enforces fine via `include?`
      # — the arity-mismatched `call` is never reached at all). Conversely, a doubtful `respond_to_missing?`/
      # `respond_to?` override backed by a cooperating `method_missing` (`dynamically_resolved_per_call?`)
      # can route to `.call` even with NO real `call` method at all, in which case `is_a?`/`public_send`
      # apply to WHATEVER `.call` returns, not to the original object — so a broken arity on the ORIGINAL
      # object's own `is_a?` is irrelevant (measured: a zero-arg `is_a?` on the delimiter itself, alongside a
      # `respond_to_missing?`+`method_missing` pair that supplies a real `.call` returning an Array, declares
      # and enforces fine — the original's `is_a?` is never dispatched).
      #
      # So the fourth question's "certain failure" only holds when routing is ALSO certain — the same
      # `own_respond_to_hook?` check `check_validity!`'s own probe already needs, reused here for a second
      # reason. And per the doubt-answers-usable doctrine that governs every other undecidable case in this
      # file, MERELY possible call routing (`dynamically_resolved_per_call?`, which already covers "real call
      # behind a lying `respond_to?`" as well as the doubtful-hook case) stands down rather than enforcing
      # either route's own arity requirements — checking one would refuse a declaration whose OTHER route is
      # what the runtime actually takes (Codex, PR #288).
      #
      # A SIXTH question, checked BEFORE any of the above and unconditionally for anything ancestry
      # classifies as a literal Proc: `resolve_value`'s `case value; when Proc` branch takes ABSOLUTE
      # precedence over the generic "else" — a Proc is NEVER routed through `respond_to?(:call)` at all, so
      # none of the routing-certainty reasoning above even applies to one. Delegated to `proc_call_usable?`.
      def usable_clusivity_delimiter?(collection)
        return false unless respond_to_reachable?(collection)
        return true if Axn::Internal::Identity.class_of(collection).equal?(::Symbol)
        return proc_call_usable?(collection) if literal_proc?(collection)

        return accepts_single_positional_arg?(collection, :call) if certainly_routed_to_call?(collection)
        return true if certainly_resolved_per_call?(collection)

        # A doubtful hook claiming `:call`, backed by `method_missing`, routes to `method_missing(:call,
        # record)` — TWO args — if it actually cooperates. A `method_missing` that cannot even accept that
        # shape (Codex, PR #288: "a one-argument method_missing(name)") is never checked again below (the
        # generic fallback needs the SAME two-argument shape for `:include?` instead), so falling through
        # rather than hard-rejecting here still reaches the right verdict either way.
        return true if (own_respond_to_missing_hook?(collection) || own_respond_to_hook?(collection)) && method_missing_accepts?(collection, 2)

        return false unless enumerable_is_a_reachable?(collection) && public_send_reachable?(collection)
        return true if range_usable?(collection)
        return false if public_method_owner?(collection, :include?) && !accepts_single_positional_arg?(collection, :include?)
        return false unless method_missing_accepts?(collection, 2)

        public_method_owner?(collection, :to_sym) || own_respond_to_missing_hook?(collection) || own_respond_to_hook?(collection)
      rescue StandardError
        true
      end

      # Whether `is_a?` can be DISPATCHED at all — `Clusivity#inclusion_method`'s `enumerable.is_a? Range` is
      # an ordinary call with an explicit receiver, made for EVERY delimiter that reaches `members = value`
      # unchanged, Range or not (Codex, PR #288: "before accepting either Range or non-Range delimiters"). A
      # private/undefined `is_a?` with no `method_missing` to catch the miss raises `NoMethodError` on the
      # first call, regardless of whether the object answers `include?` perfectly well. Distinct from
      # `own_is_a_hook?`, which asks whether an is_a? that CAN be dispatched is trustworthy for ancestry
      # classification — this asks only whether it can be dispatched AT ALL. A real, public, OWNED `is_a?`
      # always wins Ruby's dispatch over `method_missing`, so a zero-arg `def is_a? = false` is certain
      # `ArgumentError` regardless of whatever `method_missing` might otherwise do (Codex, PR #288).
      def enumerable_is_a_reachable?(collection)
        if public_method_owner?(collection, :is_a?)
          accepts_single_positional_arg?(collection, :is_a?)
        else
          method_missing_accepts?(collection, 2)
        end
      end

      # Whether `public_send` can be DISPATCHED at all — `WholeValueClusivity#include?` performs the actual
      # membership test as `members.public_send(inclusion_method(members), value)`, an ordinary call with an
      # explicit receiver, for every delimiter that reaches this point, Range or not. A private/undefined
      # `public_send` with no `method_missing` to catch the miss raises `NoMethodError` before the verified
      # `include?`/`cover?`/`to_sym` is ever reached, however public and however real (Codex, PR #288). Backed
      # by `own_method_missing_hook?` the same way every other unreachable-but-caught case here is: Ruby
      # routes a call it cannot dispatch normally through `method_missing` regardless of why normal dispatch
      # failed, so a caller-owned `method_missing` genuinely answers a `public_send` an ordinary lookup could
      # not reach. And, same precedence as every other real-method-first case here: a real, public, OWNED
      # `public_send` accepting fewer than the TWO arguments it is always called with (the method name plus
      # the value) is certain `ArgumentError`, `method_missing` notwithstanding (Codex, PR #288).
      def public_send_reachable?(collection)
        if public_method_owner?(collection, :public_send)
          accepts_positional_args?(collection, :public_send, 2)
        else
          method_missing_accepts?(collection, 3)
        end
      end

      # The native `Range#begin`/`#end` readers, unbound and bound per call — for reading a Range's OWN
      # stored bound, never the caller's possibly-overridden version, exactly the "native reader over the
      # caller's own" pattern `HASH_KEYS_READER` already applies to a Hash's keys. `inclusion_method` itself
      # would read the SAME value absent such an override, since `begin`/`end` are C-level accessors onto
      # Range's own internal state, not derived from anything a subclass typically recomputes.
      RANGE_BEGIN = ::Range.instance_method(:begin)
      RANGE_END = ::Range.instance_method(:end)

      # The bound types `Clusivity#inclusion_method` selects `cover?` for, guarded by `defined?` for the same
      # reason `Set` is guarded elsewhere in this file — axn works outside Rails, where `Time`/`DateTime`/
      # `Date` may not be loaded at all.
      RANGE_COVER_TYPES = [
        ::Numeric,
        (::Time if defined?(::Time)),
        (::DateTime if defined?(::DateTime)),
        (::Date if defined?(::Date)),
      ].compact.freeze

      # Resolves what `Clusivity#inclusion_method`'s `enumerable.begin || enumerable.end` would actually see,
      # evaluated in THE SAME short-circuit order: `.end` is asked AT ALL only when `.begin` answers falsy
      # (`nil`, for a beginless Range) — so `.end`'s reachability, ownership, and value are irrelevant
      # whenever `.begin` alone resolves the bound, and matter only when it doesn't. Treating the two
      # symmetrically (requiring both reachable, both reliable) gets this wrong in BOTH directions: it
      # refused a Range whose untouched `begin` alone decides the bound while `end` was narrowed to
      # private/undefined (never dispatched, so never a problem), and it silently accepted one whose
      # untouched, numeric `begin` alone decides the bound while an UNRELATED override on `end` made the
      # guard call the whole pair "unreliable" and skip the `cover?` requirement `begin`'s own real value
      # would have earned (Codex, PR #288, two more findings after the first "require both" pass).
      #
      # Returns one of:
      #   `:unreachable` — the read ActiveModel would try NEXT cannot be dispatched at all (no owner, no
      #                    `method_missing` to catch the miss) — CERTAIN failure, refuse regardless of
      #                    `cover?`/`include?`.
      #   `:undecidable` — the read succeeds, but through an OVERRIDE (or a `method_missing`), so the value it
      #                    returns cannot be safely determined without dispatching the caller's own code —
      #                    DOUBT, so no `cover?` requirement either way.
      #   `:cover`       — resolved, via a NATIVE (trustworthy) read, to a bound `Clusivity#inclusion_method`
      #                    selects `cover?` for (`Numeric`/`Time`/`DateTime`/`Date`).
      #   `:no_cover`    — resolved, via a NATIVE read, to any other bound (including both `begin` and `end`
      #                    answering `nil`, which `inclusion_method` itself would then also route to
      #                    `include?`).
      #
      # A REAL method, of ANY owner, is checked for arity BEFORE the ownership-equal-`::Range` read below:
      # `enumerable.begin`/`.end` are called with ZERO arguments, and a real method requiring one — overridden
      # by anything, not necessarily maliciously — is refused as `:unreachable` REGARDLESS of who owns it,
      # the same "a real method always wins dispatch over `method_missing`" precedence applied everywhere
      # else in this file. This is decidable from the method table alone, unlike the VALUE such an override
      # would return, which is what the ownership-equal-`::Range` check below still exists to gate (Codex, PR
      # #288).
      def range_cover_resolution(collection)
        %i[begin end].each do |name|
          if public_method_owner?(collection, name)
            return :unreachable unless accepts_positional_args?(collection, name, 0)
          else
            return :unreachable unless method_missing_accepts?(collection, 1)
          end
          return :undecidable unless Axn::Internal::NativeMethods.method_owner(collection, name).equal?(::Range)

          value = name.equal?(:begin) ? RANGE_BEGIN.bind_call(collection) : RANGE_END.bind_call(collection)
          next if value.nil? && name.equal?(:begin)

          return(case value
                 when *RANGE_COVER_TYPES then :cover
                 else :no_cover
                 end)
        end

        :no_cover
      end

      # Whether `collection` is usable via a real public `include?` — REQUIRED UNCONDITIONALLY, Range or not:
      # `check_validity!`'s `respond_to?(:include?) || respond_to?(:call) || respond_to?(:to_sym)` gate never
      # looks at `cover?` at all, so a private `include?` fails `check_validity!` regardless of what bound the
      # Range has or whether `cover?` is public — a Range gets NO exemption from the ordinary requirement
      # every other collection already has here.
      #
      # For a Range (by ANCESTRY, ordinarily — see the `is_a?` stand-down below) whose bound is
      # `Numeric`/`Time`/`DateTime`/`Date`, `cover?` is an ADDITIONAL requirement ON TOP of `include?`, never
      # a substitute for it: `check_validity!` passes on `include?` alone, but `Clusivity#inclusion_method`
      # then selects `cover?` for that bound, and `WholeValueClusivity#include?` dispatches it with
      # `public_send` — so a Range SUBCLASS with a real public `include?` but an undefined/private `cover?`
      # still declares cleanly and raises `NoMethodError` on every call whose bound is numeric/time-like
      # (Codex, PR #288). A Range whose bound does NOT select `cover?` needs no such extra requirement at
      # all — refusing it there would refuse a declaration ActiveModel and the runtime both accept, the same
      # finding's other half.
      #
      # `range_cover_resolution` gates the reachability question BEFORE any of that: `inclusion_method` must
      # read the bound before it can decide anything, so a Range whose `begin` (or `end`, only when `.begin`
      # is falsy) cannot be dispatched at all is refused regardless of what `include?`/`cover?` look like —
      # that read is what raises, not the membership dispatch this method otherwise reasons about.
      #
      # `cover?` itself is required PUBLIC-OR-method_missing-caught, not public-only: unlike `include?`/`call`/
      # `to_sym`, `check_validity!` never probes `respond_to?(:cover?)` at all — `cover?` only matters for the
      # ACTUAL dispatch (`public_send`, which reaches `method_missing` regardless of any `respond_to?` hook
      # cooperating) once `inclusion_method` has already selected it, so `own_method_missing_hook?` alone is
      # sufficient here, with no `respond_to?`/`respond_to_missing?` override needed to back it (Codex, PR
      # #288 — a genuine difference from every other doubtful hook in this file, which all gate on
      # `respond_to?` being asked first).
      #
      # ANCESTRY classifies "is this a Range" everywhere else in this file — established once through
      # `Identity.class_of`/`includes_module?` and never by dispatching `is_a?` on the caller's object, same
      # as every other classification here. But `inclusion_method` does not ask ancestry: `enumerable.is_a?
      # Range` is a REAL call, and a caller who overrides it governs what the runtime actually branches on,
      # not what its ancestry says. Measured: a Range subclass overriding `is_a?` to answer `false` for
      # `Range`, with `cover?` undefined, declares against `include?` alone and validates cleanly under real
      # ActiveModel — `inclusion_method` never reaches the numeric bound, `cover?`, or the requirement below
      # at all, because its own `is_a? Range` check is the thing that decided not to. Ancestry alone would
      # still call this a Range and require `cover?` (Codex, PR #288). `own_is_a_hook?` catches this the same
      # way every other doubtful hook here is caught: OWNERSHIP, never dispatch. Doubt answers "usable" for
      # the same reason `range_cover_resolution`'s own `:undecidable` branch does — an overridden `is_a?`
      # could in principle still answer exactly as ancestry does, in which case standing down costs a
      # `cover?` requirement that was genuinely earned, but requiring it anyway costs certain, immediate
      # rejection of a declaration ActiveModel actually accepts, which is the one error this guard exists to
      # rule out.
      #
      # Whether `is_a?` ITSELF is the caller's own, distinct from every other dispatch hook this file checks
      # ownership of. `Clusivity#inclusion_method` classifies its argument with `enumerable.is_a? Range` — a
      # REAL call, dispatched on the collection exactly as written, not a question about its ancestry — so an
      # override answering `false` for a genuine Range subclass (or `true` for something that is not one) is
      # what the runtime actually consults, and `range_usable?` classifying by ANCESTRY alone (deliberately,
      # see below) can disagree with it in either direction. Ownership only, never dispatched, for the same
      # reason every other hook here is: running `is_a?` on the caller's object to find out is the one thing
      # this predicate exists to avoid needing.
      def own_is_a_hook?(collection)
        owner = Axn::Internal::NativeMethods.method_owner(collection, :is_a?)
        owner && NATIVE_DISPATCH_HOOK_OWNERS.none? { |native| native.equal?(owner) }
      end

      def range_usable?(collection)
        return false unless public_method_owner?(collection, :include?)

        klass = Axn::Internal::Identity.class_of(collection)
        # `include?` is unconditionally what `inclusion_method` selects for anything outside Range ancestry
        # — never `cover?` — so its arity must clear here, on THIS path, rather than at the caller's own
        # top-level check (Codex, PR #288: deferred below for the reason this early return exists at all).
        return accepts_single_positional_arg?(collection, :include?) unless Axn::Internal::NativeMethods.includes_module?(klass, ::Range)
        return true if own_is_a_hook?(collection)

        case range_cover_resolution(collection)
        when :unreachable then false
        when :cover
          # A real, public, OWNED `cover?` is what Ruby dispatches to, unconditionally — `method_missing` is
          # never consulted once a real method answers, so a WRONG arity there is certain failure regardless
          # of whatever `method_missing` might otherwise do (same precedence `usable_clusivity_delimiter?`
          # applies to `include?`/`call`, Codex, PR #288). `include?`'s own arity is IRRELEVANT here:
          # `inclusion_method` selected `cover?`, and `include?` is never dispatched at all — a numeric-bounded
          # Range with a zero-arg `include?` and a correct `cover?` declares and enforces fine, since the
          # broken `include?` is never reached (Codex, PR #288: "the arity requirement should apply only when
          # include? is the selected membership method").
          if public_method_owner?(collection, :cover?)
            accepts_single_positional_arg?(collection, :cover?)
          else
            method_missing_accepts?(collection, 2)
          end
        when :no_cover
          # `:no_cover` is resolved via a NATIVE (trustworthy) read — `inclusion_method` is CERTAIN to select
          # `include?` here, never `cover?`, so `include?`'s own arity governs (Codex, PR #288, same
          # reasoning as the non-Range early return above — deferred here rather than left to the caller's
          # top-level check, which cannot tell `:no_cover` apart from `:cover`).
          accepts_single_positional_arg?(collection, :include?)
        else true # :undecidable — the bound itself is unreadable, so which method gets selected is UNKNOWN;
          # doubt answers usable here for the same reason `own_is_a_hook?` above does, not the certain
          # dispatch `:no_cover` earns.
        end
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
      #
      # EXEMPT when `dynamically_resolved_per_call?` is true: `resolve_value`'s `else` branch checks
      # `respond_to?(:call)` BEFORE anything ever reaches `include?`, so a String subclass ActiveModel would
      # route to `.call` — certainly, through a real public `call`, or doubtfully, through a cooperating
      # `respond_to?`/`respond_to_missing?` + `method_missing` pair — is resolved through that `call`, never
      # through its own inherited substring `include?` at all. Refusing it here would refuse a declaration
      # ActiveModel and the runtime both accept, which is the one error this guard may not make (Codex, PR
      # #288, twice: a real `call` first, then a dynamically dispatched one).
      def string_keyed_delimiter?(collection)
        return false if dynamically_resolved_per_call?(collection)

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

      # Whether `collection` is an Array or a Range (by ANCESTRY, never `is_a?`) — the two shapes ActiveModel's
      # OWN `_parse_validates_options` already routes a BARE delimiter to `{ in: … }` for, natively, with no
      # help from axn's canonicalization. Their aliasing property (a caller who still holds the object can
      # mutate it, changing an already-declared validator's membership) is consequently PRE-EXISTING, ordinary
      # ActiveModel behavior that predates axn's involvement in this area entirely — sometimes even relied on
      # intentionally for a dynamically-changing allow-list — and not a gap `usable_clusivity_delimiter?`
      # opened, so it is out of scope for the aliasing rule below.
      def native_bare_clusivity_delimiter?(collection)
        klass = Axn::Internal::Identity.class_of(collection)
        Axn::Internal::NativeMethods.includes_module?(klass, ::Array) ||
          Axn::Internal::NativeMethods.includes_module?(klass, ::Range)
      end

      # A delimiter `usable_clusivity_delimiter?` accepts by OWNERSHIP — a Set SUBCLASS, or any other object
      # answering `include?` (really, or through a doubtful hook) — is stored as the declaration's OWN
      # membership set, by reference, once it reaches here. The SAME aliasing rule `reject_unreadable_mutable_
      # container!` already applies to a Hash-keyed container applies for the SAME reason: a caller who still
      # holds this object could mutate it after declaring, changing an already-declared class's membership
      # retroactively (PRO-3326 widened bare acceptance to exactly the shapes this reopens — a Set subclass or
      # a custom `include?`-answering object that used to raise on every call now declares cleanly and stores
      # itself unguarded).
      #
      # EXEMPT when `certainly_routed_to_call?` (a Proc/lambda's behavior cannot be mutated after creation the
      # way a container's elements can, matching the Hash-keyed branch's own exemption — and CERTAINLY, not
      # merely a real `call` in the table, since an overridden `respond_to?` can route dispatch through a
      # mutable `include?` instead, Codex, PR #288) or `native_bare_clusivity_delimiter?` (an Array or Range,
      # whose aliasing is ActiveModel's own pre-existing property, not this guard's to police). A Symbol is
      # always frozen (Ruby gives every Symbol one object per name), so it clears the check below without
      # needing a special case either.
      def reject_unfrozen_clusivity_delimiter!(collection, key, where)
        return if Axn::Internal::NativeMethods.frozen?(collection)

        raise ArgumentError,
              "#{key}: on #{where} names a set of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(collection)} that is not " \
              "frozen. A declared contract is axn's own, so mutating what you still hold after declaring it " \
              "could change its membership retroactively. Freeze this object before naming it as a delimiter " \
              "(a frozen one is stored as-is, since nothing can mutate it afterwards)."
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
            reject_unreadable_mutable_container!(entry, key, where) unless certainly_routed_to_call?(entry)
            return { in: entry }
          end

          reject_unusable_clusivity_delimiter!(entry, key, where) unless usable_clusivity_delimiter?(entry)
          reject_string_clusivity_delimiter!(entry, key, where) if string_keyed_delimiter?(entry)
          reject_unfrozen_clusivity_delimiter!(entry, key, where) unless certainly_routed_to_call?(entry) || native_bare_clusivity_delimiter?(entry)

          return { in: entry }
        end

        set_key = declared_set_key(options, keys: CLUSIVITY_SET_KEYS)
        reject_missing_clusivity_delimiter!(key, where) if set_key.nil?

        collection = options[set_key]
        members = hash_keyed_set_members(collection)
        return options.merge(set_key => members) if members

        if hash_keyed_container?(collection)
          reject_unreadable_mutable_container!(collection, key, where) unless certainly_routed_to_call?(collection)
          return entry
        end

        reject_unusable_clusivity_delimiter!(collection, key, where) unless usable_clusivity_delimiter?(collection)
        reject_string_clusivity_delimiter!(collection, key, where) if string_keyed_delimiter?(collection)
        unless certainly_routed_to_call?(collection) || native_bare_clusivity_delimiter?(collection)
          reject_unfrozen_clusivity_delimiter!(collection, key, where)
        end

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
