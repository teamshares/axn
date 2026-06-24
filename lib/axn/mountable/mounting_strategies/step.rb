# frozen_string_literal: true

module Axn
  module Mountable
    class MountingStrategies
      module Step
        include Base
        extend self # rubocop:disable Style/ModuleFunction -- module_function breaks inheritance

        def default_inherit_mode = :none

        module DSL
          def steps(*steps)
            Array(steps).compact.each do |step_class|
              next unless step_class.is_a?(Class)
              raise ArgumentError, "Step #{step_class} must include Axn module" if !step_class.included_modules.include?(::Axn) && !step_class < ::Axn

              num_steps = _mounted_axn_descriptors.count { |descriptor| descriptor.mount_strategy.key == :step }
              step("Step #{num_steps + 1}", step_class)
            end
          end

          def step(name, axn_klass = nil, error_prefix: nil, inherit: MountingStrategies::Step.default_inherit_mode, **, &)
            # Steps default to :none - they are isolated units of work
            Helpers::Mounter.mount_via_strategy(
              target: self,
              as: :step,
              name:,
              axn_klass:,
              error_prefix:,
              inherit:,
              **,
              &
            )
          end
        end

        def strategy_specific_kwargs = super + [:error_prefix]

        def mount_to_target(descriptor:, target:)
          # Ensure the mounted axn class is registered (e.g. as a constant under target's namespace)
          descriptor.mounted_axn_for(target:)

          # Only define #call method once
          return if target.instance_variable_defined?(:@_axn_call_method_defined_for_steps)

          target.define_method(:call) do
            step_descriptors = self.class._mounted_axn_descriptors.select { |d| d.mount_strategy.key == :step }

            step_descriptors.each do |step_descriptor|
              axn = step_descriptor.mounted_axn_for(target: self.class)
              error_prefix = step_descriptor.options[:error_prefix] || "#{step_descriptor.name}: "

              step_result = axn.call(**@__context.__combined_data)

              unless step_result.ok?
                # Propagate the step's outcome *category*, not a flattened failure: a deliberate fail!
                # (or a fails_on-classified exception) settles the parent as a failure with the
                # prefixed message; an unclassified exception (a bug) re-raises the original object so
                # the parent settles as an exception too. The global report already fired at the step
                # and is deduped per exception object, so re-raising never double-reports.
                raise step_result.exception if step_result.outcome.exception?

                fail!("#{error_prefix}#{step_result.error}")
              end

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
