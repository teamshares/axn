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
    end
  end
end
