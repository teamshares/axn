# frozen_string_literal: true

module Actions
  module Integration
    # Action that uses fail! (business logic failure) - should NOT retry or report
    class FailingWithFail
      include Axn

      async # Uses default adapter set at boot time
      expects :name

      def call
        info "About to fail! with name: #{name}"
        fail! "Business logic failure: #{name}"
      end
    end
  end
end
