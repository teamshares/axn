# frozen_string_literal: true

module Action
  module Attachable
    module Steps
      extend ActiveSupport::Concern

      included do
        class_attribute :_axn_steps, default: []
      end

      Entry = Data.define(:label, :axn)

      class_methods do
        def steps(*steps)
          self._axn_steps += Array(steps).compact
        end

        def step(name, axn_klass = nil, **kwargs, &block)
          axn_klass = axn_for_attachment(
            name:,
            axn_klass:,
            attachment_type: "Step",
            superclass: Object, # NOTE: steps skip inheriting from the wrapping class (to avoid duplicate field expectations/exposures)
            **kwargs,
            &block
          )

          # Add the step to the list of steps
          steps Entry.new(label: name, axn: axn_klass)
        end
      end

      def call
        self.class._axn_steps.each_with_index do |step, idx|
          # Set a default label if we were just given an array of unlabeled steps
          # TODO: should Axn have a default label passed in already that we could pull out?
          step = Entry.new(label: "Step #{idx + 1}", axn: step) if step.is_a?(Class)

          hoist_errors(prefix: "#{step.label} step") do
            # Merge exposed data from previous steps into provided data for this step
            # This ensures each step has access to both original data and exposures from previous steps
            merged_data = @__context.provided_data.merge(@__context.exposed_data)

            # Execute the step with the merged context and get the result
            step_result = step.axn.call(merged_data)

            # Merge the step's exposures back into the main context
            # Extract the exposed data from the step result by reading its declared fields
            step_result.declared_fields.each do |field|
              @__context.exposed_data[field] = step_result.public_send(field)
            end

            step_result
          end
        end
      end
    end
  end
end
