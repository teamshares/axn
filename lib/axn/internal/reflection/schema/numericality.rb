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
        end
      end
    end
  end
end
