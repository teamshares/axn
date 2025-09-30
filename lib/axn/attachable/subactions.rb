# frozen_string_literal: true

module Axn
  module Attachable
    module Subactions
      extend ActiveSupport::Concern

      included do
        class_attribute :_inheritance_in_progress, default: false
      end

      class_methods do
        def _axns
          @_axns ||= {}
        end

        def _axn_methods
          @_axn_methods ||= {}
        end

        def axn(name, axn_klass = nil, _internal: false, **action_kwargs, &block) # rubocop:disable Lint/UnderscorePrefixedVariableName
          method_name = name.to_s.underscore # handle invalid characters in names like "get name" or "SomeCapThing"

          raise AttachmentError, "Unable to attach Axn -- '#{method_name}' is already taken" if respond_to?(method_name) && !_inheritance_in_progress

          # Store the configuration (unless this is an internal call) - use original name for storage
          _axns[name] = { axn_klass:, action_kwargs:, block: } unless _internal

          # Use the Factory to build the Axn class with the clean superclass
          axn_klass = attach_axn(name:, axn_klass:, **action_kwargs, &block)

          define_singleton_method(method_name) do |**kwargs|
            axn_klass.call(**kwargs)
          end

          define_singleton_method("#{method_name}!") do |**kwargs|
            axn_klass.call!(**kwargs)
          end

          define_singleton_method("#{method_name}_async") do |**kwargs|
            axn_klass.call_async(**kwargs)
          end

          # Return the axn class for debugging
          axn_klass
        end

        def axn_method(name, axn_klass = nil, **action_kwargs, &block)
          # Force expose_return_as to :value for direct value returns
          action_kwargs[:expose_return_as] = action_kwargs[:expose_return_as].presence || :value

          # Store the configuration for inheritance
          _axn_methods[name] = { axn_klass:, action_kwargs:, block: }

          # Call axn to do the heavy lifting (_internal: true skips _axns storage)
          axn_klass = axn(name, axn_klass, _internal: true, **action_kwargs, &block)

          # Remove the base method that axn created and replace with our custom methods
          singleton_class.remove_method(name) if respond_to?(name)
          singleton_class.remove_method("#{name}!") if respond_to?("#{name}!")
          singleton_class.remove_method("#{name}_async") if respond_to?("#{name}_async")

          # Define only the ! and _axn methods, not the base method
          define_singleton_method("#{name}!") do |**kwargs|
            result = axn_klass.call!(**kwargs)
            result.public_send(action_kwargs[:expose_return_as]) # Return direct value, raises on error
          end

          define_singleton_method("#{name}_axn") do |**kwargs|
            axn_klass.call(**kwargs)
          end

          # Return the axn class for debugging
          axn_klass
        end

        # Need to redefine the axn methods on the subclass to ensure they properly reference the subclass's
        # helper method definitions and not the superclass's.
        def inherited(subclass)
          super

          # Prevent infinite recursion during factory creation
          return if _inheritance_in_progress

          # Set flag to prevent recursion
          self._inheritance_in_progress = true

          begin
            # Copy the configurations to the subclass first
            subclass.instance_variable_set(:@_axns, _axns.dup)
            subclass.instance_variable_set(:@_axn_methods, _axn_methods.dup)

            # Recreate the methods on the subclass
            _axns.each do |name, config|
              if config[:axn_klass]
                subclass.axn(name, config[:axn_klass], **config[:action_kwargs])
              else
                subclass.axn(name, **config[:action_kwargs], &config[:block])
              end
            end

            _axn_methods.each do |name, config|
              if config[:axn_klass]
                subclass.axn_method(name, config[:axn_klass], **config[:action_kwargs])
              else
                subclass.axn_method(name, nil, **config[:action_kwargs], &config[:block])
              end
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
