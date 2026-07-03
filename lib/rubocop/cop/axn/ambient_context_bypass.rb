# frozen_string_literal: true

module RuboCop
  module Cop
    module Axn
      # Flags direct reads of `Current.<attr>` and steers toward declaring the dependency
      # explicitly with `expects :<attr>, on: :ambient_context`. Opt-in (see README).
      #
      # Only fires inside a class/module that `include Axn` — `expects ..., on: :ambient_context`
      # is only a fix available to Axn classes, so flagging a `Current` read anywhere else
      # (controllers, models, plain jobs) would be an unfixable false positive.
      #
      # @example
      #   # bad
      #   class ChargeCard
      #     include Axn
      #     def call = do_thing(Current.company)
      #   end
      #
      #   # good
      #   class ChargeCard
      #     include Axn
      #     expects :company, on: :ambient_context
      #     def call = do_thing(company)
      #   end
      class AmbientContextBypass < RuboCop::Cop::Base
        MSG = "Read ambient state via `expects :%<attr>s, on: :ambient_context` instead of `Current` directly."

        # ActiveSupport::CurrentAttributes class/lifecycle API — these are not ambient-attribute
        # reads, so flagging them (and suggesting a nonsense `expects :reset, ...`) would break
        # normal request/test cleanup lint.
        CURRENT_API_METHODS = %i[
          reset reset_all clear_all set instance attributes before_reset after_reset resets attribute
        ].freeze

        # Matches `Current.foo` and `::Current.foo`, capturing the attribute name.
        def_node_matcher :current_read, <<~PATTERN
          (send {(const nil? :Current) (const (cbase) :Current)} $_)
        PATTERN

        def_node_search :includes_axn?, <<~PATTERN
          (send nil? :include (const nil? :Axn))
        PATTERN

        def on_send(node)
          # Reads only: skip `Current.foo(args)` and the setter `Current.foo = x`.
          return if node.arguments.any? || node.assignment_method?
          return if CURRENT_API_METHODS.include?(node.method_name)
          return unless within_axn_class?(node)

          current_read(node) do |attr|
            add_offense(node, message: format(MSG, attr:))
          end
        end

        private

        # Walks `node`'s ancestors looking for an enclosing class/module whose body includes
        # `include Axn`. Wrapped in a rescue like unchecked_result.rb so malformed AST can't
        # crash the cop.
        def within_axn_class?(node)
          current_node = node
          while current_node.parent
            current_node = current_node.parent
            next unless %i[class module].include?(current_node.type)

            return true if includes_axn?(current_node)
          end
          false
        rescue StandardError => _e
          false
        end
      end
    end
  end
end
