# frozen_string_literal: true

module RuboCop
  module Cop
    module Axn
      # Flags direct reads of `Current.<attr>` and steers toward declaring the dependency
      # explicitly with `expects :<attr>, on: :ambient_context`. Opt-in (see README).
      #
      # @example
      #   # bad
      #   def call = do_thing(Current.company)
      #
      #   # good
      #   expects :company, on: :ambient_context
      #   def call = do_thing(company)
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

        def on_send(node)
          # Reads only: skip `Current.foo(args)` and the setter `Current.foo = x`.
          return if node.arguments.any? || node.assignment_method?
          return if CURRENT_API_METHODS.include?(node.method_name)

          current_read(node) do |attr|
            add_offense(node, message: format(MSG, attr:))
          end
        end
      end
    end
  end
end
