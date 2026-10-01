# frozen_string_literal: true

# LITERAL_RENDERINGS names each literal class it reads a rendering through.
require "bigdecimal"
require "date"
require "time"
# A mentioned fragment is encoded only after it has been reduced to plain primitives.
require "json"

require "axn/internal/text"
require "axn/internal/rendering"
require "axn/internal/identity"
require "axn/internal/reflection/schema/vocabulary"

module Axn
  module Internal
    module Reflection
      module Schema
        # How a residue names what it could not emit: a declined fragment rendered verbatim, a caller's literal
        # reduced to something JSON can carry without asking it anything, and an author's description closed as a
        # sentence and joined to the prose after it. Every read here is bound or guarded, so composing a report
        # never runs a caller's code.
        module Mentions
          include Vocabulary
        end
      end
    end
  end
end
