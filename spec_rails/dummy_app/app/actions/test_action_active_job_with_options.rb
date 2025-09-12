# frozen_string_literal: true

module Actions
  class TestActionActiveJobWithOptions
    include Axn

    async :active_job do
      queue_as :high_priority
      retry_on StandardError, wait: 5.seconds, attempts: 3
    end

    expects :name, :age

    def call
      info "Hello, #{name}! You are #{age} years old."
    end
  end
end
