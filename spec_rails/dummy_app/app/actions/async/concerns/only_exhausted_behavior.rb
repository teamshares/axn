# frozen_string_literal: true

module Actions
  module Async
    module Concerns
      # Shared behavior for actions with per-class :only_exhausted exception reporting.
      # Include this in adapter-specific action classes to test the override.
      module OnlyExhaustedBehavior
        extend ActiveSupport::Concern

        included do
          async_exception_reporting :only_exhausted

          expects :name

          define_method(:call) do
            info "Action executed with only_exhausted: #{name}"
            raise StandardError, "Intentional failure for retry testing"
          end
        end
      end
    end
  end
end
