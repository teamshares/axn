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

        # Eagerly create action class constants for inherited descriptors
        # (e.g. allow TeamsharesAPI::Company::Axns::Get.call to work *without* having to
        # call TeamsharesAPI::Company.get! first)
        def self.inherited(subclass)
          super

          # Only process if we have inherited descriptors from parent
          return unless _mounted_axn_descriptors.any?

          # Skip if subclass doesn't respond to _mounted_axn_descriptors
          # This prevents recursion when creating action classes that inherit from target
          return unless subclass.respond_to?(:_mounted_axn_descriptors)

          # Skip if we're currently creating an action class (prevent infinite recursion)
          # This is necessary because Axn::Factory.build creates classes that inherit from
          # Axn (which includes Axn::Mountable), triggering inherited callbacks during
          # action class creation.
          superclass = subclass.superclass
          creating_for = superclass&.instance_variable_get(:@_axn_creating_action_class_for)
          return if creating_for

          # Skip if this is an action class being created (they're in the Axns namespace)
          # Action classes have names like "ParentClass::Axns::ActionName"
          subclass_name = subclass.name
          return if subclass_name&.include?("::Axns::")

          # Eagerly create constants for all inherited descriptors
          # mounted_axn_for will ensure namespace exists and create the constant
          # If a child overrides, the new descriptor will replace the constant
          _mounted_axn_descriptors.each do |descriptor|
            # This will create the constant if it doesn't exist
            descriptor.mounted_axn_for(target: subclass)
            # Also define namespace methods on the child's namespace
            # This ensures TeamsharesAPI::Company::Axns.get works even though
            # the descriptor was originally mounted on TeamsharesAPI::Base
            # We use define_namespace_methods instead of mount_to_namespace to
            # avoid re-registering the constant (which is already created above)
            descriptor.mount_strategy.define_namespace_methods(descriptor:, target: subclass)
          end
        end
      end

      MountingStrategies.all.each do |(_name, klass)|
        base.extend klass::DSL if klass.const_defined?(:DSL)
      end
    end
  end
end
