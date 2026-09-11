# frozen_string_literal: true

module Axn
  module Core
    module Hooks
      def self.included(base)
        base.class_eval do
          class_attribute :around_hooks, instance_accessor: false, default: []
          class_attribute :before_hooks, instance_accessor: false, default: []
          class_attribute :after_hooks, instance_accessor: false, default: []

          extend ClassMethods
        end
      end

      module ClassMethods
        # Public: Declare hooks to run around action execution. The around
        # method may be called multiple times; subsequent calls append declared
        # hooks to existing around hooks.
        #
        # Around hooks wrap the entire action execution, including before and
        # after hooks. Parent hooks wrap child hooks (parent outside, child inside).
        #
        # hooks - Zero or more Symbol method names representing instance methods
        #         to be called around action execution. Each instance method
        #         invocation receives an argument representing the next link in
        #         the around hook chain.
        # block - An optional block to be executed as a hook. If given, the block
        #         is executed after methods corresponding to any given Symbols.
        def around(*hooks, &block)
          hooks << block if block
          _validate_hooks!(hooks)
          hooks.each { |hook| self.around_hooks += [hook] }
        end

        # Public: Declare hooks to run before action execution. The before
        # method may be called multiple times; subsequent calls append declared
        # hooks to existing before hooks.
        #
        # Before hooks run in parent-first order (general setup first, then specific).
        # Parent hooks run before child hooks.
        #
        # hooks - Zero or more Symbol method names representing instance methods
        #         to be called before action execution.
        # block - An optional block to be executed as a hook. If given, the block
        #         is executed after methods corresponding to any given Symbols.
        def before(*hooks, &block)
          hooks << block if block
          _validate_hooks!(hooks)
          hooks.each { |hook| self.before_hooks += [hook] }
        end

        # Public: Declare hooks to run after action execution. The after
        # method may be called multiple times; subsequent calls prepend declared
        # hooks to existing after hooks.
        #
        # After hooks run in child-first order (specific cleanup first, then general).
        # Child hooks run before parent hooks.
        #
        # hooks - Zero or more Symbol method names representing instance methods
        #         to be called after action execution.
        # block - An optional block to be executed as a hook. If given, the block
        #         is executed before methods corresponding to any given Symbols.
        def after(*hooks, &block)
          hooks << block if block
          _validate_hooks!(hooks)
          hooks.each { |hook| self.after_hooks = [hook] + after_hooks }
        end

        private

        # A hook is dispatched at run time as either a Symbol (`@action.send(hook)`) or a callable
        # (`@action.instance_exec(&hook)`, see `Executor#run_hook`) — there is no String form, unlike
        # the `error`/`success` message DSL. A value outside that grammar reached this point silently
        # before: `before [:a, :b]` (an Array handed to the splat instead of two Symbols) declared
        # cleanly and only blew up as a bare `TypeError: wrong argument type Array (expected Proc)` on
        # the FIRST call after — after!, at the run site, not the declaration. Reject it here instead,
        # naming the shape to write.
        #
        # Deliberately NOT `Handlers::Invoker.safely_callable?` -- that predicate requires `arity` too,
        # because Invoker's OWN dispatch (`instance_exec` with arity-filtered args, for messages and
        # callbacks) needs it. `Executor#run_hook` calls `instance_exec(*, &hook)` instead: `&hook`
        # only ever calls `hook.to_proc`, never inspects arity, so an object answering `to_proc` alone
        # (no `arity`) runs here just fine and must not be rejected by a stricter borrowed check.
        def _validate_hooks!(hooks)
          invalid = hooks.reject { |hook| hook.is_a?(Symbol) || _safely_to_proc?(hook) }
          return if invalid.empty?

          # Rendered by CLASS, never by the offender's own `#inspect` -- a guard that has already
          # gone to the trouble of surviving a hostile `respond_to?` (`_safely_to_proc?` above) must
          # not turn around and hand the SAME hostile object its `#inspect` to run, which would
          # replace this ArgumentError with whatever that raises instead.
          rendered = invalid.map { |hook| Axn::Internal::Reflection::PropertyNames.renderable_class_name(hook) }.join(", ")
          raise ArgumentError,
                "hooks must be Symbols naming instance methods, or callables (e.g. `before :a, :b`); got #{rendered}"
        end

        # Guarded against a hostile `respond_to?`/`respond_to_missing?` that raises instead of
        # answering, same boundary as `Handlers::Invoker.safely_callable?` -- a declaration guard must
        # not let the value being judged raise IN PLACE OF the verdict.
        def _safely_to_proc?(value)
          value.respond_to?(:to_proc)
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
          false
        end
      end
    end
  end
end
