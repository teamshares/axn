# frozen_string_literal: true

module Actions
  module Async
    # Carries a static sidekiq_options tag alongside a facet, to verify the two are unioned
    # (not clobbered) at enqueue.
    class TestActionSidekiqTaggedWithStatic
      include Axn
      async :sidekiq do
        sidekiq_options tags: ["static"]
      end

      expects :company_id
      tag(:company_id) { company_id }

      def call; end
    end
  end
end
