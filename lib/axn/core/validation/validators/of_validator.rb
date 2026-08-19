# frozen_string_literal: true

require "active_model"

require "axn/internal/cycle_guard"
require "axn/internal/shape_graph"

module Axn
  module Validators
    class OfValidator < ActiveModel::EachValidator
      def self.apply_syntactic_sugar(value, _fields)
        return value if value.is_a?(Hash)

        { klass: value }
      end

      # A map names its axes with `keys:`/`values:`, either of which may be left off. An element bag names
      # `klass:` only when that is what it constrains — a bag constraining by `of:` or `shape:` names no class
      # deliberately (`of: { shape: … }` is "each element has these members, class unconstrained"), and the
      # declaration guard has already refused a bag constraining none of the three.
      def check_validity!
        return if options[:container] == ::Hash
        return if options[:of] || options[:shape]

        raise ArgumentError, "must supply :klass" if options[:klass].nil?
      end

      def validate_each(record, attribute, value)
        return if value.nil? && (options[:allow_nil] || options[:allow_blank])

        options[:container] == ::Hash ? validate_entries(record, attribute, value) : validate_elements(record, attribute, value)
      end

      private

      # The declared container decides which branch runs; the value's own class only decides whether this
      # validator has anything to say about it. TypeValidator owns both mismatches.
      def validate_elements(record, attribute, value)
        return unless value.is_a?(::Array)

        klasses = Array(options[:klass])
        # A custom message: replaces the type description but the index is always reported —
        # element position is the locating info that makes a per-element error actionable.
        msg = options[:message] || describe_mismatch(klasses)

        value.each_with_index do |el, i|
          # allow_blank governs whether the whole field may be absent (handled above), not whether
          # individual elements may be blank — so it is intentionally not passed to the matcher.
          record.errors.add(attribute, "element at index #{i} #{msg}") unless matches_axis?(el, klasses)
          # The type verdict does NOT gate the contents check: a wrong-typed element still reports what could
          # not be read out of it, which is what the pre-recursion pairing of OfValidator and ShapeValidator
          # did (both ran, independently) and what an author fixing a payload needs.
          add_contents_errors(record, attribute, el, "element at index #{i}: ")
        end
      end

      # The inner contract this bag declares, as a VALIDATIONS bag — both of its edges, since a position may
      # hold a container of its own AND have members read off it. `klass:` is deliberately absent, because the
      # type check is performed above and its message ("element at index 0 is not a String" — no colon) differs
      # in punctuation from a delegated one, which the caller below prefixes with a colon. Nil when the bag
      # constrains only a class, which is the overwhelmingly common case and the one that must allocate nothing.
      def contents_validations
        return @contents_validations if defined?(@contents_validations)

        bag = {}
        bag[:of] = options[:of] if options[:of]
        bag[:shape] = options[:shape] if options[:shape]
        @contents_validations = bag.empty? ? nil : bag
      end

      # One validator class per bag, built once and reused across every element, exactly as ShapeValidator
      # caches its per-member classes: a validator instance is built once per declaration and lives for the
      # life of the process, so the memo is per-contract rather than per-call.
      def contents_validator_class
        @contents_validator_class ||=
          Axn::Validation::ContainerContents.validator_class_for(field: :__axn_contents__, validations: contents_validations)
      end

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
      def guard_contents_descent(value, ancestry)
        depth = ancestry ? ancestry.depth : 0
        raise ArgumentError, Axn::Internal::ShapeGraph.inner_contract_too_deep_message if depth > Axn::Internal::ShapeGraph::MAX_NESTING

        # The child this descent is about to validate against, which is the identity a cyclic graph brings back
        # around: the nested `of:` bag, or the `shape:` node where that is the only edge the bag has. Never nil
        # — a nil key would pair every shape-only position with every other, and the second would be dropped as
        # a repeat.
        Axn::Internal::CycleGuard.guard_pair(value, options[:of] || options[:shape], ancestry&.seen, on_cycle: nil) do |seen|
          yield Axn::Internal::CycleGuard::Ancestry.new(seen:, depth: depth + 1)
        end
      end

      def add_contents_errors(record, attribute, value, prefix)
        return if nil.equal?(contents_validations)

        guard_contents_descent(value, record.send(:_shape_ancestry_for_validation)) do |ancestry|
          errors = Axn::Validation::Fields.errors_for(
            contents_validator_class,
            source: value,
            validations: contents_validations,
            action: record.send(:_action_for_validation),
            # A shape member's own `method_call:` opt-in is honored by ShapeValidator per member; nothing at
            # this level may re-permit dispatch on the caller's object.
            permit_method_call: false,
            shape_ancestry: ancestry,
          )
          errors.each { |error| record.errors.add(attribute, "#{prefix}#{error.message}") }
        end
      end

      # Both axes are reported independently: a map whose keys and values are both wrong has two things to
      # fix, and the entry's position locates both. An axis left undeclared constrains nothing.
      #
      # That position is the ONLY locating token the message carries, and the key deliberately is not. A
      # validation message is built here and settled unredacted: it reaches `result.exception.message` and the
      # logged line without passing through `contract/redaction.rb`, so a `sensitive:` map naming its own keys
      # would publish exactly what the declaration asked to be masked. Value-free is the same rule the element
      # branch's index already answers to and the one `TypeValidator` states for its own messages. A Hash
      # enumerates in insertion order, so the index names the entry the caller wrote.
      def validate_entries(record, attribute, value)
        return unless value.is_a?(::Hash)

        key_klasses = Array(options[:keys])
        value_klasses = Array(options[:values])
        index = 0

        # Traversed through a BOUND `Hash#each` so a subclass cannot decide which entries get validated — nor,
        # since nothing here renders a key, which entries get to run their own code while being named.
        Axn::Internal::ShapeGraph.each_entry(value) do |key, entry|
          record.errors.add(attribute, "key at index #{index} #{describe_mismatch(key_klasses)}") unless matches_axis?(key, key_klasses)
          record.errors.add(attribute, "value at index #{index} #{describe_mismatch(value_klasses)}") unless matches_axis?(entry, value_klasses)
          index += 1
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
