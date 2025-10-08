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
        puts "Action executed: I was called with number: #{number} | #{instance_helper} | #{self.class.class_helper}"
      end

      enqueue_all_via do |max:|
        puts "About to enqueue_all: max: #{max} | #{instance_helper} | #{self.class.class_helper}"
        raise "don't like 4s" if max == 4

        1.upto(max).map do |i|
          call_async(number: i)
        end
      end
    end
  end
end
