# frozen_string_literal: true

module Axn
  module Mountable
    class MountingStrategies
      module Step
        extend Base

        module DSL
          def steps(*steps)
            Array(steps).compact.each do |step_class|
              next unless step_class.is_a?(Class)
              raise ArgumentError, "Step #{step_class} must include Axn module" if !step_class.included_modules.include?(::Axn) && !step_class < ::Axn

              num_steps = _mounted_axn_descriptors.count { |descriptor| descriptor.mount_strategy.key == :step }
              step("Step #{num_steps + 1}", step_class)
            end
          end

          def step(name, axn_klass = nil, error_prefix: nil, _inherit_from_target: false, **, &)
            Helpers::Mounter.mount_via_strategy(
              target: self,
              as: :step,
              name:,
              axn_klass:,
              error_prefix:,
              _inherit_from_target:,
              **,
              &
            )
          end
        end

        def self.strategy_specific_kwargs = super + [:error_prefix]

        def self.mount_to_target(descriptor:, target:)
          error_prefix = descriptor.options[:error_prefix] || "#{descriptor.name}: "
          axn_klass = descriptor.mounted_axn_for(target:)

          target.error from: axn_klass do |e|
            "#{error_prefix}#{e.message}"
          end

          # Only define #call method once
          return if target.instance_variable_defined?(:@_axn_call_method_defined_for_steps)

          target.define_method(:call) do
            step_descriptors = self.class._mounted_axn_descriptors.select { |d| d.mount_strategy.key == :step }

            step_descriptors.each do |step_descriptor|
              axn = step_descriptor.mounted_axn_for(target:)
              step_result = axn.call!(**@__context.__combined_data)

              # Extract exposed fields from step result and update exposed_data
              step_result.declared_fields.each do |field|
                @__context.exposed_data[field] = step_result.public_send(field)
              end
            end
          end
          target.instance_variable_set(:@_axn_call_method_defined_for_steps, true)
        end
      end
    end
  end
end
