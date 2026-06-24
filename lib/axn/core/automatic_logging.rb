# frozen_string_literal: true

module Axn
  module Core
    module AutomaticLogging
      # The outcomes `result.outcome` can report, each independently configurable.
      OUTCOMES = %i[success failure exception].freeze

      def self.included(base)
        base.class_eval do
          extend ClassMethods

          # Per-outcome log levels; a nil value means that outcome is not logged.
          # Defaults to every outcome at the configured level (logging on by default).
          default_level = Axn.config.log_level
          class_attribute :_auto_log_levels,
                          default: OUTCOMES.each_with_object({}) { |outcome, h| h[outcome] = default_level }
        end
      end

      # Resolve `auto_log` arguments into a frozen {success:, failure:, exception:} level hash.
      #
      # - A positional level is the default for any outcome not named by a keyword.
      # - `success:`/`failure:`/`exception:` keywords override per outcome.
      # - With no positional and at least one keyword, unnamed outcomes are off (so keyword-only
      #   forms log *only* the named outcomes).
      # - A bare `auto_log` (no positional, no keywords) logs every outcome at the configured level.
      def self.resolve_levels(args, overrides)
        raise ArgumentError, "auto_log accepts at most one positional level argument" if args.size > 1

        # Indifferent access: a string-keyed Hash (e.g. forwarded by Axn::Factory.build from
        # YAML/params) resolves the same as symbol keys.
        overrides = overrides.transform_keys(&:to_sym)
        unknown = overrides.keys - OUTCOMES
        raise ArgumentError, "auto_log got unknown outcome(s): #{unknown.join(', ')} (expected #{OUTCOMES.join('/')})" if unknown.any?

        base = base_level(args, overrides)
        OUTCOMES.each_with_object({}) do |outcome, hash|
          hash[outcome] = overrides.key?(outcome) ? normalize_level(overrides[outcome]) : base
        end.freeze
      end

      # The base level for unspecified outcomes (see resolve_levels).
      def self.base_level(args, overrides)
        return normalize_level(args.first) unless args.empty?

        overrides.empty? ? Axn.config.log_level : nil
      end

      # Coerce a single level value: true → configured default, false/nil → off, a valid level → itself.
      def self.normalize_level(value)
        case value
        when true then Axn.config.log_level
        when false, nil then nil
        when *Core::Logging::LEVELS then value
        else
          raise ArgumentError, "Invalid log level: #{value.inspect} (expected one of #{Core::Logging::LEVELS.join('/')})"
        end
      end

      module ClassMethods
        # Declarative control over automatic logging. Examples:
        #   auto_log :warn                     # all outcomes at :warn (before + after)
        #   auto_log false                     # fully silent
        #   auto_log :warn, success: false     # errors only, no before line
        #   auto_log exception: :error         # only log raised exceptions
        def auto_log(*args, **overrides)
          self._auto_log_levels = AutomaticLogging.resolve_levels(args, overrides)
        end

        # Level for a given outcome, or nil if that outcome should not be logged.
        def _auto_log_level_for(outcome)
          _auto_log_levels[outcome.to_sym]
        end

        # The "About to execute" / start line rides at the success level (and is suppressed when
        # success logging is off), so the before/after bookend is a property of narrating
        # successful calls rather than a separate knob.
        def _auto_log_before_level
          _auto_log_levels[:success]
        end
      end
    end
  end
end
