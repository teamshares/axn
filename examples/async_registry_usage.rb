# frozen_string_literal: true

require_relative "../lib/axn"

# Example usage of the new Axn async registry system

# Example 1: Using built-in adapters (automatically registered)
class BuiltInAction
  include Axn

  async false

  expects :name

  def call
    "Hello, #{name}!"
  end
end

# Example 2: Registering a custom async adapter
# Note: Adapters must implement _enqueue_async_job and must NOT override call_async.
# The base call_async handles notifications, logging, and delegates to _enqueue_async_job.
module CustomAsyncAdapter
  extend ActiveSupport::Concern

  included do
    puts "Custom async adapter included!"
  end

  class_methods do
    private

    # Implement adapter-specific enqueueing logic here.
    # The base call_async will handle notifications and logging before calling this.
    def _enqueue_async_job(kwargs)
      puts "Custom async execution: #{kwargs.inspect}"
      # Simulate async execution
      Thread.new do
        sleep(0.1) # Simulate background processing
        puts "Background task completed: #{call(**kwargs)}"
      end
    end
  end
end

# Register the custom adapter
Axn::Async::Adapters.register(:custom, CustomAsyncAdapter)

# Example 3: Using the custom adapter
class CustomAction
  include Axn

  async :custom

  expects :name

  def call
    "Custom async: Hello, #{name}!"
  end
end

# Example 4: Listing available adapters
puts "=== Available Async Adapters ==="
Axn::Async::Adapters.all.each do |name, adapter|
  puts "#{name}: #{adapter.name}"
end

puts "\n=== Usage Examples ==="

# Built-in adapter usage
puts "Built-in disabled adapter: #{BuiltInAction.call(name: 'World')}"

# Custom adapter usage
puts "Custom adapter:"
CustomAction.call_async(name: "World")

# Wait a moment for the background thread to complete
sleep(0.2)

puts "\n=== Registry Information ==="
puts "Total adapters: #{Axn::Async::Adapters.all.size}"
puts "Built-in adapters: #{Axn::Async::Adapters.built_in.keys}"
puts "All adapters: #{Axn::Async::Adapters.all.keys}"
