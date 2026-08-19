# frozen_string_literal: true

require "axn/core/validation/fields"

module Axn
  module Validation
    # Validates the value at an UNNAMED position — an array element, and (PRO-3166 onwards) a map key or a map
    # value — against a contract of its own. `Fields` reads a NAMED attribute off its source; here the source IS
    # the value, so the read answers it whatever attribute is asked for. That one override is the whole
    # difference, and it is what lets an inner contract run through the ordinary validator pipeline: a recursive
    # `of:` applies at an unnamed position exactly as it does at a named one, at any depth, with the action and
    # the shape-walk ancestry threaded across the boundary the same way.
    #
    # ActiveModel's `error.message` excludes the attribute name, so the synthetic name the one-off class is
    # built under never reaches a message — the enclosing `OfValidator` supplies the positional prefix instead,
    # which is the only locating token an unnamed position has.
    class ContainerContents < Fields
      def read_attribute_for_validation(_attr) = @source
    end
  end
end
