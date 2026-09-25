# frozen_string_literal: true

module Axn
  module Internal
    module Reflection
      module Schema
        # The small fixed shapes more than one part of the emitter writes. They live in their own file for
        # the same reason every other constant does not: a table read from two files is a shared vocabulary,
        # and the alternative — one file reaching into another's namespace — is the drift these exist to
        # prevent. Frozen, because the emitter hands these out into schemas a consumer may hold.
        module Vocabulary
          # Satisfied by no value — what an unsatisfiable intersection projects to.
          EMPTY_ENUM = [].freeze

          NULL_BRANCH = { type: "null" }.freeze

          # PRO-3441. Where a map's `of: { values: }` axis schema and its own exempt key set ride on a
          # property until `Schema#finalize_residues!`'s final tree sweep conjoins them into every
          # colliding key the axis's own `shape:` doesn't name — see that method and
          # `Schema#conjoin_map_value_axes`. Lives here, not directly on `Schema`, because `Contents`
          # (`map_values_schema`) writes it and only ever `require`s this file, not `schema.rb` itself —
          # the same reason `EMPTY_ENUM`/`NULL_BRANCH` live here rather than on `Schema` directly
          # (`standalone_require_spec.rb` catches a reference the referencing file's own requires can't
          # satisfy).
          MAP_VALUE_EXEMPT_KEY = :__axn_map_value_exempt

          # The residue sentences a gated check left out of the schema is named with. Here rather than on
          # `Schema` for the reason above: `Contents` names a gated shape member's requirement and a gated bag
          # entry too.
          # Every blank a JSON document can carry. `false` is among them: ActiveSupport counts it blank, which
          # is what an ungated `presence:` rejects — and so is `nil`, which is why it is listed here even
          # though `reject_null!` independently strips a null branch on the nested-child path. The floor is
          # only ever restored where some config's ungated `presence:` rejects blank, and such a config also
          # answers `nil_allowed?` false, so naming nil here cannot narrow a nil-tolerant position; it closes
          # the axis path, where that separate null pass does not reach.
          #
          # Deep-frozen on the same terms as `BLANK_BRANCH_WITNESS`, and for the same measured reason: these
          # members ride INSIDE an emitted schema, schemas are rebuilt per call and caller-mutable, and a
          # shared mutable `[]`/`{}` lets one consumer's mutation reach every schema emitted afterwards —
          # appending to one action's floor changed a DIFFERENT action class's `enum` to `["", [:x], {}, false,
          # nil]`. Freezing rather than copying is what the neighbours do, so a mutating consumer gets a
          # FrozenError instead of silently corrupting every later schema.
          #
          # Here rather than on `Schema` because `Contents` floors an untyped bag position with it.
          BLANK_WIRE_VALUES = ["", [].freeze, {}.freeze, false, nil].freeze

          GATED_RESIDUE = "a conditional validator at this position applies only on the calls " \
                          "its condition opens"

          GATED_REQUIRED_RESIDUE = "required on the calls its condition opens"
        end
      end
    end
  end
end
