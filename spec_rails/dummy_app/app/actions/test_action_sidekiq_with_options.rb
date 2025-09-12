# frozen_string_literal: true

require "axn"
require "axn/async/adapters/sidekiq"

module Actions
  class TestActionSidekiqWithOptions
    include Axn

    async :sidekiq do
      sidekiq_options queue: "high_priority", retry: 3
    end

    expects :name, :age

    def call
      info "Hello, #{name}! You are #{age} years old."
    end
  end
end
