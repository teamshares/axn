# frozen_string_literal: true

module Action
  module Core
    module Flow
      module Handlers
        # Small, immutable, copy-on-write registry keyed by event_type.
        # Stores arrays of entries (handlers/interceptors) in insertion order.
        class Registry
          def self.empty = new({})

          def initialize(index)
            # Freeze arrays and the index for immutability
            @index = index.transform_values { |arr| Array(arr).freeze }.freeze
          end

          def register(event_type:, entry:, prepend: true)
            key = event_type.to_sym
            existing = Array(@index[key])
            updated = prepend ? [entry] + existing : existing + [entry]
            self.class.new(@index.merge(key => updated.freeze))
          end

          def for(event_type)
            Array(@index[event_type.to_sym])
          end

          def empty?
            @index.empty?
          end

          protected

          attr_reader :index
        end
      end
    end
  end
end
