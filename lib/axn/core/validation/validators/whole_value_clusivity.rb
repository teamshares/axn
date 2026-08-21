# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    # ActiveModel's `Clusivity#include?` special-cases an Array VALUE — `value.all? { |v| members.include?(v) }`
    # (activemodel-8.1.3.1, clusivity.rb:24) — so an inclusion set distributes over an array's elements while
    # every other validator on the same field constrains the field's own value. Axn's rule is positional: a
    # validator constrains the value at the position it is declared at, and `of:` is how a declaration descends
    # a level. So the branch goes, and one reading holds everywhere.
    #
    # Three things that reading buys, in the order they matter. The emitted `enum` sits on the field's own node
    # and always did, so the runtime now agrees with the document instead of contradicting it. `exclusion:`
    # stops being wrong under every reading: `include?` is called by a negating caller, so distributing with
    # `all?` meant "reject only when EVERY element is forbidden", and an array carrying one forbidden element
    # among legal ones passed. And the reading reaches every depth, where the special case reached only a
    # field-level Array — a map's axis and an element two levels down have no field-level slot to borrow.
    #
    # Included into axn's own subclasses, which places it ahead of `Clusivity` in each subclass's ancestry;
    # `delimiter` / `inclusion_method` / `resolve_value` still come from ActiveModel. The consuming app's own
    # validators are untouched.
    module WholeValueClusivity
      private

      def include?(record, value)
        members = resolve_value(record, delimiter)

        members.public_send(inclusion_method(members), value)
      end
    end
  end
end
