# frozen_string_literal: true

module Axn
  module Attachable
    class AttachmentStrategies
      class Step < Base
        module DSL
          def steps(*steps)
            Array(steps).compact.each do |step_class|
              next unless step_class.is_a?(Class)
              raise ArgumentError, "Step #{step_class} must include Axn module" if !step_class.included_modules.include?(::Axn) && !step_class < ::Axn

              num_steps = _attached_axn_descriptors.count { |descriptor| descriptor.mount_strategy.key == :step }
              step("Step #{num_steps + 1}", step_class)
            end
          end

          def step(name, axn_klass = nil, error_prefix: nil, **, &)
            attach_axn(as: :step, name:, axn_klass:, error_prefix:, **, &)
          end
        end

        def self.mount(descriptor:, target:)
          error_prefix = descriptor.options[:error_prefix] || "#{descriptor.name}: "
          axn_klass = descriptor.attached_axn

          target.error from: axn_klass do |e|
            "#{error_prefix}#{e.message}"
          end

          # Define #call method dynamically to execute steps
          target.define_method(:call) do
            self.class._attached_axn_descriptors.select { |d| d.mount_strategy.key == :step }.each do |step_descriptor|
              axn = step_descriptor.attached_axn
              step_result = axn.call!(**@__context.__combined_data)
              step_result.declared_fields.each do |field|
                @__context.exposed_data[field] = step_result.public_send(field)
              end
            end
          end
        end

        def self.strategy_specific_kwargs = [:error_prefix]
      end
    end
  end
end
