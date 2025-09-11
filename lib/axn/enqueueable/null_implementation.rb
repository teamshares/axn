# frozen_string_literal: true

module Axn
  module Enqueueable
    module NullImplementation
      def self.included(base)
        base.class_eval do
          def self.perform_later(context = {})
            raise NotImplementedError,
                  "Enqueueable functionality requires a background job library. " \
                  "Please add active_job or sidekiq to your Gemfile."
          end

          def self.perform_now(context = {})
            raise NotImplementedError,
                  "Enqueueable functionality requires a background job library. " \
                  "Please add active_job or sidekiq to your Gemfile."
          end
        end
      end
    end
  end
end
