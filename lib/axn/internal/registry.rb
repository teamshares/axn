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
            # The directory is named for the class ("MountingStrategies" -> "mounting_strategies"), split by hand
            # because `underscore` reads the host's inflections too.
            dir_name = name.split("::").last.gsub(/(?<=[a-z\d])(?=[A-Z])/, "_").downcase

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

        # The registry's OWN module (never an inherited constant) that an entry file is named for, matched
        # case- and underscore-blind (`active_job.rb` names `ActiveJob`) rather than through `camelize`, whose
        # result depends on the host's process-wide inflections (`acronym("AXN")` camelizes `axn` to `AXN`).
        # None, or more than one, is a layout mistake, refused at load rather than listing a guess.
        def _entry_constant(base)
          wanted = base.downcase.delete("_")
          candidates = constants(false).select { |const| const.to_s.downcase.delete("_") == wanted }
                                       .map { |const| const_get(const, false) }
                                       .grep(Module)
          return candidates.first if candidates.one?

          raise NotImplementedError,
                "#{name}: #{base}.rb must define exactly one module on #{name} named for it " \
                "(a helper belongs in a `_`-prefixed file, which contributes no entry)"
        end
      end
    end
  end
end
