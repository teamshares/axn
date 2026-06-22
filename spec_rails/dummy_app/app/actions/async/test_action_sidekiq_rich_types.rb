# frozen_string_literal: true

module Actions
  module Async
    class TestActionSidekiqRichTypes
      include Axn

      async :sidekiq
      expects :occurred_at, type: Time
      exposes :klass_name

      def call
        expose klass_name: occurred_at.class.name
      end
    end
  end
end
