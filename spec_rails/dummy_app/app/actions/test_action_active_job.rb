# frozen_string_literal: true

module Actions
  class TestActionActiveJob
    include Axn

    async :active_job
    expects :name, :age

    def call
      info "Action executed: Hello, #{name}! You are #{age} years old."
    end
  end
end
