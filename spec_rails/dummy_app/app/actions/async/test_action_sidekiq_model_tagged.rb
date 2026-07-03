# frozen_string_literal: true

module Actions
  module Async
    # Declares a `model:`-derived facet to exercise a real AR lookup during enqueue-time facet
    # resolution (PRO-2855): `tag(:user_name)` reads `user`, which lazily triggers `User.find`
    # (facade.rb) — only because the resolver reads it, not for every enqueue.
    class TestActionSidekiqModelTagged
      include Axn
      async :sidekiq

      expects :user, model: User

      tag(:user_name) { user.name }

      def call; end
    end
  end
end
