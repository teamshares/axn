# frozen_string_literal: true

module Action
  module Attachable
    module Subactions
      extend ActiveSupport::Concern

      included do
        class_attribute :_axnable_methods, default: {}
        class_attribute :_axns, default: {}
      end

      class_methods do
        def axnable_method(name, axn_klass = nil, **action_kwargs, &block)
          raise ArgumentError, "Unable to attach Axn -- '#{name}' is already taken" if respond_to?(name)

          self._axnable_methods = _axnable_methods.merge(name => { axn_klass:, action_kwargs:, block: })

          action_kwargs[:expose_return_as] ||= :value unless axn_klass
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

          self._axns = _axns.merge(name => { axn_klass:, action_kwargs:, block: })

          axn_klass = axn_for_attachment(name:, axn_klass:, **action_kwargs, &block)

          define_singleton_method(name) do |**kwargs|
            axn_klass.call(**kwargs)
          end

          # TODO: do we also need an instance-level version that auto-wraps in hoist_errors(label: name)?

          define_singleton_method("#{name}!") do |**kwargs|
            axn_klass.call!(**kwargs)
          end

          self._axns = _axns.merge(name => axn_klass)
        end

        def inherited(subclass)
          super

          return unless subclass.name.present? # TODO: not sure why..

          # Need to redefine the axnable methods on the subclass to ensure they properly reference the subclass's
          # helper method definitions and not the superclass's.
          _axnable_methods.each do |name, config|
            subclass.axnable_method(name, config[:axn_klass], **config[:action_kwargs], &config[:block])
          end

          _axns.each do |name, config|
            subclass.axn(name, config[:axn_klass], **config[:action_kwargs], &config[:block])
          end
        end
      end
    end
  end
end
