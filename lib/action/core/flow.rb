# frozen_string_literal: true

require "action/core/flow/messages"
require "action/core/flow/callbacks"
require "action/core/flow/exception_execution"

module Action
  module Core
    module Flow
      def self.included(base)
        base.class_eval do
          include Messages
          include Callbacks
          include ExceptionExecution
        end
      end
    end
  end
end
