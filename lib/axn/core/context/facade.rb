# frozen_string_literal: true

require "active_support/parameter_filter"

module Axn
  module Core
    class ContextFacade
      def initialize(action:, context:, declared_fields:, implicitly_allowed_fields: nil)
        if self.class.name == "Axn::Core::ContextFacade" # rubocop:disable Style/ClassEqualityComparison
          raise "Axn::Core::ContextFacade is an abstract class and should not be instantiated directly"
        end

        @context = context
        @action = action
        @declared_fields = declared_fields

        # Read once, before the first reader is defined: a legal wire key may be `class` or
        # `singleton_class` (both judged on the action class, where nothing of axn's overrides Object),
        # and the reader this loop defines for one would answer every later dispatch with the caller's
        # value. The singleton lands in an ivar because the reader-defining methods below are also
        # overridden in InternalContext and called again from Result's predicate pass, and an ivar read
        # cannot be intercepted at all.
        facade_class = self.class
        @__singleton = singleton_class

        (@declared_fields + Array(implicitly_allowed_fields)).each do |field|
          # Never define over a name the facade ITSELF answers to — its own ancestry up to Object,
          # private methods included, since those are the ones it dispatches on itself
          # (`_default_error`, `_msg_resolver`). Declarations that would land such a name are refused up
          # front (Contract::ClassMethods#_reject_shadowed_exposure_name! and its inbound twin); this is
          # the definition-site half of that rule, so a config reaching a facade without passing through
          # the DSL cannot silently take a method away. Object/Kernel are deliberately NOT asked: an
          # inbound field named `warn` or `format` is legal by design (judged on the action class, where
          # its reader lands), and the facade must answer for its wire key.
          next if Axn::Internal::NameOwnership.owner_within(facade_class, field)

          _define_reader_for(field)
        end
      end

      # Namespaced like `Axn::Result`'s `__action__`/`__exposed_keys__` rather than left as
      # `declared_fields`: every name this class owns is one an `expects`/`exposes` declaration may not
      # take, so the facade's own surface stays out of the namespace an author writes field names in.
      def __declared_fields__ = @declared_fields

      def inspect = ContextFacadeInspector.new(facade: self, action: _action, context: _context).call

      def fail!(...)
        raise Axn::ContractViolation::MethodNotAllowed, "Call fail! directly rather than on the context"
      end

      private

      # Underscored, like everything else this class owns. The facade's method table IS the set of
      # field names a declaration is refused (Contract::ClassMethods#_reject_shadowed_wire_key! and
      # its exposure twin ask it by ownership), so a helper named `action` or `context` would take two
      # ordinary domain words away from every author while offering them nothing — neither name is
      # reachable from an action or documented anywhere. Keep new helpers here underscored;
      # spec/axn/core/context/facade_name_surface_spec.rb enforces it.
      def _action = @action
      def _context = @context

      # Define one field's reader. The base (outbound Result) facade reads the data source directly;
      # InternalContext overrides this to resolve declared inbound fields through the read path.
      def _define_reader_for(field)
        if _model_fields.key?(field)
          _define_model_field_method(field, _model_fields[field])
        else
          @__singleton.define_method(field) do
            _context_data_source[field]
          end
        end
      end

      def _model_fields = _action.class._model_fields

      def _action_name = @action.class.name.presence || "The action"

      def _define_model_field_method(field, options)
        Axn::Internal::Memoization.define_memoized_reader_method(@__singleton, field) do
          Axn::Core::FieldResolvers.resolve(
            type: :model,
            field:,
            options:,
            provided_data: _context_data_source,
          )
        end
      end

      def _context_data_source = raise NotImplementedError

      def _msg_resolver(event_type, exception:)
        Axn::Core::Flow::Handlers::Resolvers::MessageResolver.new(
          _action.class._messages_registry,
          event_type,
          action: _action,
          exception:,
        )
      end
    end
  end
end
