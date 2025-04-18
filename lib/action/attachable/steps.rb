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
        def steps(*steps) = self._axn_steps += Array(steps).compact

        def step(name, axn_klass = nil, **kwargs, &block)
          raise ArgumentError, "Step name must be a string or symbol" unless name.is_a?(String) || name.is_a?(Symbol)
          raise ArgumentError, "Step '#{name}' must be given an existing action class or a block" if axn_klass.nil? && !block_given?
          raise ArgumentError, "Step '#{name}' was given both an existing action class and a block - only one is allowed" if axn_klass && block_given?

          new_action_name = "_step_#{name}"
          raise ArgumentError, "Action cannot be added -- '#{name}' is already taken" if respond_to?(new_action_name)

          if axn_klass && !(axn_klass.respond_to?(:<) && axn_klass < Action)
            raise ArgumentError,
                  "Action '#{name}' must be given a block or an already-existing Action class"
          end

          # TODO: CAREFUL ABOUT EXTENDING SELF WHEN THAT ALREADY HAS STEP INFO?!!
          axn_klass ||= Axn::Factory.build(superclass: self, **kwargs, &block)

          #
          # --- Above here -- probably extractable ---
          #

          # Add the step to the list of steps
          _axn_steps << Entry.new(label: name, axn: axn_klass)
        end
      end

      def call
        self.class._axn_steps.each_with_index do |step, idx|
          # Set a default label if we were just given an array of unlabeled steps
          # TODO: should Axn have a default label passed in already that we could pull out?
          step = Entry.new(label: "Step #{idx + 1}", axn: step) if step.is_a?(Class)

          hoist_errors(prefix: "#{step.label} step") do
            step.axn.call(@context)
          end
        end
      end
    end
  end
end
