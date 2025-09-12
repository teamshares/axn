# frozen_string_literal: true

# These classes are only used to test Async

class TestAsyncAction
  include Axn

  async :sidekiq do
    queue "default"
    retry_count 10
    retry_queue "low"
  end

  expects :name, :address

  def call
    puts "Name: #{name}"
    puts "Address: #{address}"
  end
end

class AnotherAsyncAction
  include Axn

  async :sidekiq do
    queue "default"
    retry_count 10
    retry_queue "low"
  end

  expects :foo

  def call
    puts "Another Action: #{foo}"
  end
end
