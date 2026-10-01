# frozen_string_literal: true

module Axn
  module Internal
    # An anonymous class or module renders as its object address (`#<Class:0x…>`, and `#<Class:0x…>::Inner` for a
    # constant set under one), which changes on every boot and tells the reader nothing the placeholder does not:
    # `(anonymous class)`, `(anonymous module)`, and a bare `#<Name>` for any other address a rendering carries (a
    # singleton class's object). In a file of its own, below both `Internal::Identity` and `axn/exceptions`, so the
    # messages built on either can reach it, and so `Rendering.stable_class_name`/`stable_module_name` compose
    # through one owner rather than two.
    module StableAddresses
      ANONYMOUS_MODULE_ADDRESS = /#<(?:Class|Module):0x\h+>/
      OBJECT_ADDRESS = /:0x\h+>/
      private_constant :ANONYMOUS_MODULE_ADDRESS, :OBJECT_ADDRESS

      def self.of(rendered)
        stable = rendered.gsub(ANONYMOUS_MODULE_ADDRESS) { |address| address.start_with?("#<Class") ? "(anonymous class)" : "(anonymous module)" }
        stable.gsub(OBJECT_ADDRESS, ">").freeze
      end

      # A rendered name set in parentheses (`Handled exception (RuntimeError): …`), unless it is a bare placeholder,
      # which already carries its own pair: `Handled exception (anonymous class): …` rather than
      # `((anonymous class))`. A placeholder that opens a longer path (`(anonymous class)::Inner`) is wrapped
      # like any other name.
      def self.parenthesized(rendered) = PLACEHOLDER.match?(rendered) ? rendered : "(#{rendered})"

      PLACEHOLDER = /\A\(anonymous (?:class|module)\)\z/
      private_constant :PLACEHOLDER
    end
  end
end
