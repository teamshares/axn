# frozen_string_literal: true

module Axn
  module Mountable
    class MountingStrategies
      module Method
        extend Base

        module DSL
          def axn_method(name, axn_klass = nil, **, &)
            mount_axn(as: :method, name:, axn_klass:, **, &)
          end
        end

        def self.preprocess_kwargs(**kwargs)
          # Call parent preprocessing first
          processed_kwargs = super

          # Methods require a return value
          processed_kwargs[:expose_return_as] = processed_kwargs[:expose_return_as].presence || :value

          # Methods aren't capable of returning multiple values
          if processed_kwargs[:exposes].present?
            raise MountingError,
                  "Methods aren't capable of exposing multiple values (will automatically expose return value instead)"
          end

          # Check for existing axn class with multiple exposed fields
          if processed_kwargs[:axn_klass].present?
            axn_klass = processed_kwargs[:axn_klass]
            exposed_fields = axn_klass.external_field_configs.map(&:field)

            if exposed_fields.size > 1
              raise MountingError,
                    "Cannot determine expose_return_as for existing axn class with multiple exposed fields: #{exposed_fields.join(", ")}. " \
                    "Use a fresh block with axn_method or ensure the axn class has exactly one exposed field."
            end
          end

          processed_kwargs
        end

        def self.mount_to_target(descriptor:, target:)
          name = descriptor.name

          mount_method(target:, method_name: "#{name}!") do |**kwargs|
            # Lazy load the action class for the current target
            axn_klass = descriptor.mounted_axn_for(target: self)

            # Determine expose_return_as by introspecting the axn class
            exposed_fields = axn_klass.external_field_configs.map(&:field)
            expose_return_as = exposed_fields.size == 1 ? exposed_fields.first : nil

            result = axn_klass.call!(**kwargs)
            return result if expose_return_as.nil?

            result.public_send(expose_return_as)
          end
        end

        private_class_method def self._determine_exposure_to_return(axn_klass)
          # Introspect the axn class to determine expose_return_as
          exposed_fields = axn_klass.external_field_configs.map(&:field)

          case exposed_fields.size
          when 0
            nil # No exposed fields, return nil to avoid public_send
          when 1
            exposed_fields.first # Single field, assume it's expose_return_as
          else
            raise MountingError,
                  "Cannot determine expose_return_as for existing axn class with multiple exposed fields: #{exposed_fields.join(", ")}. " \
                  "Use a fresh block with axn_method or ensure the axn class has exactly one exposed field."
          end
        end
      end
    end
  end
end
