# frozen_string_literal: true

require "axn"

module Actions
  class TestActionActiveJob
    include Axn

    async :active_job
    expects :name, :age

    def call
      result = "Hello, #{name}! You are #{age} years old."
      puts "Action executed: #{result}"
      result
    end
  end
end
