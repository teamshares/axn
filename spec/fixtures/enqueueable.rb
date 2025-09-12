# frozen_string_literal: true

# These classes are only used to test Enqueueable

class TestEnqueueableInteractor
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

class AnotherEnqueueableInteractor
  include Axn

  async :sidekiq do
    queue "default"
    retry_count 10
    retry_queue "low"
  end

  expects :foo

  def call
    puts "Another Interactor: #{foo}"
  end
end
