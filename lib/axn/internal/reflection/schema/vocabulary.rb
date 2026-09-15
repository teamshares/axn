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
        end
      end
    end
  end
end
