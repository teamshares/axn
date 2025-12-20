# frozen_string_literal: true

module Axn
  module Core
    module Hooks
      def self.included(base)
        base.class_eval do
          class_attribute :around_hooks, default: []
          class_attribute :before_hooks, default: []
          class_attribute :after_hooks, default: []

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
          hooks.each { |hook| self.after_hooks = [hook] + after_hooks }
        end
      end

      private

      def _with_hooks
        # Outer is needed in the unlikely case done! is called in around hooks
        __respecting_early_completion do
          _run_around_hooks do
            __respecting_early_completion do
              _run_before_hooks
              yield
              _run_after_hooks
            end
          end
        end
      end

      # Around hooks are reversed before injection to ensure parent hooks wrap
      # child hooks (parent outside, child inside).
      def _run_around_hooks(&block)
        self.class.around_hooks.reverse.inject(block) do |chain, hook|
          proc { _run_hook(hook, chain) }
        end.call
      end

      # Before hooks run in the order they were added (parent first, then child).
      def _run_before_hooks
        _run_hooks(self.class.before_hooks)
      end

      # After hooks are reversed to ensure child hooks run before parent hooks
      # (specific cleanup first, then general).
      def _run_after_hooks
        _run_hooks(self.class.after_hooks.reverse)
      end

      # Internal: Run a collection of hooks. The "_run_hooks" method is the common
      # interface by which collections of either before or after hooks are run.
      #
      # hooks - An Array of Symbol and Procs.
      #
      # Returns nothing.
      def _run_hooks(hooks)
        hooks.each { |hook| _run_hook(hook) }
      end

      # Internal: Run an individual hook. The "_run_hook" method is the common
      # interface by which an individual hook is run. If the given hook is a
      # symbol, the method is invoked whether public or private. If the hook is a
      # proc, the proc is evaluated in the context of the current instance.
      #
      # hook - A Symbol or Proc hook.
      # args - Zero or more arguments to be passed as block arguments into the
      #        given block or as arguments into the method described by the given
      #        Symbol method name.
      #
      # Returns nothing.
      def _run_hook(hook, *)
        hook.is_a?(Symbol) ? send(hook, *) : instance_exec(*, &hook)
      end

      def __respecting_early_completion
        yield
      rescue Axn::Internal::EarlyCompletion => e
        @__context.__record_early_completion(e.message)
        raise e
      end
    end
  end
end
