# frozen_string_literal: true

require "axn/internal/identity"
require "axn/internal/native_methods"
# An `only_integer:` string branch carries ActiveModel's integer test through this module's translation.
require "axn/internal/reflection/pattern"
require "axn/internal/reflection/schema/vocabulary"

module Axn
  module Internal
    module Reflection
      module Schema
        # What a `numericality:` entry does to the node its position emits: the Number-or-numeric-String union it
        # types an untyped input as, and the per-branch narrowing every typed node goes through — which branches no
        # Numeric can occupy, which retag to "integer", and which carry the integer-literal pattern. Also the two
        # token questions the numeric bounds share with it (does a JSON integer reach a declared token; does a
        # declared numeric serialize exactly).
        module Numericality
          include Vocabulary

          # Inbound, `numericality:` alone admits a Number or a numeric String (a Number only under `only_numeric:`),
          # so it types the node as that union and lets the union's own narrowing say which Strings and which
          # Numbers pass. Typing it `"number"` rejected the `"5"` the validator parses.
          def numericality_input_node(validations, numericality)
            only_numeric = Axn::Validation::Base.validator_entry_options(numericality)[:only_numeric]
            tokens = only_numeric ? [::Numeric] : [::Numeric, ::String]
            type_hashes = tokens.map { |k| single_type_for(k, for_output: false) }.uniq
            node = type_hashes.size == 1 ? type_hashes.first : { anyOf: type_hashes }
            narrow_node_under_numericality(node, validations, tokens)
          end

          # A `numericality:` entry reaches a node's branches four different ways, and each is decided from the
          # DECLARED token rather than from the emitted type alone — reading the type alone retagged branches no
          # value of the declared class can occupy.
          #
          #   a non-numeric type  drops, under EVERY spelling of the validator. `is_number?` runs before any
          #                       option is read, so no Array, Hash or boolean can satisfy it.
          #   a "number" branch   narrows to "integer" under `only_integer:`, and only where some declared token
          #                       ADMITS an Integer (`Numeric` does; `Float` does not). Retagging a Float branch
          #                       advertised the JSON integer `2`, which `is_a?(Float)` rejects — and no Float
          #                       satisfies `only_integer:` anyway (`2.0.to_s` is "2.0"), so the branch is
          #                       unreachable and drops out.
          #   a "string" branch   drops under `only_numeric:`, which demands a Numeric OBJECT. Otherwise it stays
          #                       — the validator parses a numeric STRING — and carries ActiveModel's own integer
          #                       test translated where `only_integer:` gives it one, so `"2"` passes where `"abc"`
          #                       does not and leaving the branch unconstrained advertised both.
          #   anything else       is left exactly as built.
          #
          # Narrowing both branches of `[Integer, Float]` converges them, so the node collapses; deduping is a
          # CONSEQUENCE of that convergence and never a tidy-up of its own, so a union that narrows nothing comes
          # back untouched, duplicate branches included.
          def narrow_node_under_numericality(node, validations, tokens)
            entry = Axn::Validation::Base.validator_entries(validations)[:numericality]
            return node unless entry

            # The ENTRY's presence is the whole gate, and the two options below decide only what they alone can.
            # ActiveModel asks `is_number?` before it reads any option, and `only_numeric:` is one more restriction
            # INSIDE that check rather than the thing that establishes it — so no spelling of the validator can be
            # satisfied by a value that does not parse as a number, and a branch naming such values is unreachable
            # under all of them. Gating the pass on the options instead left the branch standing wherever neither
            # was given: `type: [TrueClass, Integer], numericality: true` accepts neither boolean and advertised
            # both. What the options still decide is the string branch (`only_numeric:` alone can drop it) and the
            # retag of a numeric branch to "integer" (`only_integer:`).
            # Resolved across BOTH tiers, the way `validates` builds a validator's options
            # (`defaults.merge(_parse_validates_options(options))`): a declaration-level `optional:`/`allow_blank:`
            # is recorded once on the declaration rather than copied into each entry, so an entry-only read answers
            # a field's tolerance wrongly. Every other tolerance judgment here goes through this same seam
            # (`presence_rejects_blank?`, `declared_size_minimum`), which is what keeps the branch and the size
            # floor from disagreeing about one declaration.
            options = Axn::Validation::Base.effective_entry_options(entry, Axn::Validation::Base.shared_validation_options(validations))
            only_integer = Axn::Validation::Base.declared_only_integer?(entry)
            numeric_only = options[:only_numeric] ? true : false
            # A tolerated BLANK never reaches the validator at all — ActiveModel skips a blank value before
            # `is_number?` runs — so a branch the numeric check excludes may still be occupied by its own blank,
            # and dropping it outright refused output the action produced (`type: :boolean, numericality:
            # { allow_blank: true }` exposes `false` successfully). Read off the options resolved above, so the
            # declaration-level `optional:` and an entry's own `allow_blank:` are covered by one read. Truthiness is
            # the whole test, exactly as it is for `only_numeric:` — ActiveModel reads `options[:allow_blank]` truthily
            # rather than resolving it per call, so a Proc tolerates a blank on every call.
            blank_tolerated = options[:allow_blank] ? true : false
            # Skipping the validator is only half of it: the value still has to get PAST the position. A required
            # position rejects an empty container on its own, so `type: [Array, Integer], numericality:
            # { allow_blank: true }` admits no `[]` however blank-tolerant the entry is, and treating the entry's
            # tolerance as the whole answer emitted a branch nothing satisfies (`enum: [[]]` beside the `minItems: 1`
            # the same declaration writes). This is the very predicate the size FLOOR is derived from, so the branch
            # and the floor cannot disagree about one declaration. It governs the EMPTY witnesses only — `false` is
            # blank without being empty, which is why a required `:boolean` really does expose it.
            empty_rejected = empty_value_rejected?(validations)

            union = node[:anyOf].is_a?(Array)
            admits = integer_admitted_by?(tokens)
            branches = union ? node[:anyOf] : [node]
            # A branch may only be DROPPED where the declared tokens prove no Numeric can occupy the position.
            # See `numeric_reachable_through_broad_token?` — the emitted type is not evidence on its own.
            drop = !numeric_reachable_through_broad_token?(tokens)
            mapped = branches.filter_map do |branch|
              numericality_branch(branch, admits, numeric_only:, only_integer:, drop:, blank_tolerated:,
                                                  empty_rejected:)
            end
            # Every branch dropping is the CONTRACT, not a case to fall back from: `type: Float, numericality:
            # { only_integer: true }` admits nothing at all — no Float's `to_s` is an integer literal, and a JSON
            # integer is not a Float — so restoring the node advertised `1.5` at a position that rejects it. A node
            # nothing satisfies is the faithful projection here, on the same terms two disagreeing `equal_to:`
            # bounds already emit `enum: []`. Refusing the declaration outright stays PRO-3220's.
            return { enum: EMPTY_ENUM } if mapped.empty?
            return node if mapped == branches

            deduped = mapped.uniq
            return deduped.first if deduped.size == 1

            union ? node.merge(anyOf: deduped) : node
          end

          # What each narrowing does to ONE branch. `only_numeric:` is the blunter of the two: it makes ActiveModel
          # demand a Numeric OBJECT rather than parse anything, so every branch naming values that are not Numerics
          # is unreachable — a string branch (the one that existed to carry `"2"`), and equally an array, object or
          # boolean branch, each measured as rejected. `only_integer:` is the finer one, retagging a numeric branch
          # and translating ActiveModel's integer test onto a string branch that survived.
          #
          # The `"null"` branch is exempt from both, and not by omission: NULLABILITY owns it. ActiveModel skips a
          # nil before any validator sees it wherever the field tolerates one, so neither option says anything
          # about nil — measured, `type: [String, Integer, NilClass], numericality: { only_numeric: true },
          # optional: true` accepts nil while rejecting every String.
          # Whether some declared token is a SUPERTYPE of Numeric — `Object`, `Comparable`, `Kernel`. Such a token
          # admits a Numeric value while `single_type_for` renders it APPROXIMATELY (`type: Object` emits a
          # `"string"` branch), so that branch's emitted type says nothing about what the position holds, and
          # dropping it as "names non-Numerics" emptied a contract `1` satisfies: `type: Object, numericality:
          # { only_numeric: true }` went to `enum: []` while accepting the Integer.
          #
          # The same lesson as the untyped branch above, one step further: an ABSENT type is not evidence, and
          # neither is an APPROXIMATE one. A token that is itself numeric is excluded — it emits a numeric branch,
          # which this pass narrows rather than drops.
          def numeric_reachable_through_broad_token?(tokens)
            tokens.any? do |token|
              next false unless Internal::Identity.kind?(token, ::Module)

              Internal::NativeMethods.includes_module?(::Numeric, token) &&
                !Internal::NativeMethods.includes_module?(token, ::Numeric)
            end
          end

          def numericality_branch(branch, admits_integer, numeric_only:, only_integer:, drop: true, blank_tolerated: false,
                                  empty_rejected: false)
            # A branch `only_numeric:` may drop is one whose emitted type NAMES values that are not Numerics.
            # Everything else is left exactly as built — including the `"null"` branch nullability owns, a branch
            # already tagged `"integer"`, and any branch whose type is ABSENT. That last is load-bearing: a missing
            # type is not evidence of anything. `type: Numeric` deliberately emits `{}` on output, its values
            # having more than one wire form, and reading that absence as proof emptied a position the action
            # satisfies with `1` — the schema rejecting output it had produced.
            # EVERY spelling of the validator drops it, which is why no option is consulted here: `is_number?` runs
            # before any of them, and no Array, Hash or boolean survives it — `[1].to_s` is `"[1]"` and `true.to_s`
            # is `"true"`, neither a numeric literal. Reading the options here left `of: { klass: :boolean,
            # numericality: true }` advertising an element the validator rejects on every call. The test stays on
            # types that NAME non-Numerics; an absent or unrecognized type still falls through to "keep".
            #
            # Exact for a boolean: `Class.new(TrueClass)` is legal and can never be instantiated (`new` AND
            # `allocate` both raise), so no value of a `"boolean"` branch is anything but `true`/`false`. For the
            # containers it rests on the same footing every spelling has always stood on — a subclass
            # reimplementing BOTH `to_s` and `to_i` to impersonate a number does satisfy the validator, and one
            # overriding `to_s` alone raises inside ActiveModel rather than passing.
            if NON_NUMERIC_BRANCH_TYPES.include?(branch[:type])
              return drop ? blank_witness_branch(branch, blank_tolerated, empty_rejected) : branch
            end

            case branch[:type]
            when "number" then only_integer ? number_branch_as_integer(branch, admits_integer) : branch
            when "string" then string_branch_under_numericality(branch, numeric_only:, only_integer:, drop:)
            else branch
            end
          end

          # The emitted types that name values no Numeric can be, and so the only branches `only_numeric:` may
          # drop. Listed rather than derived by exclusion for exactly the reason above — an absent or unrecognized
          # type has to fall through to "keep", not to "drop".
          NON_NUMERIC_BRANCH_TYPES = %w[array object boolean].freeze
          private_constant :NON_NUMERIC_BRANCH_TYPES

          # The one blank each of those types can hold. Every branch the numeric check excludes has exactly one, so
          # a blank-tolerant position narrows the branch TO it rather than losing the branch: the result names the
          # only value that can occupy the position there, which is right in both directions at once — outbound it
          # accepts the blank the action can expose, inbound it accepts nothing else, and the runtime agrees on
          # both counts. `enum` is the spelling because a singleton boolean branch already uses it (`TrueClass`
          # emits `enum: [true]`) and because `merge_enum!` composes it by intersection.
          #
          # Each witness is FROZEN, on the same terms `EMPTY_ENUM` and `NULL_BRANCH` already are: this value is
          # handed to a consumer inside a schema, schemas are rebuilt per call and caller-mutable, and a shared
          # mutable `[]`/`{}` let one consumer's mutation reach every schema the process emitted afterwards —
          # measured, appending to one action's witness changed a DIFFERENT action class's `enum` to `[[99]]`.
          # Freezing rather than copying is what the neighbours do and buys the same property (AGENTS.md: an
          # already-frozen container needs no copy), with the difference that a mutating consumer now gets a
          # FrozenError instead of silently corrupting every later schema.
          BLANK_BRANCH_WITNESS = { "array" => [].freeze, "object" => {}.freeze, "boolean" => false }.freeze
          private_constant :BLANK_BRANCH_WITNESS

          # `nil` — drop the branch — wherever no tolerated blank can occupy it. Two ways that happens: the
          # position tolerates no blank at all, or the branch already names values that exclude this type's blank.
          # The second is the `TrueClass` case and it matters: its branch is `enum: [true]`, and `true` is not
          # blank, so nothing skips the validator there and the branch really is unreachable — while `FalseClass`
          # names `false`, which is, and survives.
          def blank_witness_branch(branch, blank_tolerated, empty_rejected)
            return nil unless blank_tolerated
            return nil unless BLANK_BRANCH_WITNESS.key?(branch[:type])

            witness = BLANK_BRANCH_WITNESS.fetch(branch[:type])
            # An EMPTY witness has to clear the position's own emptiness check, and so does an explicitly-named
            # `false`. The one exemption is the `:boolean` pseudo-type, whose blank a REQUIRED position really does
            # admit — measured, `expects :n, type: :boolean` accepts `false`, while `type: FalseClass` accepts
            # nothing at all — and its branch is the one carrying no `enum`, a `FalseClass` branch naming `[false]`
            # explicitly.
            return nil if empty_rejected && !(false.equal?(witness) && branch[:enum].nil?)

            existing = branch[:enum]
            return nil if existing && !existing.include?(witness)

            branch.merge(enum: [witness])
          end

          # A numeric branch under `only_integer:`: retagged where some declared token admits an Integer, and
          # dropped where none does — no Float satisfies the option (`2.0.to_s` is "2.0"), so the branch is
          # unreachable rather than merely narrower.
          def number_branch_as_integer(branch, admits_integer) = admits_integer ? branch.merge(type: "integer") : nil

          def string_branch_under_numericality(branch, numeric_only:, only_integer:, drop: true)
            return nil if numeric_only && drop
            return branch unless only_integer

            merge_integer_literal_pattern(branch)
          end

          def merge_integer_literal_pattern(branch)
            source = Pattern.ecma_source(Axn::Validation::Base.integer_literal_regexp)
            return branch unless source

            composed = branch.dup
            write_pattern!(composed, source)
            composed
          end

          # Whether the position's numbers reach the wire unchanged. A Ruby Integer and Float serialize exactly;
          # every other Numeric is rendered through `Float()`, which ROUNDS — `BigDecimal("0.099999999999999999")`
          # satisfies `less_than: 0.1` and then serializes AS `0.1`, which the emitted `exclusiveMaximum` rejects.
          # A bound is outbound-honest only where that rounding cannot happen.
          def numeric_serialization_exact?(tokens)
            return false if tokens.empty?

            tokens.all? do |token|
              Internal::Identity.same?(token, ::Integer) || Internal::Identity.same?(token, ::Float)
            end
          end

          # Whether a JSON integer could satisfy any of the declared tokens. Asked of Integer's OWN ancestry, the
          # undispatched form, for the reason the key-axis gates give. No declared token at all means the caller is
          # not describing a class union, and the narrowing behaves as it did before this distinction existed.
          def integer_admitted_by?(tokens)
            return true if tokens.empty?

            tokens.any? do |token|
              Internal::Identity.kind?(token, ::Module) && Internal::NativeMethods.includes_module?(::Integer, token)
            end
          end

          # Whether a `numericality:` entry proves the value will SERIALIZE as a JSON number. Two different
          # things can stop it, and it takes both options to exclude them.
          #
          # ActiveModel accepts a numeric STRING unless `only_numeric: true` is given — `"1"` passes
          # `greater_than: 0`, and passes `only_integer:` too, since that reads the string form — so an exposed
          # value may well be a String. And `only_numeric:` alone proves only that the value is a NUMERIC, which
          # is not the same as a JSON number: `Complex(1, 2)` is a Numeric and serializes as `"1+2i"`, so the
          # inferred `"number"` rejected output the action had produced successfully.
          #
          # `only_integer:` is what excludes it, and excludes it exactly: among Numerics only an Integer's `#to_s`
          # is an integer literal (a Float's carries `.`, a Rational's `/`, a BigDecimal's `e`, a Complex's `i`),
          # so the two options together pin the value to an Integer and the emitted type is "integer" rather than
          # "number". It has to be a STATIC `only_integer:`, which is exactly what `declared_only_integer?` asks;
          # `only_numeric:` needs no such test, being the one option here ActiveModel reads truthily instead of
          # resolving per call.
          #
          # On INPUT none of this applies: `numericality_input_node` types the node as the Number-or-numeric-String
          # union the validator accepts. A declared `type:` is unaffected in both directions, being read before this
          # and proving the class itself.
          def numericality_type_provable?(numericality, for_output:)
            return true unless for_output
            return false unless Axn::Validation::Base.validator_entry_options(numericality)[:only_numeric]

            Axn::Validation::Base.declared_only_integer?(numericality)
          end
        end
      end
    end
  end
end
