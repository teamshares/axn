# frozen_string_literal: true

module Axn
  module Mountable
    class MountingStrategies
      module Axn
        extend Base

        module DSL
          def mount_axn(name, axn_klass = nil, **, &)
            Helpers::Mounter.mount_via_strategy(
              target: self,
              as: :axn,
              name:,
              axn_klass:,
              **,
              &
            )
          end
        end

        def self.mount_to_target(descriptor:, target:)
          name = descriptor.name

          mount_method(target:, method_name: name) do |**kwargs|
            axn = descriptor.mounted_axn_for(target: self)
            axn.call(**kwargs)
          end

          mount_method(target:, method_name: "#{name}!") do |**kwargs|
            axn = descriptor.mounted_axn_for(target: self)
            axn.call!(**kwargs)
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
