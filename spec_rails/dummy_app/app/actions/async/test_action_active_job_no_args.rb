# frozen_string_literal: true

module Actions
  module Async
    class TestActionActiveJobNoArgs
      include Axn

      async :active_job

      def call
        info "Action executed with no arguments"
      end
    end
  end
end
