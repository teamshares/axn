# frozen_string_literal: true

module Actions
  module Async
    class TestActionSidekiqGlobalId
      include Axn

      async :sidekiq
      expects :name, :user

      def call
        info "Hello, #{name}! User: #{user.class}"
      end
    end
  end
end
