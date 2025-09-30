# frozen_string_literal: true

module Axn
  module Attachable
    class AttachmentStrategies
      class Axn < Base
        module DSL
          def axn(name, axn_klass = nil, **, &)
            attach_axn(as: :axn, name:, axn_klass:, **, &)
          end
        end

        def mount(on:)
          axn_klass = @axn_klass
          name = @name

          on.define_singleton_method(name) do |**kwargs|
            axn_klass.call(**kwargs)
          end

          on.define_singleton_method("#{name}!") do |**kwargs|
            axn_klass.call!(**kwargs)
          end

          on.define_singleton_method("#{name}_async") do |**kwargs|
            axn_klass.call_async(**kwargs)
          end
        end
      end
    end
  end
end
