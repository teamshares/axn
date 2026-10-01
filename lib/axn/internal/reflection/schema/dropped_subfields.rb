# frozen_string_literal: true

require "axn/internal/subfield_tree"
require "axn/internal/reflection/schema/vocabulary"

module Axn
  module Internal
    module Reflection
      module Schema
        # The drop pass: which deep subfield configs have no JSON-object representation because a node their path
        # passes through cannot hold object properties. It asks `Nestability` and `shape_members_at` the same
        # questions emission asks, so a config the document leaves out is exactly one the emitter blocks.
        module DroppedSubfields
          include Vocabulary
        end
      end
    end
  end
end
