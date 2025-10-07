# frozen_string_literal: true

require "axn/attachable/attachment_strategies"
require "axn/attachable/descriptor"
require "axn/attachable/descriptor_helpers/validator"
require "axn/attachable/descriptor_helpers/action_class_builder"
require "axn/attachable/descriptor_helpers/namespace_manager"

module Axn
  # Attachable provides functionality for attaching actions to classes
  #
  # ## Inheritance Behavior
  #
  # By default, attached actions inherit from their target class, allowing them to access
  # target methods and share behavior. However, the `step` strategy defaults to inheriting
  # from `Object` to avoid field conflicts with `expects` and `exposes` declarations.
  #
  # ### Controlling Inheritance
  #
  # You can control inheritance behavior using the `_inherit_from_target` parameter:
  #
  # - `_inherit_from_target: true` - Always inherit from target class
  # - `_inherit_from_target: false` - Always inherit from Object
  # - `_inherit_from_target: nil` - Use strategy-specific defaults
  #
  # ::: danger Experimental Feature
  # The `_inherit_from_target` parameter is experimental and likely to change in future
  # versions. This is why the parameter name is underscore-prefixed. Use with caution
  # and be prepared to update your code when this feature stabilizes.
  # :::
  #
  # @example Default inheritance behavior
  #   class MyClass
  #     include Axn
  #
  #     def shared_method
  #       "from target"
  #     end
  #   end
  #
  #   # axn and method strategies inherit from target by default
  #   MyClass.axn :my_action do
  #     expose :result, shared_method  # Can access target methods
  #   end
  #
  #   # step strategy inherits from Object by default
  #   MyClass.step :my_step do
  #     expose :result, "step result"  # Cannot access target methods
  #   end
  #
  # @example Explicit inheritance control
  #   # Force step to inherit from target
  #   MyClass.step :my_step, _inherit_from_target: true do
  #     expose :result, shared_method  # Can now access target methods
  #   end
  #
  #   # Force axn to inherit from Object
  #   MyClass.axn :my_action, _inherit_from_target: false do
  #     expose :result, "standalone"  # Cannot access target methods
  #   end
  module Attachable
    extend ActiveSupport::Concern

    def self.included(base)
      base.class_eval do
        class_attribute :_attached_axn_descriptors, default: []
      end

      AttachmentStrategies.all.each do |(_name, klass)|
        base.extend klass::DSL if klass.const_defined?(:DSL)
      end
    end

    class_methods do
      def attach_axn(
        as: :axn,
        name: nil,
        axn_klass: nil,
        **kwargs,
        &block
      )
        descriptor = Descriptor.new(name:, axn_klass:, as:, block:, kwargs:)
        self._attached_axn_descriptors += [descriptor]
        descriptor.mount(target: self)
      end
    end
  end
end
