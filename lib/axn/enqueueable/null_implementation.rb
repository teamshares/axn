# frozen_string_literal: true

module Axn
  module Enqueueable
    module NullImplementation
      def self.included(base)
        base.class_eval do
          def self.enqueue(context = {})
            raise NotImplementedError,
                  "Enqueueable functionality requires a background job library. " \
                  "Please add sidekiq to your Gemfile or configure another provider."
          end

          def self.enqueue!(context = {})
            raise NotImplementedError,
                  "Enqueueable functionality requires a background job library. " \
                  "Please add sidekiq to your Gemfile or configure another provider."
          end
        end
      end
    end
  end
end
