# frozen_string_literal: true

module Axn
  module Attachable
    module Subactions
      extend ActiveSupport::Concern

      included do
        class_attribute :_axnable_methods, default: {}
        class_attribute :_axns, default: {}
        class_attribute :_inheritance_in_progress, default: false
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

          define_singleton_method("#{name}!") do |**kwargs|
            axn_klass.call!(**kwargs)
          end

          define_singleton_method("#{name}_async") do |**kwargs|
            axn_klass.call_async(**kwargs)
          end

          self._axns = _axns.merge(name => axn_klass)
        end

        # Need to redefine the axnable methods on the subclass to ensure they properly reference the subclass's
        # helper method definitions and not the superclass's.
        def inherited(subclass)
          super

          # Prevent infinite recursion during factory creation
          return if _inheritance_in_progress

          # Set flag to prevent recursion
          self._inheritance_in_progress = true

          begin
            _axnable_methods.each do |name, config|
              subclass.axnable_method(name, config[:axn_klass], **config[:action_kwargs], &config[:block])
            end

            _axns.each do |name, config|
              subclass.axn(name, config[:axn_klass], **config[:action_kwargs], &config[:block])
            end
          ensure
            # Always reset the flag
            self._inheritance_in_progress = false
          end
        end
      end
    end
  end
end
