# frozen_string_literal: true

module Axn
  module Core
    module Contract
      # Per-class cache of the one-off validator classes `Axn::Validation::Fields.validator_class_for`
      # would otherwise compile fresh on every `.call` for every declared top-level field and subfield
      # (PRO-3050). Mirrors `Redaction#_contract_redaction` exactly: outer key is `equal?` on the three
      # copy-on-write config arrays (self-invalidating on any redeclaration, subclass, or
      # Mountable/Factory rebuild — see redaction.rb's doctrine comment, which this reuses verbatim),
      # inner key is the `FieldConfig`/`ShapeConfig` object's own IDENTITY.
      #
      # Identity, never `validations`: a config's `#validations` is not a stable object across reads.
      # `Executor#_with_effective_coerce` mints a fresh merged Hash every call when `coerce_input_types`
      # resolves on, and a config reached only via `internal_field_configs=`/`subfield_configs=` (never
      # declared) can answer a DIFFERENT Hash on every `#validations` read (stored_shape_traversal_spec's
      # generative member) — keying on either would never hit, or worse, would grow the table forever.
      # The config object itself has neither problem: it is a frozen `Data`, minted once and replaced
      # wholesale on redeclaration, never mutated.
      #
      # The SAME config can legitimately need two different compiled classes in one process — the
      # `coerce_input_types` gate is per-call/per-class/global and can flip between calls — so the inner
      # table is keyed on [config, coerce] rather than on config alone.
      module ValidatorClassCache
        def _validator_class_cache
          internals = internal_field_configs
          externals = external_field_configs
          subfields = subfield_configs
          memo = @_axn_validator_class_cache
          return memo if memo&.current?(internals, externals, subfields)

          @_axn_validator_class_cache = ValidatorClassCacheTable.new(internals:, externals:, subfields:)
        end

        # The compiled validator class for one config under one coerce state, built once per class per
        # (config, coerce) pair and reused across every `.call`. `effective_validations` is the caller's
        # already-resolved Hash (with `_with_effective_coerce` applied if relevant) — computed by the
        # caller regardless of hit/miss, same as before this cache existed, so a hit only saves the
        # `Class.new` + `validates` compilation, not the coerce merge.
        def _cached_validator_class_for(config:, effective_validations:, coerce:)
          _validator_class_cache.fetch(config:, coerce:) do
            Axn::Validation::Fields.validator_class_for(field: config.field, validations: effective_validations)
          end
        end
      end

      # The table `_validator_class_cache` hands out. Mutable (so not a `Data`), one Hash slot written
      # once per (config, coerce) pair. `||=` is safe here (unlike `_contract_redaction`'s `dynamic`
      # flag): a compiled Class is always truthy, so there is no false/nil tri-state to guard.
      class ValidatorClassCacheTable
        def initialize(internals:, externals:, subfields:)
          @internals = internals
          @externals = externals
          @subfields = subfields
          # Per config, by identity — a FieldConfig/ShapeConfig defines no `hash`/`eql?` axn would want
          # to run (its `validations` Hash may hold a caller-supplied option container that does), and
          # identity is the right question anyway: the stored config is the one axn built.
          @classes = {}.compare_by_identity
        end

        def current?(internals, externals, subfields)
          @internals.equal?(internals) && @externals.equal?(externals) && @subfields.equal?(subfields)
        end

        def fetch(config:, coerce:)
          by_coerce = (@classes[config] ||= {})
          by_coerce[coerce] ||= yield
        end
      end
    end
  end
end
