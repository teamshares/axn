# frozen_string_literal: true

module Axn
  module Mountable
    class MountingStrategies
      module EnqueueAll
        include Base
        extend self # rubocop:disable Style/ModuleFunction -- module_function breaks inheritance

        module DSL
          def enqueue_all(axn_klass = nil, **, &)
            # Check if enqueue_all has already been called
            if respond_to?(:enqueue_all) && method(:enqueue_all).owner != self.class
              raise "enqueue_all can only be called once per class"
            end
            
            Helpers::Mounter.mount_via_strategy(
              target: self,
              as: :enqueue_all,
              name: "enqueue_all",
              axn_klass:,
              **,
              &
            )
          end
        end

        def mount_to_target(descriptor:, target:)
          name = descriptor.name

          mount_method(target:, method_name: name) do |**kwargs|
            axn = descriptor.mounted_axn_for(target: self)
            axn.call(**kwargs)
          end

          mount_method(target:, method_name: "#{name}_async") do |**kwargs|
            axn = descriptor.mounted_axn_for(target: self)
            axn.call_async(**kwargs)
          end
        end
      end
    end
  end
end
