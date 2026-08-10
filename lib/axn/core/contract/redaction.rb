# frozen_string_literal: true

require "active_support/parameter_filter"
require "axn/extensions"
require "axn/internal/cycle_guard"
require "axn/internal/rendering"
require "axn/internal/shape_graph"

module Axn
  module Core
    module Contract
      module Redaction
        # `sensitive:` redaction, derived from the declaration: the candidate config set, the static
        # field-name filter, the shape paths a `ParameterFilter` cannot descend into, and the masking walk
        # that covers them. Extends onto the action class through `Contract::ClassMethods`, so every method
        # here is reached with an implicit receiver exactly as it was when it lived beside `expects`/`exposes`.

        # The mask a sensitive value is replaced with — matches `ActiveSupport::ParameterFilter`'s default
        # so wholesale-masked values read identically to per-key-filtered ones.
        SENSITIVE_FILTERED_MASK = "[FILTERED]"

        # Everything redaction derives from the DECLARATION rather than from a call: the candidate config
        # set, whether resolving `sensitive:` needs an instance at all, the static field-name filter, the
        # static shape paths, and — per shape — which members a mask has to descend into.
        #
        # All of it is a pure function of the class, because a stored shape graph is a declaration-time
        # SNAPSHOT — every node a Hash axn built, every member a `ShapeConfig` axn constructed from values read
        # once (`_snapshot_member_attributes!`). That is what makes an identity-keyed table sound at all: a
        # retained member would have left `sensitive:` free to change with nothing the key could see, so the
        # first read of a contract decided it and a later flip changed nothing. Re-deriving it per logged call
        # instead made the cost of redaction scale with the size of that graph, and worst for the contracts
        # that use no `sensitive:` at all: concluding "there is nothing to redact" is exactly what requires
        # visiting every member, so a 24,000-member shape with no `sensitive:` anywhere cost more per logged
        # call (~34ms) than the same shape with one.
        #
        # Keyed by the IDENTITY of the three config arrays, exactly as `_resolved_subfields` is and as
        # `PropertyNames.validate_outbound!`'s verdict is: the arrays are copy-on-write, so ANY later
        # declaration — a reopened class, a subclass, `Mountable`'s builder clearing them, a downstream gem
        # assigning the attribute directly — mints new ones and the stale table misses on `equal?`. That is
        # invalidation with no hook to keep in sync, which matters more here than for a schema cache: a
        # stale answer does not merely disagree with the contract, it fails to redact a `sensitive:` field
        # declared after the first logged call.
        def _contract_redaction
          internals = internal_field_configs
          externals = external_field_configs
          subfields = subfield_configs
          memo = @_axn_contract_redaction
          return memo if memo&.current?(internals, externals, subfields)

          @_axn_contract_redaction = ContractRedaction.new(internals:, externals:, subfields:)
        end

        # The table `_contract_redaction` hands out. Mutable (so not a `Data`) because each fact is derived
        # on first demand and written once, with `nil` meaning "not yet derived" — which none of the values
        # can be. Unlocked deliberately: every slot's value is the one answer that contract will ever have, so
        # a racing second derivation recomputes it and writes the same thing (the resolved-subfield cache's
        # single-ivar-write reasoning). The two per-shape tables are the same bargain one level down — a lost
        # race costs a repeat derivation, and a single Hash insert is not interruptible by another Ruby thread.
        class ContractRedaction
          attr_reader :internals, :externals, :subfields
          attr_accessor :candidates, :dynamic, :static_fields, :filter,
                        :static_shape_paths, :static_ambient_shape_paths

          def initialize(internals:, externals:, subfields:)
            @internals = internals
            @externals = externals
            @subfields = subfields
            # Per shape / per config, by identity — neither defines a `hash`/`eql?` axn would want to run,
            # and identity is the right question anyway: the stored graph is the one axn snapshotted.
            @nested_members = {}.compare_by_identity
            @member_names = {}.compare_by_identity
          end

          def current?(internals, externals, subfields)
            @internals.equal?(internals) && @externals.equal?(externals) && @subfields.equal?(subfields)
          end

          def nested_members_for(shape, &derive) = @nested_members.fetch(shape) { @nested_members[shape] = derive.call }

          def member_names_for(config, &derive) = @member_names.fetch(config) { @member_names[config] = derive.call }
        end
        private_constant :ContractRedaction

        def inspection_filter
          memo = _contract_redaction
          memo.filter ||= ActiveSupport::ParameterFilter.new(sensitive_fields)
        end

        def sensitive_fields
          _static_sensitive_fields
        end

        # Every config whose `sensitive:` participates in redaction: the declared inbound/outbound fields
        # and subfields, plus (recursively) the members of any shape block they carry. Shape members live
        # in validations[:shape][:members] at every depth, so the walk is uniform — a sensitive member at
        # any nesting level contributes its name to the ParameterFilter set (which redacts by key name at
        # any depth, array elements included). Single-sources the traversal for all three collectors.
        # Derived from the arrays the memo is KEYED on, never re-read from the class: a table that answered
        # from a newer contract than the one it is keyed to would be a stale answer wearing a valid key.
        def _sensitive_candidate_configs
          memo = _contract_redaction
          memo.candidates ||= (memo.internals + memo.externals + memo.subfields)
                              .flat_map { |config| _flatten_sensitive_candidates(config) }
        end

        def _flatten_sensitive_candidates(config, seen = nil, depth = 0)
          # Through the shared seam: a member list that hides itself from `flat_map` would drop a
          # `sensitive:` member from the redaction set, which leaks rather than merely disagreeing.
          shape = Internal::ShapeGraph.shape_in(config.validations)
          # Bounded BOTH ways, because the configs this walks need not have been DECLARED: the declaration walk
          # rejects an untraversable graph and snapshots what it accepts, but `internal_field_configs` and friends
          # are writable, so a config assigned onto a class carries whatever shape its author built — pointed back
          # at itself (which `CycleGuard` sees) or minting a fresh nested shape on every read (which nothing sees
          # but depth). This runs while a log line or an exception report is being built — once per contract, or
          # per logged call for a `sensitive:` that resolves against the action — and the alternative is
          # SystemStackError from a log line, a side channel taking down the call it observes.
          #
          # Nothing is lost by stopping at a cycle: it re-reaches members an enclosing frame is already
          # collecting. Past the depth bound there IS no honest answer, and the wholesale mask does the work —
          # `_shape_has_sensitive_member?` answers true there, so the whole value is redacted rather than
          # filtered per member.
          return [config] if nil.equal?(shape) || depth > Internal::ShapeGraph::MAX_NESTING

          nested = Axn::Internal::CycleGuard.guard(shape, seen, on_cycle: []) do |open|
            Internal::ShapeGraph.members(shape).flat_map { |member| _flatten_sensitive_candidates(member, open, depth + 1) }
          end
          [config, *nested]
        end

        def _static_sensitive_fields
          memo = _contract_redaction
          memo.static_fields ||= _sensitive_candidate_configs
                                 .select { |c| _config_sensitive(c) == true }
                                 .flat_map { |c| _sensitive_field_keys(c) }
        end

        # Whether resolving this contract's `sensitive:` needs an action instance — and therefore the ONE
        # question every reuse decision below turns on. It can be one question because the value space is closed
        # at declaration (see Contract.validate_sensitive!): over `true`/`false`/`nil`/Symbol/Proc, "carries a
        # Proc or Symbol" and "would resolve differently with an instance than without" are the same set. A
        # second, stricter predicate existed here to cover a truthy value that is neither — which the
        # instanceless path counted as not-sensitive while the per-instance path truthiness-tested it as
        # sensitive, observably so for a non-Hash shaped value — and rejecting that value at declaration is what
        # removes the divergence instead of guarding it.
        #
        # `false` is one of the two answers, so the memo is guarded on `nil` rather than written with `||=`: an
        # `||=` here re-ran the whole candidate walk on every logged call for precisely the contracts that have
        # no dynamic `sensitive:` — which is nearly all of them.
        def _has_dynamic_sensitive_fields?
          memo = _contract_redaction
          return memo.dynamic unless memo.dynamic.nil?

          memo.dynamic = _sensitive_candidate_configs.any? do |config|
            # `case`/`when` consults the real class, so a caller-supplied member's value cannot decide whether
            # it needs an instance — the same non-dispatching test the declaration guard uses.
            case _config_sensitive(config)
            when ::Proc, ::Symbol then true
            else false
            end
          end
        end

        def _resolve_sensitive_fields(action_instance)
          return _static_sensitive_fields unless _has_dynamic_sensitive_fields?

          _sensitive_candidate_configs
            .select { |config| _resolve_sensitive_value(_config_sensitive(config), action_instance, field: config.field) }
            .flat_map { |c| _sensitive_field_keys(c) }
        end

        # A shape member's contract is duck-typed — ShapeValidator requires only #field/#validations,
        # and `shape: { members: [...] }` may be supplied raw with member objects that implement no
        # more than that. `#sensitive` is optional (absent on such a raw member), so read it defensively
        # and treat a missing reader as `false`, mirroring how the validator treats a missing
        # #method_call as not opted in. Read through Internal::ShapeGraph, so a member that DEFINES
        # `sensitive:` cannot opt out of redaction by denying the reader.
        #
        # That costs a Method allocation per read (~0.25µs, against ~0.04µs for `respond_to?` plus a
        # dispatch) and is spent deliberately: the reads here are per config on a derivation, and a
        # member hiding from redaction leaks a secret. `_sensitive_shape_paths` makes the opposite call for
        # the opposite reason — it reads axn's OWN configs, which cannot lie, so it takes the cheap
        # `shape_in` path. The tradeoff differs because the exposure does.
        def _config_sensitive(config)
          Internal::ShapeGraph.read(config, :sensitive) || false
        end

        # A sensitive `model:` field also redacts its generated `<field>_id` alias (the id is as
        # sensitive as the record). Non-model fields contribute only their own key.
        def _sensitive_field_keys(config)
          keys = [config.field]
          keys << Internal::FieldConfig.model_id_key(config.field) if config.validations[:model]
          keys
        end

        # The first three arms are the whole declared grammar (see Contract.validate_sensitive!); `!!` is what
        # turns a predicate's arbitrary return value into a decision. The `else` is now reachable only by `nil`
        # — which `_config_sensitive` already normalizes to `false` on every path that reads a config — and is
        # kept fail-SAFE rather than dropped: were an out-of-grammar value ever to arrive here, redacting a
        # truthy one is the direction that cannot leak. This is the branch whose truthiness test used to
        # disagree with the instanceless path about `sensitive: "yes"`, and closing the value space is what
        # removed the disagreement rather than a second predicate guarding it.
        #
        # This runs on the presentation path — `inspect`, a log line, the exception context — which must never
        # raise (the same rule `MessageResolver#apply_join_proc` follows for `join:`). The declaration guard
        # (`Contract.validate_sensitive!`) rejects the common static case, a Proc that cannot take zero
        # arguments, but two shapes still reach here: a Symbol naming a method that takes a required argument
        # or does not exist yet (defined later, or answered only via `method_missing`), and a Proc that raises
        # for a reason that has nothing to do with arity. Both are caught and FAIL CLOSED — redact and warn —
        # never fail open: unlike `join:`'s cosmetic fallback, this one decides whether a secret is printed,
        # and the accidental behavior it replaces was already fail-closed (an uncaught raise blocks the
        # value from ever being displayed at all).
        #
        # `field` is passed by every caller that has one, purely to name the offending declaration in the
        # warning — `sensitive`/`action_instance` alone decide the outcome.
        def _resolve_sensitive_value(sensitive, action_instance, field: nil)
          case sensitive
          when true, false
            sensitive
          when Symbol
            !!action_instance.send(sensitive)
          when Proc
            !!action_instance.instance_exec(&sensitive)
          else
            !!sensitive
          end
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => e
          _warn_sensitive_resolution_failure(action_instance, field, sensitive, e)
          true
        end

        # The warning is a diagnostic ABOUT the fail-closed decision, not part of it — `true` above has
        # already been earned by the time this runs, so a broken warn target cannot undo it. Guarded
        # separately from the resolution rescue: the sensitive predicate raising is the ordinary case this
        # whole method exists for, but the environment that made a predicate misbehave (a custom logger
        # writing to a closed IO, a network sink timing out) is exactly the kind where the CONFIGURED
        # LOGGER is also more likely to raise, and `action_instance.warn` ultimately dispatches to
        # `Axn.config.logger`, which is caller-supplied. Swallowed on the same terms as everywhere else axn
        # decides what it will ever absorb — silently, since a second diagnostic about the first one
        # failing has nowhere honest left to go.
        #
        # `error`'s own MESSAGE is deliberately never rendered here, only its class and source location: a
        # `sensitive:` predicate exists to keep some value out of logs, so a predicate that raises with that
        # value interpolated into its message (`raise "invalid SSN #{ssn}"`) would otherwise turn the
        # fail-closed diagnostic into exactly the disclosure `sensitive:` exists to prevent — no rendering
        # guard can tell safe prose from an accidental echo of the value it was written to protect.
        #
        # `sensitive` is described through `_describe_sensitive_rule` rather than a bare `.inspect`: it is a
        # Proc or Symbol declared by this action's own author, but a Proc CAN carry a singleton `inspect`
        # (a Symbol cannot — `define_singleton_method` on one raises TypeError), and this predicate is the
        # one already known to behave unexpectedly, having just raised. Naming it without dispatching to it
        # is the same discipline `Contract.validate_sensitive!` uses to name an out-of-grammar value by class.
        def _warn_sensitive_resolution_failure(action_instance, field, sensitive, error)
          action_instance.warn("sensitive: #{field.nil? ? '' : "#{field.inspect} "}(#{_describe_sensitive_rule(sensitive)}) raised " \
                               "#{Axn::Internal::Rendering.class_name(error)} at #{Axn::Internal::Rendering.exception_source_location(error)} " \
                               "— redacting (fail closed)")
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
          nil
        end

        # `sensitive` here is always a Symbol or a Proc — the only two grammar members
        # `_resolve_sensitive_value` can raise from. A Symbol's own `#inspect` is safe to call directly (no
        # singleton is possible on one); a Proc's is read through Proc's OWN implementation, `bind_call`,
        # never dispatched, since a Proc singleton-`inspect` could otherwise be used to smuggle arbitrary
        # text — including a captured secret — into this warning under the guise of "naming the rule".
        PROC_INSPECT = ::Proc.instance_method(:inspect)
        private_constant :PROC_INSPECT

        def _describe_sensitive_rule(sensitive)
          case sensitive
          when ::Proc then PROC_INSPECT.bind_call(sensitive)
          when ::Symbol then sensitive.inspect
          else Axn::Internal::Rendering.class_name(sensitive)
          end
        end

        def _build_instance_filter(action_instance)
          ActiveSupport::ParameterFilter.new(_resolve_sensitive_fields(action_instance))
        end

        # Internal method for filtering context data by direction
        # Used by instance methods (inputs_for_logging, outputs_for_logging) and async exception reporting
        # When action_instance is provided, dynamic sensitive fields are resolved against that instance.
        def _context_slice(data:, direction: nil, action_instance: nil)
          filter = if action_instance && _has_dynamic_sensitive_fields?
                     _build_instance_filter(action_instance)
                   else
                     inspection_filter
                   end
          sliced = _mask_unfilterable_shapes(data.slice(*_declared_fields(direction)), _sensitive_shape_paths(action_instance), action_instance)
          _filter_tolerating_cycles(filter, sliced)
        end

        # ActiveSupport::ParameterFilter has no cycle guard of its own, so a self-referential value blows
        # its stack — and since a filter is active for any action declaring `sensitive:`, that cost the
        # WHOLE slice: both auto_log lines dropped to warnings and the exception report degraded to empty
        # inputs/outputs, losing the fields that had nothing to do with the cycle.
        #
        # Retried on a decycled copy rather than decycling up front, so acyclic data (all of it, in
        # practice) pays nothing: no extra walk, no copy. The retry can only be reached by data that
        # already failed, where one wasted filter pass is irrelevant.
        def _filter_tolerating_cycles(filter, data)
          filter.filter(data)
        rescue SystemStackError
          filter.filter(Axn::Internal::CycleGuard.decycle(data))
        end

        # Per-element `sensitive:` redaction works by adding the member's key name to an
        # `ActiveSupport::ParameterFilter`, which redacts Hash keys at any depth — so a member inside a
        # Hash (or an Array of Hashes) is filtered precisely, siblings preserved. But the filter only
        # descends into Hashes: an object-backed shape value (a Data/Struct/PORO), or a malformed non-Hash
        # value where a Hash was expected (which reaches logging before inbound validation can reject it),
        # is opaque to it and would print whole. So for every field/subfield whose shape carries a
        # sensitive member, this walks to the shaped value and replaces a non-Hash value in a
        # member-bearing position with the mask — over-redacting the whole value (its non-sensitive
        # siblings included) rather than risk leaking the secret. Applied to logs, exception context,
        # and `inspect`.
        def _mask_unfilterable_shapes(data, shape_paths, action_instance)
          return data unless data.is_a?(Hash)

          shape_paths.reduce(data) do |acc, (wire_path, shape)|
            _mask_value_at_path(acc, wire_path, shape, action_instance)
          end
        end

        # Single-field entry — inspect renders one field at a time. Reuses the whole-hash pass on a
        # one-key hash so a subfield shape rooted under `field` is masked at its nested position too.
        def _mask_unfilterable_shape_value(field, value, action_instance)
          _mask_unfilterable_shapes({ field => value }, _sensitive_shape_paths(action_instance), action_instance)[field]
        end

        # `[(wire_path, shape)]` for every field/subfield whose shape carries a sensitive member. A
        # top-level field's path is `[field]`; a subfield's is its resolved wire path (from the
        # SubfieldTree cache), so a shape declared on a subfield — `expects :person, on: :payload, …
        # do … end` — is masked at `payload[:person]`, not just where a top-level shape lives.
        # Memoized unless a `sensitive:` resolves against the action (`_has_dynamic_sensitive_fields?`), which
        # is what keeps a logged call from paying for the whole stored graph. A contract that DOES need the
        # instance still derives per call — correctness requires it, and a memo ignoring the instance would
        # over-redact a `sensitive: :flag` member whose flag is false, which looks safe and is a behavior
        # change.
        def _sensitive_shape_paths(action_instance)
          return _derive_sensitive_shape_paths(action_instance) if _has_dynamic_sensitive_fields?

          memo = _contract_redaction
          memo.static_shape_paths ||= _derive_sensitive_shape_paths(nil)
        end

        # Over the arrays the memo is keyed on, for the reason `_sensitive_candidate_configs` gives.
        def _derive_sensitive_shape_paths(action_instance)
          memo = _contract_redaction
          (memo.internals + memo.externals + memo.subfields).filter_map do |config|
            shape = Internal::ShapeGraph.shape_in(config.validations)
            next unless shape && _shape_has_sensitive_member?(shape, action_instance)

            wire_path = config.subfield? ? _resolved_subfields.index[config]&.wire_path : [config.field]
            next unless wire_path

            [wire_path, shape]
          end
        end

        # The ambient analog of `_sensitive_shape_paths`: `[(wire_path_within_ambient, shape)]` for
        # every ambient subfield whose shape carries a sensitive member. Ambient shapes are leaf nodes
        # (`_check_ambient_shape_placement!`), so their value is copied whole and may be a non-Hash the
        # ParameterFilter can't descend into — this feeds `_mask_unfilterable_shapes` to mask it. The
        # ambient tree's wire paths are rooted at the synthetic `:ambient_context` segment; drop it,
        # since the mask applies to the ambient VALUE the reader returns, not a hash wrapped under an
        # `:ambient_context` key.
        def _sensitive_ambient_shape_paths(action_instance)
          return _derive_sensitive_ambient_shape_paths(action_instance) if _has_dynamic_sensitive_fields?

          memo = _contract_redaction
          memo.static_ambient_shape_paths ||= _derive_sensitive_ambient_shape_paths(nil)
        end

        def _derive_sensitive_ambient_shape_paths(action_instance)
          _ambient_subfield_tree.index.filter_map do |config, path|
            shape = Internal::ShapeGraph.shape_in(config.validations)
            next unless shape && _shape_has_sensitive_member?(shape, action_instance)

            [path.wire_path.drop(1), shape]
          end
        end

        # Walk `wire_path` through `value` — Hash keys in either symbol or string form (extraction
        # accepts both), mapping across arrays — and mask the shaped value at the leaf. Every present
        # key form is masked (see `_present_key_variants`); an absent key is left alone. A non-Hash,
        # non-Array intermediate with path still remaining is an object-backed parent (a `method_call:`
        # subfield reads the sensitive shape off it) that ParameterFilter can't descend into — mask it
        # wholesale rather than leak the sensitive member nested inside; a nil/scalar intermediate is
        # preserved (nothing to reach or leak).
        # The Hash branch consumes a path segment per level so it always terminates; the Array branch
        # maps with the path UNCHANGED, so a self-referential array would recurse until the stack
        # blows. A revisited array masks wholesale (not the `[...]` placeholder, which would be a
        # placeholder String masquerading as data) — the same over-redact-rather-than-leak call as
        # `_mask_opaque_or_preserve`, since we cannot descend to redact the sensitive member inside.
        def _mask_value_at_path(value, wire_path, shape, action_instance, seen = nil)
          return _mask_shape_value(value, shape, action_instance) if wire_path.empty?

          if value.is_a?(Array)
            return Axn::Internal::CycleGuard.guard(value, seen, on_cycle: SENSITIVE_FILTERED_MASK) do |nested|
              value.map { |element| _mask_value_at_path(element, wire_path, shape, action_instance, nested) }
            end
          end
          return _mask_opaque_or_preserve(value) unless value.is_a?(Hash)

          _present_key_variants(value, wire_path.first).reduce(value) do |acc, key|
            acc.merge(key => _mask_value_at_path(acc[key], wire_path.drop(1), shape, action_instance, seen))
          end
        end

        # A non-Hash/Array value in a member-bearing position. `nil` is preserved — it is valid absent
        # data (a nil-tolerant shape) with nothing to leak, and masking it would make absent data look
        # redacted. Anything else is malformed for a shaped field (which expects a Hash/object with
        # members) and ParameterFilter can't redact into it: a structured object could expose the member
        # via `inspect`, and a bare scalar could itself BE the sensitive value the caller mis-supplied
        # (`items: ["111-11-1111"]`). Both reach logging before validation rejects them, so mask.
        def _mask_opaque_or_preserve(value)
          value.nil? ? value : SENSITIVE_FILTERED_MASK
        end

        # Every form of `key` present in `hash` — the key as-is, its string form, and its symbol form.
        # Extraction accepts symbol and string keys (reading symbol-first) and a member/wire-path name
        # may be declared in either form, so a single logical key can appear under more than one form in
        # the same Hash; mask them all, since every form is logged and any could hold the secret.
        def _present_key_variants(hash, key)
          [key, key.to_s, key.to_s.to_sym].uniq.select { |variant| hash.key?(variant) }
        end

        # Whether a shape tree carries a `sensitive:` member anywhere (direct, or in a nested shape).
        # A nil action_instance (async reporting, no instance to resolve a dynamic predicate against)
        # counts only static `sensitive: true`, matching the static `inspection_filter` used there.
        # Bounded for the same reasons as `_flatten_sensitive_candidates`. The cycle answer is exact rather than
        # defensive: a cyclic branch re-reaches the very members the enclosing frame is already testing, so
        # answering `false` for it decides nothing on its own and no `sensitive:` member can hide in one. The
        # depth answer cannot be exact, so it is fail-safe instead (see below).
        def _shape_has_sensitive_member?(shape, action_instance, seen = nil, depth = 0)
          # Past the depth bound the answer is TRUE, not false: a graph that deep is one minting fresh nested
          # shapes on every read, so nothing can enumerate what is inside it — and the fail-safe answer for
          # redaction is "assume a secret", which masks the value wholesale rather than logging it in the clear.
          # Unreachable for a declared graph, since the declaration walk rejects one this deep — depth included
          # when it comes only from sub-shapes that walk had already verified shallower, which is what keeps this
          # from masking a value in a contract with no `sensitive:` in it (`Contract#_walk_shape_graph!`).
          return true if depth > Internal::ShapeGraph::MAX_NESTING

          Axn::Internal::CycleGuard.guard(shape, seen, on_cycle: false) do |open|
            Internal::ShapeGraph.members(shape).any? do |member|
              _member_sensitive?(member, action_instance) ||
                (_member_shape(member) && _shape_has_sensitive_member?(_member_shape(member), action_instance, open, depth + 1))
            end
          end
        end

        def _member_sensitive?(member, action_instance)
          sensitive = _config_sensitive(member)
          return sensitive == true if action_instance.nil?

          _resolve_sensitive_value(sensitive, action_instance, field: member.field)
        end

        # The shape a config or member carries, or nil when it carries none — read without dispatching
        # anything a raw `shape:` kwarg's objects can define (see Internal::ShapeGraph), so a member
        # lying about its type or its readers cannot hide a nested shape from a walk that reflection,
        # validation and redaction all still descend into.
        def _member_shape(member) = Internal::ShapeGraph.nested_shape(member)

        # Dispatch on the shape's container — the value must match it, or it's malformed (and reaches
        # logging before validation rejects it, so its arbitrary contents could leak). An `Array` shape
        # maps each element (member-bearing); a `Hash` shape filters the Hash's member keys; a class
        # (Data/Struct/PORO) shape reads members off an object ParameterFilter can't descend into. Any
        # value whose type doesn't match the container is masked wholesale rather than treated as a lone
        # valid element/Hash — only declared member keys would be filtered, leaking arbitrary siblings.
        # `nil` (valid absent data) is preserved throughout via `_mask_opaque_or_preserve`.
        #
        # The container is compared by IDENTITY rather than with `==`: a raw `shape:` kwarg may supply any
        # object there, and `container == Array` dispatches that object's own `==` — one answering true for
        # both arms, or raising, would decide which redaction path a secret takes. `Array`/`Hash` are the
        # receivers, so only their own `equal?` runs.
        def _mask_shape_value(value, shape, action_instance, seen = nil)
          container = shape[:container]
          if ::Array.equal?(container)
            return value.map { |element| _mask_shape_element(element, shape, action_instance, seen) } if value.is_a?(Array)

            return _mask_opaque_or_preserve(value)
          end
          return _mask_shape_element(value, shape, action_instance, seen) if ::Hash.equal?(container)

          _mask_opaque_or_preserve(value)
        end

        # A non-Hash value where members are expected is opaque to ParameterFilter → mask it whole. A Hash
        # keeps its own keys (ParameterFilter redacts the sensitive ones); only recurse into a nested-shape
        # member's value when that nested shape actually carries a sensitive member, to avoid needless
        # masking of an unrelated non-Hash deeper down. The member key is matched in either symbol or
        # string form, since extraction accepts both.
        #
        # Cycle-guarded on the VALUE, which is the only ancestry that can recurse here: every step of this
        # walk moves to a strictly contained value (an Array element, or a Hash value under a member's key),
        # so a finite acyclic value terminates it however the SHAPE is built — a shape pointed back at itself
        # (reachable only through `internal_field_configs=`, since declaring one is refused) walks a
        # self-referential value forever but an acyclic one only as deep as the value goes. Guarding the shape
        # instead would stop the recursion at the wrong place: it would refuse to descend a legitimately
        # repeated shape — the same nested shape used by two members — where the value has more to redact.
        # The guard therefore lives on the Hash opened here rather than on the Array opened above, because a
        # cycle cannot close through Arrays alone (an Array element only recurses by being a Hash), so every
        # cyclic path repeats one of these.
        #
        # A revisited value masks WHOLESALE, never passes through: we cannot descend to redact the sensitive
        # member inside it, and a cycle is exactly where a sensitive sibling would otherwise print in the
        # clear — the same over-redact-rather-than-leak call `_mask_opaque_or_preserve` and the Array branch of
        # `_mask_value_at_path` make. Only genuine ancestry counts (CycleGuard pops on the way out), so a Hash
        # repeated among SIBLINGS, or a shape shared by two members, is still masked in full at every position.
        #
        # The guard is skipped when the shape has no descendable member, which is the ordinary flat shape and
        # every value masked under one: there is no recursion to guard, and entering it would put a
        # `compare_by_identity` Hash allocation on the per-logged-call redaction path.
        def _mask_shape_element(element, shape, action_instance, seen = nil)
          return _mask_opaque_or_preserve(element) unless element.is_a?(Hash)

          descendable = _sensitive_nested_members(shape, action_instance)
          return element.dup if descendable.empty?

          Axn::Internal::CycleGuard.guard(element, seen, on_cycle: SENSITIVE_FILTERED_MASK) do |open|
            descendable.each_with_object(element.dup) do |(member, nested), masked|
              _present_key_variants(masked, member.field).each do |key|
                masked[key] = _mask_shape_value(masked[key], nested, action_instance, open)
              end
            end
          end
        end

        # The `[(member, nested_shape)]` pairs a mask has to descend into: the members of `shape` whose OWN
        # nested shape carries a sensitive member. Memoized per shape (by identity) on the same condition as
        # `_sensitive_shape_paths` — no `sensitive:` resolving against the action — because for the ordinary
        # flat shape the answer is EMPTY, and finding that out cost a `nested_shape` read (a bound-Method
        # allocation each) for every member of the shape, on every value masked.
        def _sensitive_nested_members(shape, action_instance)
          return _derive_sensitive_nested_members(shape, action_instance) if _has_dynamic_sensitive_fields?

          _contract_redaction.nested_members_for(shape) { _derive_sensitive_nested_members(shape, nil) }
        end

        def _derive_sensitive_nested_members(shape, action_instance)
          Internal::ShapeGraph.members(shape).filter_map do |member|
            nested = _member_shape(member)
            next unless nested && _shape_has_sensitive_member?(nested, action_instance)

            [member, nested]
          end
        end

        # The names of the `sensitive:` members reachable inside one shape-bearing config's value — the flat
        # key set `inspect` hands to a `ParameterFilter`, since a member redacts by NAME wherever it appears
        # (every array element, any nesting depth), unlike the precise wire path a subfield contributes.
        # Memoized on the same condition as `_sensitive_shape_paths` — no `sensitive:` resolving against the
        # action — since `inspect` asks it once per displayed field, and the walk covers the whole stored graph.
        #
        # Lives here rather than with the inspector because it is a question about the CONTRACT, and because
        # sensitivity is read through `_config_sensitive` — the same seam logging reads — so a member that
        # defines `sensitive:` cannot escape redaction in `inspect` by denying the reader while logging
        # redacts it anyway.
        def _sensitive_member_names(config, action_instance)
          return _derive_sensitive_member_names(config, action_instance) if _has_dynamic_sensitive_fields?

          _contract_redaction.member_names_for(config) { _derive_sensitive_member_names(config, nil) }
        end

        # Bounded both ways, exactly as `_flatten_sensitive_candidates` is, and for its reason: a config assigned
        # onto a class rather than declared carries a shape no walk has traversed, which can be pointed at itself
        # (which `CycleGuard` sees) or mint a fresh one on every read (which nothing but depth sees). `inspect` is
        # reachable directly, not only from a side channel, so an unbounded walk here raises SystemStackError at
        # the caller rather than degrading a log line.
        #
        # A cycle re-reaches members an enclosing frame is already collecting, so stopping loses nothing.
        # Past the depth bound nothing can enumerate a graph that mints its members on demand — and the
        # value it describes is masked wholesale by then anyway (`_shape_has_sensitive_member?` answers true
        # past the same bound), so `inspect` shows a redacted value rather than a leaked one.
        def _derive_sensitive_member_names(config, action_instance, seen = nil, depth = 0)
          shape = Internal::ShapeGraph.shape_in(config.validations)
          return [] if nil.equal?(shape) || depth > Internal::ShapeGraph::MAX_NESTING

          Axn::Internal::CycleGuard.guard(shape, seen, on_cycle: []) do |open|
            # Through the shared seam, for the reason _flatten_sensitive_candidates gives: a list hiding
            # itself from `flat_map` would drop a sensitive member from the redaction set.
            Internal::ShapeGraph.members(shape).flat_map do |member|
              names = _derive_sensitive_member_names(member, action_instance, open, depth + 1)
              names << member.field if _member_sensitive?(member, action_instance)
              names
            end
          end
        end

        # An `_`-prefixed name already says "not yours to call", but on a module included into ClassMethods it
        # also lands on every action class as a PUBLIC singleton method — so the convention and the surface
        # disagreed. Everything reached only with an implicit receiver is listed here, declared beside its
        # definition rather than relocated below so each method stays with the walk it belongs to and its comment.
        #
        # The exceptions are the redaction entry points other layers genuinely call on the action class from
        # another file — `inspection_filter`/`sensitive_fields`, `_context_slice`, `_build_instance_filter`,
        # `_has_dynamic_sensitive_fields?`, `_resolve_sensitive_value`, `_mask_unfilterable_shapes`,
        # `_mask_unfilterable_shape_value`, `_sensitive_ambient_shape_paths`, `_sensitive_member_names`. Those
        # stay public: a cross-layer call needs a public method, and hiding one behind a `send` at the call site
        # would say private while meaning public, which is less honest than the `_` prefix alone.
        private :_contract_redaction, :_sensitive_candidate_configs, :_flatten_sensitive_candidates,
                :_static_sensitive_fields, :_resolve_sensitive_fields, :_config_sensitive, :_sensitive_field_keys,
                :_warn_sensitive_resolution_failure, :_describe_sensitive_rule,
                :_filter_tolerating_cycles, :_sensitive_shape_paths, :_derive_sensitive_shape_paths,
                :_derive_sensitive_ambient_shape_paths, :_mask_value_at_path, :_mask_opaque_or_preserve,
                :_present_key_variants, :_shape_has_sensitive_member?, :_member_sensitive?, :_member_shape,
                :_mask_shape_value, :_mask_shape_element, :_sensitive_nested_members,
                :_derive_sensitive_nested_members, :_derive_sensitive_member_names
      end
    end
  end
end
