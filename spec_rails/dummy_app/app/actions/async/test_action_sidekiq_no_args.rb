# frozen_string_literal: true

module Actions
  module Async
    class TestActionSidekiqNoArgs
      include Axn

      async :sidekiq

      def call
        info "Action executed with no arguments"
      end
    end
  end
end
