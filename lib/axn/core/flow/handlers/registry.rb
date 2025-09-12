# frozen_string_literal: true

module Axn
  module Core
    module Flow
      module Handlers
        # Small, immutable, copy-on-write registry keyed by event_type.
        # Stores arrays of entries (handlers/interceptors) in insertion order.
        #
        # NOTE: serves different need than user-mutable e.g. Axn::Async::Adapters
        class Registry
          def self.empty = new({})

          def initialize(index)
            # Freeze arrays and the index for immutability
            @index = index.transform_values { |arr| Array(arr).freeze }.freeze
          end

          # Always register most-recent-first (last-defined wins). Simpler mental model.
          def register(event_type:, entry:)
            key = event_type.to_sym
            existing = Array(@index[key])
            updated = [entry] + existing
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
