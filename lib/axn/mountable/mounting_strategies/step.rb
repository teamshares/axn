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

          def step(name, axn_klass = nil, error_prefix: nil, inherit: MountingStrategies::Step.default_inherit_mode, **kwargs, &)
            # Steps chain into a shared, accumulating context (see the generated #call): each step is
            # invoked with all data exposed so far, and its exposures merge back for later steps.
            MountingStrategies::Step.validate_conditions!(kwargs)
            Helpers::Mounter.mount_via_strategy(
              target: self,
              as: :step,
              name:,
              axn_klass:,
              error_prefix:,
              inherit:,
              **kwargs,
              &
            )
          end
        end

        # if:/unless: must be a Symbol (a parent method) or a callable — fail at declaration (AGENTS.md).
        def validate_conditions!(kwargs)
          %i[if unless].each do |key|
            next unless kwargs.key?(key)

            condition = kwargs[key]
            next if condition.is_a?(Symbol) || condition.respond_to?(:call)

            raise ArgumentError, "step #{key}: must be a Symbol or callable (got #{condition.inspect})"
          end
        end

        def strategy_specific_kwargs = super + %i[error_prefix if unless]

        CALL_COLLISION_MESSAGE =
          "%s declares steps and a custom #call. Steps generate the #call orchestrator, so you " \
          "can't also define one. Use before/after hooks for setup/teardown around the steps."

        def mount_to_target(descriptor:, target:)
          # Ensure the mounted axn class is registered (e.g. as a constant under target's namespace)
          descriptor.mounted_axn_for(target:)

          # Only define #call method once
          return if target.instance_variable_defined?(:@_axn_call_method_defined_for_steps)

          # A user-authored #call already on this class (steps declared after `def call`) collides
          # with the orchestrator we're about to generate — fail at declaration (AGENTS.md).
          raise ArgumentError, format(CALL_COLLISION_MESSAGE, target.name || "Action") if target.instance_methods(false).include?(:call)

          _define_steps_call(target)
          _install_call_collision_guard(target)
          target.instance_variable_set(:@_axn_call_method_defined_for_steps, true)
        end

        # Define the generated orchestrator. The defining flag lets the method_added guard ignore
        # this (and the re-generation on a subclass that inherits the guard) — only a *user* #call
        # should trip it.
        def _define_steps_call(target)
          target.instance_variable_set(:@_axn_defining_steps_call, true)
          target.define_method(:call) do
            step_descriptors = self.class._mounted_axn_descriptors.select { |d| d.mount_strategy.key == :step }

            evaluate_condition = lambda do |condition|
              condition.is_a?(Symbol) ? send(condition) : instance_exec(&condition)
            end

            step_descriptors.each do |step_descriptor|
              options = step_descriptor.options
              # Conditions run on the parent instance right before the step would run, so they read the
              # accumulated context (parent inputs + anything exposed by earlier steps). if: and unless:
              # combine with AND.
              next if options[:if] && !evaluate_condition.call(options[:if])
              next if options[:unless] && evaluate_condition.call(options[:unless])

              axn = step_descriptor.mounted_axn_for(target: self.class)
              error_prefix = options[:error_prefix] || "#{step_descriptor.name}: "

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
        ensure
          target.instance_variable_set(:@_axn_defining_steps_call, false)
        end

        # Catch a `def call` written *after* steps were declared (the reverse order). The invariant:
        # a class with step descriptors (own or inherited) must not define its own #call. Subclasses
        # inherit this guard, so re-generating the orchestrator on a subclass is shielded by the
        # defining flag set in _define_steps_call.
        def _install_call_collision_guard(target)
          target.define_singleton_method(:method_added) do |name|
            super(name)
            next unless name == :call
            next if instance_variable_defined?(:@_axn_defining_steps_call) && @_axn_defining_steps_call
            next unless _mounted_axn_descriptors.any? { |d| d.mount_strategy.key == :step }

            raise ArgumentError, format(CALL_COLLISION_MESSAGE, self.name || "Action")
          end
        end
      end
    end
  end
end
