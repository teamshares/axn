# frozen_string_literal: true

require "axn/mountable/descriptor"

module Axn
  module Mountable
    module Helpers
      # Helper class for mounting actions via strategies
      class Mounter
        # Mount an action using the specified strategy
        #
        # @param target [Class] The target class to mount the action to
        # @param as [Symbol] The strategy to use (:axn, :method, :step, :enqueuer)
        # @param name [Symbol] The name of the action
        # @param axn_klass [Class, nil] Optional existing action class
        # @param kwargs [Hash] Additional strategy-specific options
        # @param block [Proc] The action block
        def self.mount_via_strategy(
          target:,
          as: :axn,
          name: nil,
          axn_klass: nil,
          **kwargs,
          &block
        )
          descriptor = Descriptor.new(name:, axn_klass:, as:, block:, kwargs:)
          target._mounted_axn_descriptors += [descriptor]
          descriptor.mount(target:)
        end
      end
    end
  end
end
