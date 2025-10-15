# frozen_string_literal: true

require "axn/mountable/inherit_profiles"
require "axn/mountable/mounting_strategies"
require "axn/mountable/descriptor"
require "axn/mountable/helpers/validator"
require "axn/mountable/helpers/class_builder"
require "axn/mountable/helpers/namespace_manager"
require "axn/mountable/helpers/mounter"

module Axn
  # Mountable provides functionality for mounting actions to classes
  #
  # ## Inheritance Behavior
  #
  # Mounted actions inherit features from their target class in different ways depending on the
  # mounting strategy. Each strategy has sensible defaults, but you can customize inheritance
  # behavior using the `inherit` parameter.
  #
  # ### Default Inheritance Modes
  #
  # - `mount_axn` and `mount_axn_method`: `:lifecycle` - Inherits hooks, callbacks, messages, and async config (but not fields)
  # - `step`: `:none` - Completely independent to avoid conflicts
  # - `enqueue_all_via`: `:async_only` - Only inherits async configuration
  #
  # ### Inheritance Profiles
  #
  # - `:lifecycle` - Inherits everything except fields (hooks, callbacks, messages, async config)
  # - `:async_only` - Only inherits async configuration
  # - `:none` - Completely standalone with no inheritance
  #
  # You can also use a hash for granular control:
  #   `inherit: { fields: false, hooks: true, callbacks: false, messages: true, async: true }`
  #
  # Available hash keys: `:fields`, `:hooks`, `:callbacks`, `:messages`, `:async`
  #
  # @example Default inheritance behavior
  #   class MyClass
  #     include Axn
  #
  #     before :log_start
  #     on_success :track_success
  #     async :sidekiq
  #   end
  #
  #   # mount_axn uses :lifecycle (inherits hooks, callbacks, messages, async)
  #   MyClass.mount_axn :my_action do
  #     # Will run log_start before and track_success after
  #   end
  #
  #   # step uses :none (completely independent)
  #   MyClass.step :my_step do
  #     # Will NOT run log_start or track_success
  #   end
  #
  #   # enqueue_all_via uses :async_only (only inherits async config)
  #   MyClass.enqueue_all_via do
  #     # Can call enqueue (uses inherited async config)
  #     # Does NOT inherit hooks, callbacks, or messages
  #   end
  #
  # @example Custom inheritance control
  #   # Override step default to inherit lifecycle
  #   MyClass.step :my_step, inherit: :lifecycle do
  #     # Will now run hooks and callbacks
  #   end
  #
  #   # Use granular control
  #   MyClass.mount_axn :my_action, inherit: { hooks: true, callbacks: false } do
  #     # Will run hooks but not callbacks
  #   end
  module Mountable
    extend ActiveSupport::Concern

    def self.included(base)
      base.class_eval do
        class_attribute :_mounted_axn_descriptors, default: []
      end

      MountingStrategies.all.each do |(_name, klass)|
        base.extend klass::DSL if klass.const_defined?(:DSL)
      end
    end
  end
end
