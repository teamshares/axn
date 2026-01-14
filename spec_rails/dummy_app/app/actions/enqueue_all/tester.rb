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

      # Use enqueues_each to iterate over a fixed range
      enqueues_each :number, from: -> { [1, 2, 3] }
    end
  end
end
