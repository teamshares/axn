# frozen_string_literal: true

module Actions
  module Async
    # Declares both a high-card `tag` and a bounded `dimension`, plus an inbound default,
    # to exercise enqueue-time facet → Sidekiq job tag surfacing (PRO-2855).
    class TestActionSidekiqTagged
      include Axn
      async :sidekiq

      expects :company_id
      expects :plan, default: "free"

      tag(:company_id) { company_id }
      dimension(:plan) { plan }

      def call; end
    end
  end
end
