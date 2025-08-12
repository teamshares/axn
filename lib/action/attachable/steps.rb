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
            step.axn.call(**merged_context_data).tap do |step_result|
              merge_step_exposures!(step_result)
            end
          end
        end
      end

      private

      def merged_context_data
        @__context.__combined_data
      end

      # Each step can expect the data exposed from the previous steps
      def merge_step_exposures!(step_result)
        step_result.declared_fields.each do |field|
          @__context.exposed_data[field] = step_result.public_send(field)
        end
      end
    end
  end
end
