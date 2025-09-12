# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Axn
  module Internal
    class Registry
      class NotFound < StandardError; end
      class DuplicateError < StandardError; end

      class << self
        def built_in
          # Subclasses must implement this method
          @built_in ||= raise NotImplementedError, "Subclasses must implement built_in method"
        end

        def register(name, item)
          items = all # ensure built_in is initialized
          key = name.to_sym
          raise duplicate_error_class, "#{item_type} #{name} already registered" if items.key?(key)

          items[key] = item
          items
        end

        def all
          @items ||= built_in.dup
        end

        def clear!
          @items = built_in.dup
        end

        def find(name)
          raise not_found_error_class, "#{item_type} name cannot be nil" if name.nil?
          raise not_found_error_class, "#{item_type} name cannot be empty" if name.to_s.strip.empty?

          all[name.to_sym] or raise not_found_error_class, "#{item_type} '#{name}' not found"
        end

        private

        def item_type
          # Subclasses can override this for better error messages
          "Item"
        end

        def not_found_error_class
          # Subclasses can override this to return their specific error class
          NotFound
        end

        def duplicate_error_class
          # Subclasses can override this to return their specific error class
          DuplicateError
        end
      end
    end
  end
end
