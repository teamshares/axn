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

# Example 3: Sidekiq async with configuration using kwargs (terser syntax)
if defined?(Sidekiq)
  class SidekiqAction
    include Axn

    async :sidekiq, queue: "high_priority", retry: 5, retry_queue: "low"

    expects :name

    def call
      "Hello, #{name}!"
    end
  end

  # Example 4: Sidekiq async with configuration using block (traditional syntax)
  class SidekiqActionWithBlock
    include Axn

    async :sidekiq do
      sidekiq_options queue: "high_priority", retry: 5, retry_queue: "low"
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
  puts "Sidekiq action (kwargs): #{SidekiqAction.call(name: "World")}"
  puts "Sidekiq action (block): #{SidekiqActionWithBlock.call(name: "World")}"
  puts "SimpleSidekiq action: #{SimpleSidekiqAction.call(name: "World")}"

  # Async execution examples
  puts "\n=== Async Execution Examples ==="
  puts "Immediate execution:"
  # SidekiqAction.call_async(name: 'World') # Would enqueue the job immediately

  puts "Delayed execution (wait 1 hour):"
  # SidekiqAction.call_async(name: 'World', _async: { wait: 1.hour }) # Would enqueue for 1 hour from now

  puts "Scheduled execution (wait until specific time):"
  # SidekiqAction.call_async(name: 'World', _async: { wait_until: 1.hour.from_now }) # Would enqueue for specific time

  puts "User parameter named _async (treated as regular parameter):"
  # SidekiqAction.call_async(name: 'World', _async: 'user_value') # Would pass _async as regular parameter
else
  puts "Sidekiq not available - would raise LoadError"
end

# ActiveJob actions (when ActiveJob is available)
if defined?(ActiveJob)
  puts "ActiveJob action: #{ActiveJobAction.call(name: "World")}"

  # Async execution examples
  puts "\n=== ActiveJob Async Execution Examples ==="
  puts "Immediate execution:"
  # ActiveJobAction.call_async(name: 'World') # Would enqueue the job immediately

  puts "Delayed execution (wait 1 hour):"
  # ActiveJobAction.call_async(name: 'World', _async: { wait: 1.hour }) # Would enqueue for 1 hour from now

  puts "Scheduled execution (wait until specific time):"
  # ActiveJobAction.call_async(name: 'World', _async: { wait_until: 1.hour.from_now }) # Would enqueue for specific time
else
  puts "ActiveJob not available - would raise LoadError"
end

puts "\n=== Configuration Examples ==="
puts "Default async setting: #{Axn.config.default_async}"

if defined?(Sidekiq)
  puts "SidekiqAction queue: #{SidekiqAction.queue}"
  puts "SidekiqAction sidekiq options: #{SidekiqAction.sidekiq_options_hash}"
end
