# frozen_string_literal: true

module Axn
  module Core
    # Declarative per-action observability facets. `tag` (high-cardinality) and
    # `dimension` (bounded) share parsing/resolution; they differ only in which
    # sinks the executor routes them to.
    module Tagging
      def self.included(base)
        base.class_eval do
          extend ClassMethods
          class_attribute :_tags, default: {}
          class_attribute :_dimensions, default: {}
        end
      end

      # Resolve a declared map against a running action instance, at the
      # settled-result point. Each resolver runs independently; a nil result
      # omits the facet, a raised error is swallowed and that facet skipped.
      def self.resolve(map, action:)
        map.each_with_object({}) do |(name, resolver), acc|
          value = resolve_one(resolver, action:)
          acc[name] = coerce(value) unless value.nil?
        rescue StandardError => e
          Axn::Internal::PipingError.swallow("resolving observability facet #{name}", action:, exception: e)
        end
      end

      def self.resolve_one(resolver, action:)
        case resolver
        when Proc then action.instance_exec(&resolver)
        when Symbol then action.send(resolver)
        else resolver
        end
      end

      # OpenTelemetry attributes accept only String / Integer / Float / Boolean,
      # or a homogeneous array of one of those. Pass those scalars through; coerce
      # anything else to a String (notably non-Integer/Float numerics like
      # BigDecimal/Rational, which the OTel SDK drops); coerce array elements
      # (see #coerce_array).
      def self.coerce(value)
        case value
        when String, Integer, Float, true, false then value
        when Array then coerce_array(value)
        else value.to_s
        end
      end

      # Coerce each element (so `[:trial, :paid]` becomes `["trial", "paid"]`,
      # consistent with scalar coercion). OTel array attributes must be homogeneous
      # in a single scalar type, so if per-element coercion still leaves a mix
      # (e.g. `[1, :a]`), stringify every element to keep the array legal.
      def self.coerce_array(array)
        coerced = array.map { |element| coerce(element) }
        return coerced if coerced.all?(String) || coerced.all?(Numeric) || coerced.all? { |e| [true, false].include?(e) }

        coerced.map(&:to_s)
      end

      module ClassMethods
        def tag(*args, **kwargs, &block)
          self._tags = _tags.merge(_parse_facets(args, kwargs, block))
        end

        def dimension(*args, **kwargs, &block)
          self._dimensions = _dimensions.merge(_parse_facets(args, kwargs, block))
        end

        private

        # Dual form, mirroring Contract#expose: a name + positional/block value,
        # or a hash of name => resolver. Returns a symbol-keyed hash.
        def _parse_facets(args, kwargs, block)
          if args.any?
            raise ArgumentError, "expected a name and a single resolver (or a hash)" unless args.size <= 2
            raise ArgumentError, "provide a resolver (positional, block, or hash), not both" if args.size == 2 && block
            raise ArgumentError, "provide a resolver: a positional value, a block, or the hash form" if args.size == 1 && !block

            name = args.first
            value = block || args.last

            kwargs = kwargs.merge(name => value)
          elsif block
            raise ArgumentError, "provide a block only with the single-name form (e.g. `tag(:name) { ... }`)"
          end

          kwargs.transform_keys(&:to_sym)
        end
      end
    end
  end
end
