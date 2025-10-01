# frozen_string_literal: true

module Axn
  module Attachable
    class AttachmentStrategies
      module Axn
        extend Base

        module DSL
          def axn(name, axn_klass = nil, **, &)
            attach_axn(as: :axn, name:, axn_klass:, **, &)
          end
        end

        def self.mount(descriptor:, target:)
          axn = descriptor.attached_axn
          name = descriptor.name

          target.define_singleton_method(name) do |**kwargs|
            axn.call(**kwargs)
          end

          target.define_singleton_method("#{name}!") do |**kwargs|
            axn.call!(**kwargs)
          end

          target.define_singleton_method("#{name}_async") do |**kwargs|
            axn.call_async(**kwargs)
          end
        end
      end
    end
  end
end
