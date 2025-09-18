# frozen_string_literal: true

# Example: Using axn profiling with Vernier
#
# To use profiling, you need to:
# 1. Add 'vernier' to your Gemfile: gem 'vernier', '~> 0.1'
# 2. Enable profiling in your configuration
# 3. Enable profiling on specific actions

require_relative "../lib/axn"

# Configure profiling
Axn.configure do |c|
  c.profiling_enabled = true
  c.profiling_sample_rate = 0.1 # Profile 10% of executions
  c.profiling_output_dir = "tmp/profiles"
end

# Example 1: Simple profiling
class SimpleAction
  include Axn

  # Enable profiling for this action
  profile

  expects :name

  def call
    # Simulate some work
    sleep(0.01)
    "Hello, #{name}!"
  end
end

# Example 2: Conditional profiling
class ConditionalAction
  include Axn

  # Only profile when debug_mode is true
  profile if: -> { debug_mode }

  expects :name, :debug_mode

  def call
    # Simulate some work
    sleep(0.01)
    "Hello, #{name}!"
  end
end

# Example 3: Symbol-based condition
class SymbolConditionAction
  include Axn

  # Use a method to determine when to profile
  profile if: :should_profile?

  expects :name, :user_id

  def call
    # Simulate some work
    sleep(0.01)
    "Hello, #{name}!"
  end

  private

  def should_profile?
    # Only profile for specific users
    user_id == 123
  end
end

# Example 4: Callable condition
class CallableConditionAction
  include Axn

  # Use a callable object to determine when to profile
  profile if: -> { name.include?("Action") }

  expects :name

  def call
    # Simulate some work
    sleep(0.01)
    "Hello, #{name}!"
  end
end

puts "Profiling examples loaded!"
puts "To use profiling:"
puts "1. Add 'vernier' to your Gemfile"
puts "2. Enable profiling: Axn.config.profiling_enabled = true"
puts "3. Enable profiling on actions: MyAction.profile"
puts "4. Run your actions normally - they'll be profiled when conditions are met"
puts "5. View profiles in Firefox Profiler: https://profiler.firefox.com/"
