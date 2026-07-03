# frozen_string_literal: true

module Actions
  module Async
    # Declares a `tag` and a `dimension` under the SAME facet name, to verify both survive to
    # Sidekiq as two distinct `name:value` job tags (neither clobbers the other). See PRO-2855.
    class TestActionSidekiqDupFacetName
      include Axn
      async :sidekiq

      expects :account_id, :plan

      tag(:account) { account_id }
      dimension(:account) { plan }

      def call; end
    end
  end
end
