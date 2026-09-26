# frozen_string_literal: true

# The gate keys a conditional declaration is recognized by.
require "axn/internal/field_config"

module Axn
  module Internal
    module Reflection
      module Schema
        # Every question this emitter puts to a declaration's VALIDATOR SET, forwarded to `Validation::Base`
        # so a field config's own `optional?` and the emitted property's requiredness can never answer
        # differently. Almost all of it is one-line delegation; it lives apart because a reader tracing why a
        # property is required wants the whole chain in one place, not scattered through the builder.
        module Gates
          # Whether the field's validators, taken together, permit a nil/omitted value — the one question
          # requiredness and nullability turn on, owned by Validation::Base so a field config's own
          # `optional?` answers it identically.
          #
          # An entry whose nil verdict reflection cannot know — a `validate:` callable, or a clusivity set it may
          # not read — is left out of the question rather than counted as rejecting nil: counting it would publish
          # a field as required (or non-null) that the runtime may accept omitted, which is the one direction the
          # schema may never err in. Such an entry is always named as a residue instead.
          def nil_accepted?(config) = Axn::Validation::Base.nil_accepted?(nil_judgeable_validations(config.validations))

          def nil_judgeable_validations(validations)
            shared = shared_validation_options(validations)
            validations.reject { |key, opt| nil_verdict_unknowable?(key, opt, shared) }
          end

          def nil_verdict_unknowable?(key, opt, shared)
            return false unless opt

            case key
            when :validate then true
            when :inclusion, :exclusion then set_includes_nil?(effective_entry_options(opt, shared)).nil?
            else false
            end
          end

          # Whether the config's declaration carries a declaration-level if:/unless: gate — the signal
          # that its enforcement (NOT its shape) is conditional at runtime. Asked of a config here and of
          # already-read validations in `shape_property_plan` (which holds nothing but the reduced Hash); one
          # predicate, so the two cannot answer differently. The reduction never removes a declaration-level gate
          # key, so both spellings see the same keys.
          def conditionally_gated?(config) = gated_validations?(config.validations)

          def gated_validations?(validations)
            Internal::FieldConfig::CONDITIONAL_GATE_KEYS.any? { |k| validations.key?(k) }
          end

          # Whether a single validator ENTRY carries a real per-validator (nested) if:/unless: gate — one that can
          # skip that entry alone (e.g. `presence: { if: -> { ... } }`, `type: { klass: Integer, if: :flag }`).
          # Owned by Validation::Base so the emptiness axis's deferral test and this reasoning judge one entry the
          # same way.
          def entry_self_gated?(opt) = Axn::Validation::Base.entry_self_gated?(opt)

          # Whether a single validator ENTRY's options MENTION a per-validator gate key at all — blank or
          # not (contrast entry_self_gated?, which requires a NON-blank value). A blank nested gate is not inert
          # for the declaration-level requiredness clause: per AM's measured per-key merge
          # (fields.rb#validator_gate_open?), a blank nested same-key value OVERRIDES and drops the shared
          # (declaration) gate for that key before AM ignores it — un-gating the entry. So an entry that
          # mentions ANY gate key no longer inherits the declaration gate verbatim. Owned by Validation::Base
          # so this reasoning and the declaration-time nil-skip push-down (contract.rb `_type_rejects_nil?`)
          # judge one entry the same way.
          def entry_mentions_gate_key?(opt) = Axn::Validation::Base.entry_mentions_gate_key?(opt)

          # Which gate keys EFFECTIVELY gate a single validator entry, given the declaration-level gates
          # (`decl_gates` = the sliced :if/:unless off the whole declaration, already blank-canonicalized).
          # Owned by Validation::Base so the declaration-time nil-skip push-down judges runtime skippability
          # identically; structural (never evaluates a condition), which is what keeps reflection
          # side-effect-free.
          def entry_effective_gate_keys(entry_opts, decl_gates) = Axn::Validation::Base.entry_effective_gate_keys(entry_opts, decl_gates)

          # Whether a config's requiredness can be RELAXED at runtime by a conditional GATE — the signal
          # that a required-looking route can't oblige an omitted/nil ancestor to be present, because a
          # closed gate skips the check that would otherwise reject the nil ancestor. Reasoned on EFFECTIVE
          # gates (entry_effective_gate_keys), which model AM's measured per-key merge of the declaration
          # gate with each entry's nested gate — so the two tiers combine exactly as at runtime without ever
          # evaluating a condition. Relaxable iff BOTH:
          #   * some gate exists anywhere — a declaration-level one (already blank-canonicalized) or a real
          #     (non-blank) nested one; AND
          #   * every NIL-REJECTING entry is effectively gated — the gate a closed runtime pass would skip is
          #     precisely the check that rejects the nil/absent ancestor, so nothing forces it. A nil-tolerant
          #     entry never rejects nil, so it imposes no ancestor obligation to relax.
          # The measured merge is what makes the corner cases correct: a declaration gate with a BLANK
          # same-key nested override on the lone presence check leaves it effectively UN-gated (the override
          # drops the shared gate, then AM ignores the blank), so an ungated nil-rejecting check still forces
          # the ancestor — NOT relaxable. A DISTINCT-key declaration gate (`unless:`) surviving alongside a
          # blank nested `if:` still gates the entry — relaxable.
          #
          # The "some gate exists" conjunct is load-bearing: a STATICALLY nil-tolerant config (`optional:`/
          # `allow_nil:`, no gate) must NOT be relaxed. Static tolerance does not skip a required child's
          # validators (a nil optional parent still strands a required descendant — PRO-2857), so such a
          # config stays in the subset for node_optional?'s subtree-stranding test to apply; dropping it would
          # vacuously (`[].all?`) mark the node omittable and lose that test. Only a GATE — which skips the
          # gated check entirely when closed — genuinely relaxes requiredness. Own-level emission is
          # unaffected (this governs ancestor propagation only; see annotate_node!).
          def requiredness_conditionally_relaxable?(config)
            gate_keys = Internal::FieldConfig::CONDITIONAL_GATE_KEYS
            decl_gates = config.validations.slice(*gate_keys)
            # `entries` are the real VALIDATORS — shared options (strict:, on:, …) aren't validators and
            # must not be mistaken for a nil-rejecting one (see nil_accepted?/validator_entries).
            entries = Axn::Validation::Base.validator_entries(config.validations)

            some_gate = decl_gates.any? || entries.any? { |_key, opt| entry_self_gated?(opt) }
            return false unless some_gate

            shared = shared_validation_options(config.validations)
            entries.all? do |key, opt|
              nil_tolerant_validation?(key, opt, shared) || entry_effective_gate_keys(opt, decl_gates).any?
            end
          end

          # The declaration-wide options every entry of a config rides alongside — the tier the per-entry
          # judgments resolve against. The slice itself is Validation::Base's one definition, so a judgment made
          # from a bare validations bag (the declaration guards, before any config exists) reads the same tier.
          def shared_validation_options(validations)
            Axn::Validation::Base.shared_validation_options(validations)
          end

          def nil_tolerant_validation?(key, opt, declaration_options) = Axn::Validation::Base.nil_tolerant_validation?(key, opt, declaration_options)
          def set_includes_nil?(opt) = Axn::Validation::Base.set_includes_nil?(opt)
          def validator_entry_options(entry) = Axn::Validation::Base.validator_entry_options(entry)

          # An entry's options as `validates` will hand them over — the declaration-wide shared options with the
          # entry's own merged on top, so a shared tolerance is judged here exactly as at runtime.
          def effective_entry_options(entry, declaration_options) = Axn::Validation::Base.effective_entry_options(entry, declaration_options)

          def nil_allowed?(config)
            nil_tolerance_rescues_absence?(config)
          end

          # Whether the TYPE validator itself tolerates a blank value (`type: :uuid, allow_blank: true`
          # folds `allow_blank` into the type validator's options). Only the type validator's own option
          # matters for dropping `format: "uuid"` — a blank-tolerant `length:`/other validator doesn't make
          # `TypeValidator` accept `""`, so the format must stay.
          def type_allows_blank?(config)
            effective_entry_options(config.validations[:type], shared_validation_options(config.validations))[:allow_blank] == true
          end

          # Strip `format: "uuid"` from anyOf members: a blank-tolerant uuid accepts "" at runtime, which a
          # strict `format: uuid` validator would reject (mirrors the scalar-type relaxation above).
          def drop_uuid_format(members)
            members.map { |m| m[:format] == "uuid" ? m.except(:format) : m }
          end
        end
      end
    end
  end
end
