# frozen_string_literal: true

module Axn
  module Mountable
    class MountingStrategies
      module Axn
        include Base
        extend self # rubocop:disable Style/ModuleFunction -- module_function breaks inheritance

        def default_inherit_mode = :lifecycle

        module DSL
          def mount_axn(name, axn_klass = nil, inherit: MountingStrategies::Axn.default_inherit_mode, **, &)
            # mount_axn defaults to :lifecycle - participates in parent's execution lifecycle
            Helpers::Mounter.mount_via_strategy(
              target: self,
              as: :axn,
              name:,
              axn_klass:,
              inherit:,
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
