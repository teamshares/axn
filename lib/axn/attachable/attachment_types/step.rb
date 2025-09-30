# frozen_string_literal: true

module Axn
  module Attachable
    class AttachmentTypes
      module Step
        module DSL
          def steps(*steps)
            Array(steps).compact.each do |step_class|
              next unless step_class.is_a?(Class)
              raise ArgumentError, "Step #{step_class} must include Axn module" if !step_class.included_modules.include?(::Axn) && !step_class < ::Axn

              step("Step #{_axn_steps.length + 1}", step_class)
            end
          end

          def step(name, axn_klass = nil, error_prefix: nil, **, &)
            # Use the registry system
            attach_axn(
              as: :step,
              name:,
              axn_klass:,
              error_prefix:,
              **,
              &
            )
          end
        end

        def self.mount(attachment_name, axn_klass, on:, **options)
          # Set up error handling
          error_prefix = options[:error_prefix] || "#{attachment_name}: "
          on.error from: axn_klass do |e|
            "#{error_prefix}#{e.message}"
          end
        end
      end
    end
  end
end
