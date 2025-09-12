# frozen_string_literal: true

module Actions
  class FailingActionSidekiq
    include Axn

    async :sidekiq
    expects :name

    def call
      info "About to fail with name: #{name}"
      raise StandardError, "Intentional failure"
    end
  end
end
