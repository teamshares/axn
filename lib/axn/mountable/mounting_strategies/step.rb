# frozen_string_literal: true

module Axn
  module Mountable
    class MountingStrategies
      module Step
        include Base
        # `extend self` rather than `module_function`: the latter COPIES each method onto the singleton
        # class, so `strategy_specific_kwargs`'s `super` would no longer find `Base`'s. (Style/ModuleFunction
        # accepts `extend self` in a module that declares private methods, which this one now does.)
        extend self

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

        # if:/unless: must be a Symbol (a parent method) or a Proc-compatible callable — fail at
        # declaration (AGENTS.md). Use the same `callable?` seam as the rest of the contract: it
        # requires `to_proc` (which the runner's `instance_exec(&condition)` needs), so a bare
        # `#call`-only object is rejected here rather than raising TypeError at run time.
        def validate_conditions!(kwargs)
          %i[if unless].each do |key|
            next unless kwargs.key?(key)

            condition = kwargs[key]
            next if condition.is_a?(Symbol) || ::Axn::Core::Flow::Handlers::Invoker.callable?(condition)

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
          # with the orchestrator we're about to generate — fail at declaration (AGENTS.md). Check
          # private methods too: instance_methods(false) omits a `private def call`, which would
          # otherwise be silently replaced (the reverse order is caught by method_added, which fires
          # regardless of visibility).
          if (target.instance_methods(false) + target.private_instance_methods(false)).include?(:call)
            raise ArgumentError, format(CALL_COLLISION_MESSAGE, target.name || "Action")
          end

          _define_steps_call(target)
          _install_call_collision_guard(target)
          target.instance_variable_set(:@_axn_call_method_defined_for_steps, true)
        end

        # Catches a `def call` written *after* steps were declared (the reverse order). Prepended to
        # the singleton class — rather than `define_singleton_method(:method_added)` — so it composes
        # with (and `super`s into) any `method_added` the class already defined. It fires only once
        # the orchestrator marker is set, i.e. on a class that generated its own step `#call`; a
        # mounted child action that merely *inherits* the marker-less host (e.g. an `inherit:` step
        # whose ClassBuilder subclasses the host) defines its own `#call` without tripping it.
        module CallCollisionGuard
          def method_added(name)
            super
            return unless name == :call
            return unless instance_variable_defined?(:@_axn_call_method_defined_for_steps) && @_axn_call_method_defined_for_steps

            raise ArgumentError, format(CALL_COLLISION_MESSAGE, self.name || "Action")
          end
        end

        # Both helpers below are reached only from `mount_to_target` above; `extend self` would otherwise
        # publish them as public singleton methods of this strategy module.
        private

        # Define the generated orchestrator. Defined before the marker is set (and before the guard is
        # installed on a first mount), so generating it never trips the collision guard.
        def _define_steps_call(target)
          target.define_method(:call) do
            step_descriptors = self.class._mounted_axn_descriptors.select { |d| d.mount_strategy.key == :step }

            evaluate_condition = lambda do |condition|
              condition.is_a?(Symbol) ? send(condition) : instance_exec(&condition)
            end

            step_descriptors.each do |step_descriptor|
              options = step_descriptor.options
              # Conditions run on the parent instance right before the step would run, reading data the
              # same way the action does: expects inputs (direct reader or `inputs`) and a prior step's
              # output via `result.<field>` (no bare exposure readers exist, by design). if: and
              # unless: combine with AND.
              next if options[:if] && !evaluate_condition.call(options[:if])
              next if options[:unless] && evaluate_condition.call(options[:unless])

              axn = step_descriptor.mounted_axn_for(target: self.class)
              error_prefix = options[:error_prefix] || "#{step_descriptor.name}: "

              # A field this parent declares is forwarded solely via `inputs` (resolved:
              # default:/preprocess:/coerce: applied, models resolved) -- never via the raw
              # provided_data value, which may be the un-normalized caller input (e.g. a blank
              # string a preprocess: normalizes to nil). `inputs` omits nil-resolved keys so a child
              # step applies its own absent/default handling for them, so we exclude the parent's
              # declared inbound fields from the raw passthrough rather than letting the raw splat
              # re-leak them. Undeclared caller fields (a field the caller passed that this parent
              # doesn't declare but a child step does) still pass through raw; exposed_data wins
              # last, matching __combined_data's prior exposure-over-input precedence.
              passthrough = @__context.provided_data.except(*self.class._declared_fields(:inbound))
              step_result = axn.call(**passthrough, **inputs, **@__context.exposed_data)

              # Propagate before absorbing, so a failing step merges nothing: a step's exposures
              # reaching a parent that failed at a LATER step would assemble a result across step
              # boundaries that no step ever produced.
              _propagate_sub_result_outcome!(step_result, error_prefix:)

              # Unfiltered by design — a step's output must reach later steps even when this parent
              # does not declare it, which is what makes the chain a chain.
              _absorb_result_exposures!(step_result, fields: step_result.declared_fields)
            end
          end
        end

        # Idempotent: prepending an already-present module is a no-op, and subclasses inherit the
        # guard through the singleton-class ancestry, so re-installing on a subclass that adds a step
        # is harmless.
        def _install_call_collision_guard(target)
          target.singleton_class.prepend(CallCollisionGuard)
        end
      end
    end
  end
end
