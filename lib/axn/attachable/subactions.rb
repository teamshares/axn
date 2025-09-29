# frozen_string_literal: true

module Axn
  module Attachable
    module Subactions
      extend ActiveSupport::Concern

      included do
        class_attribute :_inheritance_in_progress, default: false
      end

      class_methods do
        def _axnable_methods
          @_axnable_methods ||= {}
        end

        def _axns
          @_axns ||= {}
        end

        def axnable_method(name, axn_klass = nil, **action_kwargs, &block)
          raise ArgumentError, "Unable to attach Axn -- '#{name}' is already taken" if respond_to?(name)

          # Store the configuration
          _axnable_methods[name] = { axn_klass:, action_kwargs:, block: }

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
          raise ArgumentError, "Unable to attach Axn -- '#{name}' is already taken" if respond_to?(name) && !_inheritance_in_progress

          # Store the configuration
          _axns[name] = { axn_klass:, action_kwargs:, block: }

          # Create a clean base class that inherits from self but has no field expectations
          # This gives us all the parent's capabilities (hooks, error handling, etc.) but clean field configs
          clean_base_class = Class.new(self) do
            # Clear field expectations since this is a sub-action that shouldn't inherit parent's field requirements
            # but should inherit all other capabilities (hooks, error handling, etc.)
            self.internal_field_configs = []
            self.external_field_configs = []
          end

          axn_klass = axn_for_attachment(name:, axn_klass:, superclass: clean_base_class, **action_kwargs, &block)

          # If axn_klass is an anonymous class (created from a block), assign it to a constant
          # Check if the class name contains '#' which indicates it's not a proper constant
          if axn_klass.name.nil? || axn_klass.name.start_with?("#<Class:") || axn_klass.name.include?("#")
            constant_name = "#{name.to_s.camelize}Axn"
            const_set(constant_name, axn_klass)
          end

          define_singleton_method(name) do |**kwargs|
            axn_klass.call(**kwargs)
          end

          define_singleton_method("#{name}!") do |**kwargs|
            axn_klass.call!(**kwargs)
          end

          define_singleton_method("#{name}_async") do |**kwargs|
            axn_klass.call_async(**kwargs)
          end
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
            # Copy the configurations to the subclass first
            subclass.instance_variable_set(:@_axnable_methods, _axnable_methods.dup)
            subclass.instance_variable_set(:@_axns, _axns.dup)

            # Recreate the methods on the subclass
            _axnable_methods.each do |name, config|
              if config[:axn_klass]
                subclass.axnable_method(name, config[:axn_klass], **config[:action_kwargs])
              else
                subclass.axnable_method(name, nil, **config[:action_kwargs], &config[:block])
              end
            end

            _axns.each do |name, config|
              if config[:axn_klass]
                subclass.axn(name, config[:axn_klass], **config[:action_kwargs])
              else
                subclass.axn(name, **config[:action_kwargs], &config[:block])
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
