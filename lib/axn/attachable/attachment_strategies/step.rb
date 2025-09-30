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

              axn_steps = _attached_axns.values.select { |descriptor| descriptor.as == :step }.map(&:axn_klass)
              step("Step #{axn_steps.length + 1}", step_class)
            end
          end

          def step(name, axn_klass = nil, error_prefix: nil, **, &)
            attach_axn(as: :step, name:, axn_klass:, error_prefix:, **, &)
          end
        end

        def mount(on:)
          # Set up error handling
          axn_klass = @axn_klass
          name = @name
          error_prefix = @options[:error_prefix] || "#{name}: "

          on.error from: axn_klass do |e|
            "#{error_prefix}#{e.message}"
          end

          # Define #call method dynamically to execute steps
          on.define_method(:call) do
            self.class._attached_axns.values.select { |descriptor| descriptor.as == :step }.map(&:axn_klass).each do |axn|
              step_result = axn.call!(**@__context.__combined_data)
              step_result.declared_fields.each do |field|
                @__context.exposed_data[field] = step_result.public_send(field)
              end
            end
          end
        end

        protected

        def strategy_specific_kwargs = [:error_prefix]
      end
    end
  end
end
