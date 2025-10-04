# frozen_string_literal: true

require "axn/attachable/attachment_strategies"
require "axn/attachable/descriptor"

module Axn
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
        _attached_axn_descriptors << descriptor
        _mount_axn_from_descriptor(descriptor)
      end

      def _mount_axn_from_descriptor(descriptor)
        descriptor.mount(target: self)
      end
    end
  end
end
