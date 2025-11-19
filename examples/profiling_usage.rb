# frozen_string_literal: true

# Example: Using axn profiling with Vernier
#
# To use profiling, you need to:
# 1. Add 'vernier' to your Gemfile: gem 'vernier', '~> 0.1'
# 2. Enable profiling on specific actions with the use :vernier strategy

require_relative "../lib/axn"

# Example 1: Simple profiling
class SimpleAction
  include Axn

  # Enable profiling for this action
  use :vernier

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
  use :vernier, if: -> { debug_mode }

  expects :name, :debug_mode

  def call
    # Simulate some work
    sleep(0.01)
    "Hello, #{name}!"
  end
end

# Example 3: Profiling with custom options
class CustomOptionsAction
  include Axn

  # Profile with custom sample rate and output directory
  use :vernier,
      if: -> { debug_mode },
      sample_rate: 0.5,
      output_dir: "custom/profiles"

  expects :name, :debug_mode

  def call
    # Simulate some work
    sleep(0.01)
    "Hello, #{name}!"
  end
end

# Example 4: Symbol-based condition
class SymbolConditionAction
  include Axn

  # Use a method to determine when to profile
  use :vernier, if: :should_profile?

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

# Example 5: Callable condition
class CallableConditionAction
  include Axn

  # Use a callable object to determine when to profile
  use :vernier, if: -> { name.include?("Action") }

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
puts "2. Enable profiling on actions: use :vernier"
puts "3. Run your actions normally - they'll be profiled when conditions are met"
puts "4. View profiles in Firefox Profiler: https://profiler.firefox.com/"
