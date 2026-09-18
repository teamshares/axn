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
        end
      end
    end
  end
end
