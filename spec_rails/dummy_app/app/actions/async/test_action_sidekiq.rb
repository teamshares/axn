# frozen_string_literal: true

module Actions
  module Async
    class TestActionSidekiq
      include Axn

      async :sidekiq
      expects :name, :age

      def call
        info "Action executed: Hello, #{name}! You are #{age} years old."
      end
    end
  end
end
