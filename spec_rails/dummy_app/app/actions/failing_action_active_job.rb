# frozen_string_literal: true

require "axn"

module Actions
  class FailingActionActiveJob
    include Axn

    async :active_job
    expects :name

    def call
      raise StandardError, "Intentional failure"
    end
  end
end
