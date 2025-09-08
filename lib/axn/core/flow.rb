# frozen_string_literal: true

require "axn/core/flow/messages"
require "axn/core/flow/callbacks"
require "axn/core/flow/exception_execution"

module Axn
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
