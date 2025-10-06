# frozen_string_literal: true

module Actions
  module EnqueueAll
    class Tester
      include Axn

      async :sidekiq

      def instance_helper = "instance_helper"
      def self.class_helper = "class_helper"

      expects :number

      error "bad times"

      def call
        info "Action executed: I was called with number: #{number} | #{instance_helper} | #{self.class.class_helper}"
      end

      axn :enqueue_all, superclass: Object, async: :sidekiq, expose_return_as: :value do |max:|
        1.upto(max).map do |i|
          ::Actions::EnqueueAll::Tester.call_async(number: i)
        end
      end
    end
  end
end
