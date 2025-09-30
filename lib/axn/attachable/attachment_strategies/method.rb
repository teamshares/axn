# frozen_string_literal: true

module Axn
  module Attachable
    class AttachmentStrategies
      class Method < Base
        module DSL
          def axn_method(name, axn_klass = nil, **, &)
            attach_axn(as: :method, name:, axn_klass:, **, &)
          end
        end

        def self.preprocess_kwargs(**kwargs)
          # Call parent preprocessing first
          kwargs = super

          # Methods require a return value
          kwargs[:expose_return_as] = kwargs[:expose_return_as].presence || :value

          # Methods aren't capable of returning multiple values
          if kwargs[:exposes].present?
            raise AttachmentError,
                  "Methods aren't capable of exposing multiple values (will automatically expose return value instead)"
          end

          kwargs
        end

        def self.mount(attachment_name, axn_klass, on:, **options)
          # Define custom methods for axn_method behavior
          on.define_singleton_method("#{attachment_name}!") do |**kwargs|
            result = axn_klass.call!(**kwargs)
            result.public_send(options[:expose_return_as]) # Return direct value, raises on error
          end

          on.define_singleton_method("#{attachment_name}_axn") do |**kwargs|
            axn_klass.call(**kwargs)
          end
        end
      end
    end
  end
end
