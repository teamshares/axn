# frozen_string_literal: true

require_relative "../lib/axn"

# Example usage of the new Axn async interface

# Example 1: Disabled async (default)
class DisabledAction
  include Axn

  expects :name

  def call
    "Hello, #{name}!"
  end
end

# Example 2: Explicitly disabled async
class ExplicitlyDisabledAction
  include Axn

  async false

  expects :name

  def call
    "Hello, #{name}!"
  end
end

# Example 3: Sidekiq async with configuration (only if Sidekiq is available)
if defined?(Sidekiq)
  class SidekiqAction
    include Axn

    async :sidekiq do
      queue "high_priority"
      retry_count 5
      retry_queue "low"
    end

    expects :name

    def call
      "Hello, #{name}!"
    end
  end

  # Example 5: Sidekiq async without configuration
  class SimpleSidekiqAction
    include Axn

    async :sidekiq

    expects :name

    def call
      "Hello, #{name}!"
    end
  end
end

# Example 4: ActiveJob async with configuration (only if ActiveJob is available)
if defined?(ActiveJob)
  class ActiveJobAction
    include Axn

    async :active_job do
      queue_as "high_priority"
      retry_on StandardError, attempts: 3
      priority 10
    end

    expects :name

    def call
      "Hello, #{name}!"
    end
  end
end

# Usage examples:
puts "=== Usage Examples ==="

# Disabled actions raise NotImplementedError
begin
  DisabledAction.call_async(name: "World")
rescue NotImplementedError => e
  puts "Disabled action: #{e.message}"
end

begin
  ExplicitlyDisabledAction.call_async(name: "World")
rescue NotImplementedError => e
  puts "Explicitly disabled action: #{e.message}"
end

# Sidekiq actions (when Sidekiq is available)
if defined?(Sidekiq)
  puts "Sidekiq action: #{SidekiqAction.call(name: "World")}"
  puts "SimpleSidekiq action: #{SimpleSidekiqAction.call(name: "World")}"
  # SidekiqAction.call_async(name: 'World') # Would enqueue the job
else
  puts "Sidekiq not available - would raise LoadError"
end

# ActiveJob actions (when ActiveJob is available)
if defined?(ActiveJob)
  puts "ActiveJob action: #{ActiveJobAction.call(name: "World")}"
  # ActiveJobAction.call_async(name: 'World') # Would enqueue the job
else
  puts "ActiveJob not available - would raise LoadError"
end

puts "\n=== Configuration Examples ==="
puts "Default async setting: #{Axn.config.default_async}"

if defined?(Sidekiq)
  puts "SidekiqAction queue: #{SidekiqAction.queue}"
  puts "SidekiqAction sidekiq options: #{SidekiqAction.sidekiq_options_hash}"
end
