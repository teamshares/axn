# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Axn
  module Internal
    class Registry
      class NotFound < StandardError; end
      class DuplicateError < StandardError; end

      class << self
        # A built-in entry is the constant an entry file in the registry's directory is named for:
        # `adapters/sidekiq.rb` contributes `Adapters::Sidekiq` as `:sidekiq`. Nothing else the registry can
        # see is an entry: not a constant it inherits from this class (`NotFound`), not one it defines itself,
        # not a helper an entry file defines beside its entry, and not a shared helper, which lives in a
        # `_`-prefixed file (`_base.rb`) that is loaded but contributes no entry.
        def built_in
          @built_in ||= begin
            # Get the directory name from the class name (e.g., "Strategies" -> "strategies")
            dir_name = name.split("::").last.underscore

            files = ::Dir[File.join(registry_directory, dir_name, "*.rb")]
            files.each { |file| require file }

            entry_names = files.map { |file| File.basename(file, ".rb") }.reject { |base| base.start_with?("_") }
            entry_names.to_h { |base| [base.to_sym, _entry_constant(base)] }
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

        # Abstract on purpose. A registry names its OWN error classes, which are public and carry
        # Axn::Error; defaulting to the classes below would let a registry that forgot raise an
        # internal class to a caller.
        def not_found_error_class
          raise NotImplementedError, "Subclasses must implement not_found_error_class method"
        end

        def duplicate_error_class
          raise NotImplementedError, "Subclasses must implement duplicate_error_class method"
        end

        def registry_directory
          # Subclasses must override this to return their directory
          raise NotImplementedError, "Subclasses must implement registry_directory method"
        end

        # The registry's OWN constant (never an inherited one) that an entry file is named for. A file that
        # defines no such module is a layout mistake, refused at load rather than silently listing nothing.
        def _entry_constant(base)
          const_name = base.camelize
          entry = const_get(const_name, false) if const_defined?(const_name, false)
          return entry if entry.is_a?(Module)

          raise NotImplementedError,
                "#{name}: #{base}.rb must define the module #{name}::#{const_name} " \
                "(a helper belongs in a `_`-prefixed file, which contributes no entry)"
        end
      end
    end
  end
end
