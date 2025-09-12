# frozen_string_literal: true

require "axn"

module Actions
  class TestActionSidekiqGlobalId
    include Axn

    async :sidekiq
    expects :name, :user

    def call
      info "Hello, #{name}! User: #{user.class}"
    end
  end
end
