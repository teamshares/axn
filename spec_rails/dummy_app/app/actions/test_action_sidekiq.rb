# frozen_string_literal: true

require "axn"

module Actions
  class TestActionSidekiq
    include Axn

    async :sidekiq
    expects :name, :age

    def call
      "Hello, #{name}! You are #{age} years old."
    end
  end
end
