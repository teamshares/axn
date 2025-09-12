# frozen_string_literal: true

require "axn"
require "axn/async/adapters/sidekiq"

module Actions
  class TestActionSidekiq
    include Axn

    async :sidekiq
    expects :name, :age

    def call
      info "Action executed: Hello, #{name}! You are #{age} years old."
    end
  end
end
