# frozen_string_literal: true

module Actions
  module EnqueueAll
    class Tester
      include Axn

      module InstanceHelpers
        def instance_helper = "instance_helper"

        def self.included(base)
          base.async :sidekiq
        end
      end

      module ClassHelpers
        def class_helper = "class_helper"
      end

      include InstanceHelpers
      extend ClassHelpers

      expects :number

      error "bad times"

      def call
        info "Action executed: I was called with number: #{number} | #{instance_helper} | #{self.class.class_helper}"
      end

      axn :enqueue_all, superclass: Object, expose_return_as: :value, include: InstanceHelpers, extend: ClassHelpers do |max:|
        info "EnqueueAll block: instance_helper=#{instance_helper}, class_helper=#{self.class.class_helper}"

        1.upto(max).map do |i|
          ::Actions::EnqueueAll::Tester.call_async(number: i)
        end
      end
    end
  end
end
