# frozen_string_literal: true

require "axn"
require "axn/async/adapters/sidekiq"

module Actions
  class FailingActionSidekiq
    include Axn

    async :sidekiq
    expects :name

    def call
      raise StandardError, "Intentional failure"
    end
  end
end
