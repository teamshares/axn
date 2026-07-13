# frozen_string_literal: true

module Axn
  module Testing
    module SpecHelpers
      def build_axn(&block)
        action = Class.new.send(:include, Axn)
        action.class_eval(&block) if block
        action
      end

      # Block-scoped injection for `on: :ambient_context` inputs. Swaps the global
      # `ambient_context_provider` for the block, so the action under test AND any nested
      # actions it calls resolve their ambient subfields from `attrs` — without touching
      # `Current` / any `CurrentAttributes`. Restores the previous provider on exit (safe
      # under nesting and when the block raises). An explicit `ambient_context:` kwarg on a
      # specific call still overrides `attrs` (existing precedence in `_resolve_ambient_context`).
      def with_ambient_context(**attrs)
        previous = Axn.config.ambient_context_provider
        Axn.config.ambient_context_provider = -> { attrs }
        yield
      ensure
        Axn.config.ambient_context_provider = previous
      end
    end
  end
end

if defined?(RSpec)
  RSpec.configure do |config|
    config.include Axn::Testing::SpecHelpers
  end
end
