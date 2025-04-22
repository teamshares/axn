# frozen_string_literal: true

module Action
  module Attachable
    module Subactions
      extend ActiveSupport::Concern

      class_methods do
        def axnable_method(name, axn_klass = nil, **action_kwargs, &block)
          raise ArgumentError, "Unable to attach Axn -- '#{name}' is already taken" if respond_to?(name)

          action_kwargs[:expose_return_as] ||= :value
          axn_klass = axn_for_attachment(name:, axn_klass:, **action_kwargs, &block)

          define_singleton_method("#{name}_axn") do |**kwargs|
            axn_klass.call(**kwargs)
          end

          define_singleton_method("#{name}!") do |**kwargs|
            result = axn_klass.call!(**kwargs)
            result.public_send(action_kwargs[:expose_return_as])
          end
        end

        def axn(name, axn_klass = nil, **action_kwargs, &block)
          raise ArgumentError, "Unable to attach Axn -- '#{name}' is already taken" if respond_to?(name)

          axn_klass = axn_for_attachment(name:, axn_klass:, **action_kwargs, &block)

          define_singleton_method(name) do |**kwargs|
            axn_klass.call(**kwargs)
          end

          # TODO: do we also need an instance-level version that auto-wraps in hoist_errors(label: name)?

          define_singleton_method("#{name}!") do |**kwargs|
            axn_klass.call!(**kwargs)
          end
        end
      end
    end
  end
end
