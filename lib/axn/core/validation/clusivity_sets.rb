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
      # One ActiveModel resolves per call stands down as well: `resolve_value` calls anything answering `call`,
      # so a container given a singleton `call` is compared against what that returns, not against its members.
      # Asked with ActiveModel's own question, `respond_to?(:call)`, and only once the exact class is known.
      #
      # THE single definition of "which members can be judged", shared by the nil-membership judgment below and
      # by the declaration-time satisfiability guard, so the two cannot read one declaration differently.
      def literal_set_members(opt, keys: %i[in within])
        collection = declared_set_collection(opt, keys:)
        hash = Axn::Internal::Identity.class_of(collection).equal?(::Hash)
        return nil unless hash || literal_set_collection?(collection)
        return nil if collection.respond_to?(:call)

        hash ? HASH_KEYS_READER.bind_call(collection) : collection
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

      # ONE clusivity entry, canonicalized. The bare shorthand becomes the long form its members belong in:
      # ActiveModel's `_parse_validates_options` maps only a Range or an Array to `{ in: }` and everything else
      # to `{ with: }`, which reaches `check_validity!` with no delimiter and raises on every call — so every
      # bare delimiter ActiveModel could otherwise use (a Proc, a Symbol, a plain `include?`-answering object,
      # a Set subclass) is wrapped into the long form here, exactly as the Set/Hash case already was
      # (PRO-3319). One that ActiveModel could never use, in either spelling, is refused instead (PRO-3326).
      #
      # The entry is returned unchanged — by identity, which is how the caller knows not to write — whenever
      # there is nothing to rewrite: a long form already naming a usable set.
      def canonical_clusivity_entry(entry, key: :inclusion, where: nil)
        options = Axn::Internal::ShapeGraph.hash_or_nil(entry)

        if nil.equal?(options)
          members = hash_keyed_set_members(entry)
          return { in: members } if members

          canonical = { in: entry }
          set_key = :in
        else
          set_key = declared_set_key(options, keys: CLUSIVITY_SET_KEYS)
          reject_missing_clusivity_delimiter!(key, where) if set_key.nil?

          members = hash_keyed_set_members(options[set_key])
          return options.merge(set_key => members) if members

          canonical = entry
        end

        reject_unusable_clusivity_delimiter!(canonical, set_key, key, where)
        canonical
      end

      # The refusals a clusivity delimiter earns at declaration, each one a shape that would otherwise define
      # the class cleanly and then raise, or quietly change, on every call:
      #
      #   1. ActiveModel's own `check_validity!` rejects it. Asked by BUILDING the validator the declaration
      #      will use (`Base.build_validator`), which is exactly what `validates` does in any model's class
      #      body, rather than by predicting what that check would answer.
      #   2. The method ActiveModel will dispatch it through cannot take the argument ActiveModel hands it — the
      #      one shape `check_validity!` cannot see, since it asks only whether a method EXISTS.
      #   3. It answers membership with String's own `include?`, a substring test.
      #   4. It is a mutable object stored by reference, so mutating what the caller still holds would change an
      #      already-declared contract.
      def reject_unusable_clusivity_delimiter!(options, set_key, key, where)
        delimiter = options[set_key]
        reason = unusable_delimiter_reason(delimiter, options, key)
        raise ArgumentError, unusable_delimiter_message(delimiter, key, where, reason) if reason

        reject_string_clusivity_delimiter!(delimiter, key, where) if substring_membership?(delimiter)
        reject_aliased_clusivity_delimiter!(delimiter, key, where)
      end

      # Why ActiveModel cannot use this delimiter (refusals 1 and 2 above), or nil when it can.
      def unusable_delimiter_reason(delimiter, options, key)
        begin
          validator = build_validator(clusivity_validator_class(key), options)
        rescue StandardError => e
          return "building its validator raises `#{e.class}: #{e.message}`"
        end

        method_name, count = delimiter_dispatch_mismatch(delimiter, validator)
        return nil unless method_name

        "its `#{method_name}` cannot take the #{count} argument#{'s' unless count == 1} ActiveModel passes it, so " \
          "every call raises `ArgumentError: wrong number of arguments`"
      end

      # axn's own validator classes rather than ActiveModel's (`Validation::Base::InclusionValidator`), since
      # those are what the declaration actually compiles to.
      def clusivity_validator_class(key)
        key == :exclusion ? Axn::Validators::ExclusionValidator : Axn::Validators::InclusionValidator
      end

      # The method ActiveModel will dispatch this delimiter through, and the argument count it passes, when the
      # delimiter's own signature cannot accept that count — or nil when it can, or when there is nothing to
      # check. `resolve_value` runs a Proc as `arity.zero? ? call : call(record)` and any other callable as
      # `call(record)`; everything else is handed the value through whichever of `include?`/`cover?` the
      # validator's own `inclusion_method` selects (`cover?` for a numeric or time-bounded Range), asked of the
      # validator just built rather than re-derived here.
      #
      # A Symbol names an action method that may be defined later in the class body, so it is not checked. A
      # non-lambda Proc drops or pads positional arguments on its own, so only a required keyword breaks one.
      # Doubt permits: a method this cannot read the signature of (`method` raising, say, for one answered
      # through `method_missing`) is left to the runtime rather than refused.
      def delimiter_dispatch_mismatch(delimiter, validator)
        name, parameters, count, lenient =
          case delimiter
          when ::Symbol then return nil
          when ::Proc then [:call, delimiter.parameters, delimiter.arity.zero? ? 0 : 1, !delimiter.lambda?]
          else
            if delimiter.respond_to?(:call)
              # A bound `Method`'s own `call` is always `(*args)`; the signature that decides is its target's.
              [:call, (delimiter.is_a?(::Method) ? delimiter : delimiter.method(:call)).parameters, 1, false]
            else
              selected = validator.send(:inclusion_method, delimiter)
              [selected, delimiter.method(selected).parameters, 1, false]
            end
          end

        [name, count] unless parameters_accept?(parameters, count, lenient:)
      rescue StandardError
        nil
      end

      # Whether a method with these `parameters` can be called with exactly `count` positional arguments and
      # no keywords. A `:rest` removes the upper bound but never excuses a `:req` left unsupplied.
      def parameters_accept?(parameters, count, lenient: false)
        return false if parameters.any? { |type, _| type == :keyreq }
        return true if lenient

        required = parameters.count { |type, _| type == :req }
        return required <= count if parameters.any? { |type, _| type == :rest }

        required <= count && count <= required + parameters.count { |type, _| type == :opt }
      end

      # A delimiter stored as the declaration's own membership set, by reference, must be one the caller
      # cannot mutate afterwards: appending `2` to a set the caller still holds would make a value the contract
      # rejected start passing, on an already-declared class. Two shapes are exempt, and the rest must be
      # frozen:
      #
      #   * One ActiveModel resolves per call (`resolve_value` calls anything answering `call`, a Proc
      #     included): what it compares against is decided by that call, not held in the object.
      #   * An Array or a Range (`native_bare_clusivity_delimiter?`).
      #
      # A hash-keyed container arrives here only when it carries code of its own (one without is read out into
      # its members instead), so it is judged by `reject_unreadable_mutable_container!`, whose message names
      # why its members could not simply be copied.
      def reject_aliased_clusivity_delimiter!(delimiter, key, where)
        return if delimiter.respond_to?(:call)

        if hash_keyed_container?(delimiter)
          reject_unreadable_mutable_container!(delimiter, key, where)
        elsif !native_bare_clusivity_delimiter?(delimiter)
          reject_unfrozen_clusivity_delimiter!(delimiter, key, where)
        end
      end

      # Whether `collection` is an Array or a Range (by ANCESTRY, never `is_a?`) — the two shapes whose
      # membership cannot change after declaring even though axn stores neither frozen. An Array, subclasses
      # included, is copied by the option detachment (`ShapeGraph.detach_option_containers!`) before it is
      # stored, so mutating the caller's object leaves the declared copy alone (measured). A Range has no
      # mutators: its bounds are fixed at construction, and a literal one is frozen besides.
      def native_bare_clusivity_delimiter?(collection)
        klass = Axn::Internal::Identity.class_of(collection)
        Axn::Internal::NativeMethods.includes_module?(klass, ::Array) ||
          Axn::Internal::NativeMethods.includes_module?(klass, ::Range)
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

      # Any other mutable delimiter — a Set SUBCLASS, or an object answering `include?` with code of its own —
      # under the same rule. "Nothing can mutate it afterwards" means the object's OWN state, which is what
      # `frozen?` has ever meant in Ruby: a frozen wrapper whose `include?` reads a still-mutable Array it does
      # not own is as aliasable as `[h].freeze` is over `h`, and closing that would mean deep-freezing an
      # arbitrary object graph or running the caller's `include?` to find out.
      def reject_unfrozen_clusivity_delimiter!(collection, key, where)
        return if Axn::Internal::NativeMethods.frozen?(collection)

        raise ArgumentError,
              "#{key}: on #{where} names a set of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(collection)} that is not " \
              "frozen. A declared contract is axn's own, so mutating what you still hold after declaring it " \
              "could change its membership retroactively. Freeze this object before naming it as a delimiter " \
              "(a frozen one is stored as-is, since nothing can mutate it afterwards)."
      end

      # No delimiter at all: a long-form entry naming neither `in:` nor `within:` a TRUTHY value (an empty
      # Hash, one carrying only `message:`/`if:`/…, or one whose only size key is falsy) reaches
      # `check_validity!` with `delimiter` resolved to `nil`, which answers none of `include?`/`call`/`to_sym`
      # and raises ActiveModel's own `ArgumentError` on EVERY call — reported separately from an unusable
      # delimiter because there is no offending VALUE to describe.
      def reject_missing_clusivity_delimiter!(key, where)
        raise ArgumentError,
              "#{key}: on #{where} names no set at all — neither `in:` nor `within:` carries a value. " \
              "Declared, the class defines cleanly and every call raises ActiveModel's own `ArgumentError: An " \
              "object with the method #include? or a proc, lambda or symbol is required, and must be supplied " \
              "as the :in (or :within) option of the configuration hash` from Clusivity#check_validity! " \
              "instead. Name the set: an Array or Range of members, a Symbol naming an action method that " \
              "returns one, or a Proc/lambda called with the record."
      end

      # Described BY CLASS, never by `inspect`: this is an error-reporting path over the caller's own value.
      def unusable_delimiter_message(delimiter, key, where, reason)
        "#{key}: on #{where} names a set of class " \
          "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(delimiter)}, which ActiveModel " \
          "cannot use — #{reason}. Declared, the class would define cleanly and every call would raise " \
          "instead. Name an Array or Range of members, a Set or Hash (whose keys are read as members), a " \
          "Symbol naming an action method that returns a collection, or a Proc/lambda called with the record."
      end

      # Whether ActiveModel would decide membership with String's own `include?` — a String, or a subclass that
      # inherits it (`ActiveSupport::SafeBuffer`, which `"12".html_safe` returns), and that `resolve_value`
      # does not route through a `call` first. Asked of the `include?` the delimiter actually answers with
      # (`Method#owner`), so a subclass giving itself a membership test of its own is left alone.
      def substring_membership?(delimiter)
        Axn::Internal::Identity.kind?(delimiter, ::String) && !delimiter.respond_to?(:call) &&
          delimiter.method(:include?).owner.equal?(::String)
      rescue StandardError
        false
      end

      # A String delimiter declares cleanly (a String answers `include?`, so `check_validity!` accepts it) and
      # is not a membership set at all: `String#include?` is a SUBSTRING test, and raises `TypeError` for any
      # value that is not itself a String. So `type: Integer, inclusion: { in: "12" }` would raise on every
      # call.
      def reject_string_clusivity_delimiter!(collection, key, where)
        raise ArgumentError,
              "#{key}: on #{where} names a String as its set (of class " \
              "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(collection)}). A String " \
              "answers membership by SUBSTRING, and raises `TypeError` for any value that is not itself a " \
              "String — so declared, the class defines cleanly and every call raises unless the field's own " \
              "value is a String. Name the members instead (`%w[a b c]`), or use `format:` for a " \
              "substring/pattern check."
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
