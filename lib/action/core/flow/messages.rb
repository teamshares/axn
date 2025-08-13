# frozen_string_literal: true

module Action
  module Core
    module Flow
      module Messages
        def self.included(base)
          base.class_eval do
            class_attribute :_success_msg, :_error_msg
            class_attribute :_custom_error_interceptors, default: []

            extend ClassMethods
            include InstanceMethods
          end
        end

        module ClassMethods
          def success(message)
            self._success_msg = message if message.present?
            true
          end

          def error(message)
            self._error_msg = message if message.present?
            true
          end

          def error_from(matcher = nil, message = nil, **match_and_messages)
            _register_error_interceptor(matcher, message, **match_and_messages)
          end

          def default_error = new.internal_context.default_error

          # Private helpers

          def _error_interceptor_for(exception:, action:)
            Array(_custom_error_interceptors).detect do |int|
              int.matches?(exception:, action:)
            end
          end

          def _register_error_interceptor(matcher, message, **match_and_messages)
            raise ArgumentError, "error_from must be called with a key/value pair, or else keyword args" if [matcher, message].compact.size == 1

            interceptors = { matcher => message }.compact.merge(match_and_messages).map do |(matcher, message)| # rubocop:disable Lint/ShadowingOuterLocalVariable
              Action::EventHandlers::CustomErrorInterceptor.new(matcher:, message:)
            end

            self._custom_error_interceptors += interceptors
          end
        end

        module InstanceMethods
          delegate :default_error, to: :internal_context
        end
      end
    end
  end
end
