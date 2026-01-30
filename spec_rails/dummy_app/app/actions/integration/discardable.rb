# frozen_string_literal: true

module Actions
  module Integration
    # Custom error for testing discard_on
    class DiscardableError < StandardError; end

    # Action that raises a discardable error - tests discard_on + after_discard
    # NOTE: discard_on is ActiveJob-specific, so this action is hardcoded to use
    # :active_job adapter rather than the default. This test verifies the
    # after_discard callback integration.
    class Discardable
      include Axn

      async :active_job do
        discard_on DiscardableError
      end

      expects :name

      def call
        info "About to raise discardable error with name: #{name}"
        raise DiscardableError, "This error should be discarded"
      end
    end
  end
end
