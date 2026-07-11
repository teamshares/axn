# frozen_string_literal: true

module Axn
  # Normalizes the flexible `expects:`/`exposes:` declaration formats into a
  # uniform `{ field => opts_hash }` shape. Accepts an already-built Hash (passed
  # through untouched), or an Array whose elements are either bare field names
  # (Symbol/String, hydrated to empty opts) or Hashes of `field => opts`.
  #
  # Shared so callers building Axn classes outside Factory (e.g. adapters that
  # define #call themselves rather than routing a callable through Factory) can
  # reuse the exact same normalization instead of duplicating it.
  module FieldDeclarations
    module_function

    def hydrate(declarations)
      return declarations if declarations.is_a?(Hash)

      Array(declarations).each_with_object({}) do |item, acc|
        if item.is_a?(Hash)
          item.each { |k, v| acc[k] = v }
        else
          acc[item] = {}
        end
      end
    end
  end
end
