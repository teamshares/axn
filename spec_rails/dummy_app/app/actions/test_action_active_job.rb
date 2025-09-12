# frozen_string_literal: true

require "axn"

module Actions
  class TestActionActiveJob
    include Axn

    async :active_job
    expects :name, :age

    def call
      "Hello, #{name}! You are #{age} years old."
    end
  end
end
