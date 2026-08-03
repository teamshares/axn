# frozen_string_literal: true

require "active_model"
require "axn/internal/shape_graph"

module Axn
  module Validators
    # Validates the per-member shape of a structured field declared via a block:
    #
    #   expects :items, type: Array do
    #     field :status, type: String, inclusion: { in: %w[a b] }
    #   end
    #
    # options[:members] is an array of ShapeConfig-like objects (responding to #field and
    # #validations, and optionally #method_call/#user_facing — a member that doesn't implement one
    # defaults to not opted in); options[:container] is the declared structured type (Array, Hash, or a class).
    # A shape DECLARED through `expects`/`exposes` always supplies axn's own `ShapeConfig`, so the duck-typing
    # here serves exactly one route: a field config ASSIGNED onto a class (`internal_field_configs=`), which
    # carries the caller's own member objects because it passed no declaration walk. This validator is
    # deliberately not registered globally (see `Validation::Base`), so a consuming app's own `validates` cannot
    # reach it and is not a route.
    # For an Array container each element is validated with its index in the message; for any other
    # container the single value's members are validated directly. A value that doesn't match the
    # declared container is left to TypeValidator (we don't try to extract members from it). Nesting
    # falls out for free: a member whose validations include a :shape key recurses through the same
    # machinery.
    class ShapeValidator < ActiveModel::EachValidator
      def check_validity!
        raise ArgumentError, "must supply :members" if options[:members].nil?
      end

      def validate_each(record, attribute, value)
        return if value.nil? && (options[:allow_nil] || options[:allow_blank])

        if options[:container] == Array
          return unless value.is_a?(Array) # TypeValidator owns the non-Array error

          value.each_with_index do |element, index|
            validate_members(record, attribute, element, prefix: "element at index #{index}: ")
          end
        else
          return unless value.is_a?(options[:container]) # TypeValidator owns the type mismatch

          validate_members(record, attribute, value, prefix: "")
        end
      end

      private

      # Where the walk currently is: the value/shape pairs open on the path above it (`seen`, owned by
      # `CycleGuard`) and how many levels it has descended. Threaded through `errors_for` because a nested
      # `shape:` recurses through ActiveModel rather than by calling itself.
      Ancestry = Data.define(:seen, :depth)
      private_constant :Ancestry

      # Descending into `source`'s members is the step that can recurse forever, so it is the step that is
      # bounded — on the two terms every walk of a graph a class merely HOLDS is bounded on, because a
      # declared graph cannot be either (the declaration walk refuses both) while `internal_field_configs=`
      # carries whatever its author built.
      #
      # A CYCLIC graph repeats an object, which the pair guard sees. A GENERATIVE one — minting a fresh
      # nested shape on every read — repeats nothing at all and is endless rather than cyclic, so it is the
      # depth bound that stops it. Neither bound substitutes for the other, and `SystemStackError` is what
      # was there before both: outside `StandardError`, so it escaped as an "exception" outcome carrying a
      # stack overflow rather than anything naming the contract.
      #
      # The pair is what a REVISIT means here. This walk descends a shape and a value in lockstep, so the
      # same value legitimately reappears under a DIFFERENT shape node with its own members still to check:
      # an ordinary two-level declared shape handed a self-referential Hash validates that Hash's members at
      # both levels, and value-only ancestry silently dropped the second level's verdicts. The same value
      # under the SAME node is a genuine repeat, and skipping it adds nothing the frame that opened it is not
      # already adding — so a cycle is treated as valid rather than reported.
      #
      # Keyed on the members list the node holds rather than on `options`: one validator class is built per
      # level, so `options` is a fresh Hash each time, while a cyclic graph hands back the same members list
      # — which is exactly the identity that repeats. A generative graph hands back a fresh one, and falls to
      # the depth bound.
      def guard_descent(source, ancestry)
        depth = ancestry ? ancestry.depth : 0
        raise ArgumentError, Axn::Internal::ShapeGraph.too_deep_message(nil) if depth >= Axn::Internal::ShapeGraph::MAX_NESTING

        Axn::Internal::CycleGuard.guard_pair(source, options[:members], ancestry&.seen, on_cycle: nil) do |seen|
          yield Ancestry.new(seen:, depth: depth + 1)
        end
      end

      def validate_members(record, attribute, source, prefix:)
        guard_descent(source, record.send(:_shape_ancestry_for_validation)) do |ancestry|
          validate_members_of(record, attribute, source, prefix:, ancestry:)
        end
      end

      def validate_members_of(record, attribute, source, prefix:, ancestry:)
        # `record` is the parent field's one-off validator, which carries the action (threaded by
        # errors_for at every level) — pass it down so a member's Symbol/Proc arguments and
        # if:/unless: conditions resolve against the ACTION, exactly as at the top level (a member
        # condition is action-scoped, never element-scoped). Orthogonal to the dispatch gate:
        # permission stays the member's own method_call: opt-in, never inferred from the action.
        action = record.send(:_action_for_validation)

        members.each do |member|
          unless extractable?(source, member.field)
            # A member none of whose validators would RUN is waived entirely — including this
            # pre-check. For an extractable source AM skips each such validator itself (below); a
            # non-extractable source never reaches AM, so mirror that waiver here: emit the
            # unreadable-member error iff AT LEAST ONE validator would still run.
            next if no_member_validator_runs?(member, source, action)

            record.errors.add(attribute, "#{prefix}#{Axn::Reflection::PropertyNames.renderable_label(member.field)} " \
                                         "could not be read (got #{source.class})",
                              axn_shape_member: true, axn_member_user_facing: member_user_facing(member))
            next
          end

          errors = Axn::Validation::Fields.errors_for(
            member_validator_classes[member.field],
            source:, validations: member.validations,
            action:, permit_method_call: member_method_call?(member),
            shape_ancestry: ancestry
          )
          errors.each do |error|
            # A member error carries its own `user_facing:` intent. When re-wrapping an error that
            # bubbled up from this member's OWN nested shape (already tagged), keep the deeper member's
            # intent rather than overwriting it — so a `user_facing:` member composes at any depth. A
            # member's own direct-validator errors are untagged here and take this member's intent.
            intent = error.options[:axn_shape_member] ? error.options[:axn_member_user_facing] : member_user_facing(member)
            record.errors.add(attribute, "#{prefix}#{Axn::Reflection::PropertyNames.renderable_label(member.field)} #{error.message}",
                              axn_shape_member: true, axn_member_user_facing: intent)
          end
        end
      end

      # Whether NONE of a non-extractable member's validators would RUN — in which case the
      # unreadable-member error is suppressed, mirroring how AM, on an extractable source, adds no error
      # when every validator is skipped. A validator fails to run for either reason: it is DISABLED (a
      # falsy value, e.g. `numericality: nil`/`false` — AM skips it via `next unless options`), or its
      # gate is CLOSED. Disabled entries are dropped first; if no active validator remains, nothing
      # would read the member, so the read is waived outright. Otherwise the per-entry gate sweep
      # decides: each active entry's effective gate is its OWN nested if:/unless: merged (per AM's tier
      # precedence) with the member's declaration-level shared gate — the decision is ActiveModel's own
      # (see Fields.validator_gate_open?), with the action threaded so a Symbol/Proc condition resolves
      # against the same `self` its real validation would use, and permission kept to the member's own
      # method_call: opt-in. Key-presence on either tier is checked first, so an ungated member with
      # active validators constructs nothing and stays byte-identical to the pre-gate path.
      def no_member_validator_runs?(member, source, action)
        gate_keys = Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS
        # A disabled validator (falsy value) never runs — like a gated-off one. Drop them; with no
        # active validator left, the member read is pointless (nothing would validate it), so waive it.
        active = Axn::Validation::Base.validator_entries(member.validations).select { |_key, opt| opt }
        return true if active.empty?

        has_shared_gate = gate_keys.any? { |key| member.validations.key?(key) }
        has_nested_gate = active.values.any? { |v| v.is_a?(Hash) && gate_keys.any? { |key| v.key?(key) } }
        return false unless has_shared_gate || has_nested_gate

        active.none? do |_key, entry_options|
          Axn::Validation::Fields.validator_gate_open?(
            validations: member.validations,
            entry_options:,
            action:,
            source:,
            permit_method_call: member_method_call?(member),
          )
        end
      end

      # Captured through the shared seam, so runtime validation, schema reflection, and the declaration
      # guard all consume one owned Array: a list answering `map`/`select`/`filter_map` differently from
      # `each` would otherwise validate a different set of members than the schema advertises.
      def members = Axn::Internal::ShapeGraph.members(options)

      # A member's `method_call:` opt-in, honored when present. A member reached through a declared `shape:` is
      # always axn's own `ShapeConfig` and carries the reader; the tolerance is for one carried by a field config
      # ASSIGNED onto a class, which is the caller's own object and may implement only the documented duck-typed
      # contract (`#field` + `#validations`). Such a member is treated as not opted in — the safe default, no
      # dispatch — rather than raising.
      def member_method_call?(member) = member.respond_to?(:method_call) && member.method_call

      # A member's `user_facing:` opt-in, honored when present. Duck-typed like `method_call:` — a member axn
      # did not construct may not implement `#user_facing`, and defaults to not opted in (dev-facing). Falsy
      # (nil/false) is "not opted in" and has no grammar to meet — `nil` is not IN the grammar, and it is what a
      # member declaring the attribute without setting it answers (a `Struct.new(:field, :validations,
      # :user_facing)`), so checking it would turn every such member into an ArgumentError.
      #
      # A truthy value IS held to the grammar, here, because this read is where it first decides anything and
      # because a member is the one thing in a contract axn has no constructor for. Every member the DECLARATION
      # walk stores is a `ShapeConfig` built from a value that walk grammar-checked
      # (`Contract#_snapshot_member_attributes!`) — but the config arrays are writable, so a config ASSIGNED onto
      # a class (`internal_field_configs=`) carries the caller's own member objects, unwalked, exactly as it
      # carries an unwalked shape graph. A field config assigned that way is still held by `FieldConfig`'s
      # constructor, which every stored one passes; a member has no such choke point, so the value is checked
      # where it is read.
      #
      # Checked lazily, on the failure path only, and worth checking at all because the consequence is not a
      # cosmetic one: the tag this returns both composes the caller's message (`123` resolves as a literal
      # handler result and surfaces as `"123"`) and decides CLASSIFICATION — a truthy non-rule makes the failure
      # settle as a plain user-facing failure, so the contract bug is never reported at all. A dev-facing
      # `ArgumentError` naming the fix is the honest outcome.
      def member_user_facing(member)
        return false unless member.respond_to?(:user_facing)

        value = member.user_facing
        Axn::Core::Contract.validate_user_facing!(value) if value
        value
      end

      # A value can yield a named member only if it responds to the reader (objects/Data) or
      # supports named-key access (Hash-like). Arrays respond to #dig but only by integer index,
      # so `Array#dig("status")` would raise a TypeError; excluding them keeps the element index in
      # the error (e.g. "element at index 0: status could not be read") instead of letting the
      # resolver raise and lose it. Guarding here mirrors FieldResolvers::Extract's own dispatch.
      # Being extractable is necessary but not sufficient to READ a member by method dispatch: a
      # non-`Data` object reader / Array method is resolved only when the member opted in with
      # `method_call: true`, otherwise the read raises MethodCallNotPermittedError (PRO-2907). The
      # safe branches (Hash keys, Struct/OpenStruct/Data members) never dispatch and need no flag.
      def extractable?(source, field)
        return true if source.respond_to?(field)

        source.respond_to?(:dig) && !source.is_a?(Array)
      end

      # One validator class per member, built once and reused across every element/value.
      def member_validator_classes
        @member_validator_classes ||= members.to_h do |member|
          [member.field, Axn::Validation::Fields.validator_class_for(field: member.field, validations: member.validations)]
        end
      end
    end
  end
end
