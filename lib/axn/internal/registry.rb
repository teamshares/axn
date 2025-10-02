# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Axn
  module Internal
    class Registry
      class NotFound < StandardError; end
      class DuplicateError < StandardError; end

      class << self
        def built_in
          @built_in ||= begin
            # Get the directory name from the class name (e.g., "Strategies" -> "strategies")
            dir_name = name.split("::").last.underscore

            # Load all files from the directory
            files = Dir[File.join(registry_directory, dir_name, "*.rb")]
            files.each { |file| require file }

            # Get all modules defined within this class
            constants = self.constants.map { |const| const_get(const) }
            items = select_constants_to_load(constants)

            # Convert module names to keys
            items.to_h do |item|
              name = item.name.split("::").last
              key = name.underscore.to_sym
              [key, item]
            end
          end
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

        def registry_directory
          # Subclasses must override this to return their directory
          raise NotImplementedError, "Subclasses must implement registry_directory method"
        end

        def select_constants_to_load(constants)
          # Subclasses can override this to select which constants to load
          constants.select { |const| const.is_a?(Module) }
        end
      end
    end
  end
end
