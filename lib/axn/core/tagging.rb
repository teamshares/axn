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

      # A private copy of a resolved facet map for one external consumer. The
      # memoized maps are shared across sinks (notification payload, span
      # attributes, emit_metrics), so a subscriber or emit_metrics block that
      # mutates what it's handed would otherwise corrupt what the other sinks
      # see. Values are only scalars or flat arrays of scalars (guaranteed by
      # #coerce), so duping the map plus any Array/String values is a full copy.
      def self.dup_facets(map)
        map.transform_values do |value|
          case value
          when Array then value.map { |element| element.is_a?(String) ? element.dup : element }
          when String then value.dup
          else value
          end
        end
      end

      def self.resolve_one(resolver, action:)
        case resolver
        when Proc then action.instance_exec(&resolver)
        when Symbol then action.send(resolver)
        else resolver
        end
      end

      # OTLP int64 bounds — Integers outside this overflow at export.
      INT64_RANGE = (-9_223_372_036_854_775_808..9_223_372_036_854_775_807)

      # OpenTelemetry attributes accept only a String, Integer, Float, or Boolean,
      # or a *homogeneous* array of those — anything else is silently dropped by
      # the SDK. Since this is a framework primitive whose resolvers can return
      # anything, coerce defensively so the result is always legal:
      #   - non-finite Floats (NaN / Infinity) → String (rejected at export)
      #   - Integers outside the int64 range → String (OTLP overflow)
      #   - BigDecimal / Rational / Symbol / any other object → String (#to_s)
      #   - Array → each element coerced, then kept if the elements are uniformly
      #     one legal category (String, numeric, or boolean), else all stringified
      #     (see #coerce_array).
      def self.coerce(value)
        case value
        when String, true, false then value
        when Integer then INT64_RANGE.cover?(value) ? value : value.to_s
        when Float then value.finite? ? value : value.to_s
        when Array then coerce_array(value)
        else value.to_s
        end
      end

      # Coerce each element (so `[:trial, :paid]` becomes `["trial", "paid"]`,
      # consistent with scalar coercion). The OTel SDK accepts an array only when
      # its elements are uniformly String, numeric (Integer/Float, mixable), or
      # boolean (true/false, mixable); keep those as-is, otherwise stringify every
      # element so the array stays homogeneous and legal.
      def self.coerce_array(array)
        coerced = array.map { |element| coerce(element) }
        return coerced if coerced.all?(String) || coerced.all?(Numeric) || coerced.all? { |element| [true, false].include?(element) }

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
