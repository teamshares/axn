# frozen_string_literal: true

require "axn/internal/identity"

module Axn
  module Core
    module FieldResolvers
      class Model
        # The finder classes that mean "no such record" rather than "the lookup broke", when the
        # declaration names none of its own. Resolved on every ask rather than memoized: axn boots
        # without Rails and a host may load ActiveRecord after axn (the alpha.5 engine load-order
        # regression), so a constant captured at require time would answer for the whole process
        # from whichever side of that boot it happened to be built on.
        def self.default_not_found_classes
          defined?(::ActiveRecord::RecordNotFound) ? [::ActiveRecord::RecordNotFound] : []
        end

        # The classes THIS declaration treats as a miss — its own `not_found_on:` when it named one
        # (already normalized to an Array at declaration), the default set otherwise. An explicit
        # empty Array is a real answer, not an absent one: it opts the field out entirely, so every
        # exception the finder raises stays a fault.
        def self.not_found_classes(options)
          declared = options[:not_found_on]
          declared.nil? ? default_not_found_classes : declared
        end

        def initialize(field:, options:, provided_data:, permit_method_call: false)
          @field = field
          @options = options
          @provided_data = provided_data
          @permit_method_call = permit_method_call
        end

        def call
          provided_value.presence || derive_value
        end

        private

        attr_reader :field, :options, :provided_data, :permit_method_call

        def provided_value
          @provided_value ||= _read(field)
        end

        def derive_value
          # `id_value` is read here, OUTSIDE the guarded block: a forgotten `method_call:` reached via
          # the `_id` read raises MethodCallNotPermittedError, a contract bug that must stay loud
          # (PRO-2898's "loud, never silent" guarantee) rather than being swallowed to nil.
          return nil if id_value.blank?

          finder_name = finder.is_a?(Method) ? finder.name : finder
          # `standard_errors_only:` is the one place in the library where letting an exception through
          # beats swallowing it — but it narrows to the StandardError boundary, so what it lets escape is
          # the non-StandardError allowlist alone (a runaway finder's SystemStackError), which this
          # boundary settles into a reported result naming the real stack. Everything else the finder
          # raises is a fault the guard swallows, warns about, and reports as an ignored exception.
          #
          # A declared MISS is not one of those, and never reaches the guard: the finder answering "no
          # such record" is a statement about the caller's id, structurally identical to the finder
          # returning nil, and the two spellings must mean the same thing (PRO-3369). Converting it here
          # rather than around the guard is what keeps it out of `on_ignored_exception` — an ordinary bad
          # argument is not an app bug, the policy `Axn::Tools::Invoker` already applies to every other
          # inbound violation. The resulting nil is classified by the field's own validation, where
          # `ModelValidator` says "not found" rather than "can't be blank".
          Axn::Extensions.best_effort("finding #{field} with #{finder_name}", standard_errors_only: true) do
            _invoke_finder
          rescue StandardError => e
            raise unless _declared_miss?(e)

            nil
          end
        end

        def _invoke_finder
          if finder.is_a?(Method)
            # Method object - call it directly
            finder.call(id_value)
          elsif klass.respond_to?(finder)
            # Symbol/string method name on the klass
            klass.public_send(finder, id_value)
          else
            raise "Unknown finder: #{finder}"
          end
        end

        # Undispatched ancestry, on the same terms as `Extensions.swallowable?`: this decides whether axn
        # may absorb the exception instead of reporting it, and the only thing that authorizes that is the
        # declared class actually being in the raised class's ancestry — not the instance's opinion of
        # itself. Iterating the list also avoids `rescue *classes`, whose empty splat silently degrades to
        # `rescue StandardError` and would absorb every finder fault on an opted-out field.
        def _declared_miss?(exception)
          self.class.not_found_classes(options).any? { |klass| Axn::Internal::Identity.kind?(exception, klass) }
        end

        def klass
          @klass ||= options[:klass]
        end

        def finder
          @finder ||= options[:finder]
        end

        def id_field
          @id_field ||= Axn::Internal::FieldConfig.model_id_key(field)
        end

        def id_value
          @id_value ||= _read(id_field)
        end

        # Reads a key through the canonical extraction path (segment-by-segment, key-or-method
        # dispatch, indifferent access) rather than a raw `[]`, so model reads behave identically to
        # every other reader: a dotted key (`items.widget`) digs the nested path, a record parent is
        # read by method, and a source that can't answer the key (e.g. a String where a Hash was
        # declared) reads as ABSENT — its own type validation classifies the malformed value
        # (PRO-2857) rather than a raw error pre-empting the contract.
        def _read(key)
          Axn::Core::FieldResolvers.extract_or_nil(field: key, provided_data:, permit_method_call:)
        end
      end
    end
  end
end
