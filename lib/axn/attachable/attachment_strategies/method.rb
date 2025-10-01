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
          processed_kwargs = super

          # Methods require a return value
          processed_kwargs[:expose_return_as] = processed_kwargs[:expose_return_as].presence || :value

          # Methods aren't capable of returning multiple values
          if processed_kwargs[:exposes].present?
            raise AttachmentError,
                  "Methods aren't capable of exposing multiple values (will automatically expose return value instead)"
          end

          processed_kwargs
        end

        def self.mount(descriptor:, target:)
          # Define custom methods for axn_method behavior
          name = descriptor.name
          axn_klass = descriptor.attached_axn

          # TODO: if given an existing axn, kwargs may not be live - we should introspect the axn itself to determine this
          expose_return_as = descriptor.instance_variable_get(:@kwargs)[:expose_return_as] || :value

          target.define_singleton_method("#{name}!") do |**kwargs|
            result = axn_klass.call!(**kwargs)
            result.public_send(expose_return_as) # Return direct value, raises on error
          end

          target.define_singleton_method("#{name}_axn") do |**kwargs|
            axn_klass.call(**kwargs)
          end
        end
      end
    end
  end
end
