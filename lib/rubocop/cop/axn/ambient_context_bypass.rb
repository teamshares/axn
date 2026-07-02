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

        # Matches `Current.foo` and `::Current.foo`, capturing the attribute name.
        def_node_matcher :current_read, <<~PATTERN
          (send {(const nil? :Current) (const (cbase) :Current)} $_)
        PATTERN

        def on_send(node)
          # Reads only: skip `Current.foo(args)` and the setter `Current.foo = x`.
          return if node.arguments.any? || node.assignment_method?

          current_read(node) do |attr|
            add_offense(node, message: format(MSG, attr:))
          end
        end
      end
    end
  end
end
