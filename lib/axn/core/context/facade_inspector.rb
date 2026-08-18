# frozen_string_literal: true

# `Date` and `DateTime` are named below, in the branch that decides how a timestamp is displayed. Plain stdlib,
# which is why it is required here while ActiveSupport's date/time CONVERSIONS deliberately are not — see
# `timestamp_rendering`.
require "date"

require "axn/internal/identity"
require "axn/internal/native_methods"
require "axn/internal/reflection/property_names"
require "axn/internal/rendering"

module Axn
  module Core
    class ContextFacadeInspector
      def initialize(action:, facade:, context:)
        @action = action
        @facade = facade
        @context = context
      end

      # `inspect` composes at three nested levels, and EACH LEVEL NORMALIZES ITS OWN OPERANDS through
      # `rendered` — never by trusting what the level below happened to return.
      #
      # That is the whole discipline, and it is the opposite of rendering per-OPERAND: an
      # `Encoding::CompatibilityError` needs two INCOMPATIBLE operands, so a join that renders some of what it
      # receives and not the rest converts a working composition into a raise. Deciding which is which means
      # ENUMERATING the branches that can feed the join, and that enumeration is exactly what kept being
      # incomplete — a `to_fs(:inspect)` branch reachable through the documented `Date::DATE_FORMATS` extension
      # point, and an ActiveRecord-relation branch, both of which `format_for_inspect` can return and neither of
      # which was covered by rendering its other branches. Normalizing at the join makes the branch count
      # irrelevant, present and future.
      #
      # Here that means `status` and `visible_fields`, each of which is one of several shapes its own method
      # chose. `class_name` is not normalized because it is not foreign: it is the facade's OWN class (an
      # `Axn::Result` or a context facade), named by axn.
      def call
        str = [rendered(status), rendered(visible_fields)].compact_blank.join(" ")

        "#<#{class_name} #{str}>"
      end

      # THE normalization point every join in this class runs its operands through: a UTF-8 String axn owns, for
      # any object, without letting that object's own `to_s` replace the `inspect` being built. Byte-identical
      # for ASCII, so ordinary output does not move.
      #
      # `nil` passes through as `nil` rather than becoming `""`, because `call` distinguishes them —
      # `compact_blank` drops an absent `status` so an inputs facade reads `#<… a: 1>` rather than `#<…  a: 1>`.
      def rendered(value)
        return value if Axn::Internal::Identity.nil_value?(value)

        Axn::Internal::Rendering.value_rendering(value) || Axn::Internal::Rendering.class_name(value)
      end

      private

      attr_reader :action, :facade, :context

      def status
        return unless facade.is_a?(Axn::Result)

        return "[OK]" if context.ok?

        return default_message? ? "[failed]" : "[failed with '#{exception_message}']" if facade.outcome.failure?

        %([failed with #{Axn::Internal::Rendering.class_name(context.exception)}: '#{exception_message}'])
      end

      # Whether the failure carries no reason of its own, so `inspect` can say "[failed]" plainly.
      #
      # `default_message?` is axn's own predicate, but it is DEFINED only on `Axn::Failure`, and the exception
      # on a failed result frequently is not one: an exception classified into the failure bucket by
      # `fails_on`, and a `user_facing:` validation error, both settle here carrying their own class. So it is
      # asked only of an exception that answers it — the same guard `Result#_user_provided_error_message` puts
      # on the identical read, which spells it as a dispatched `is_a?`. Here the type test is undispatched
      # (`Module#===`), on the same terms as the reads below: whether axn may call its own method on a
      # caller-supplied object is a fact about the class hierarchy, not that object's opinion.
      def default_message?
        Axn::Internal::Identity.kind?(context.exception, Axn::Failure) && context.exception.default_message?
      end

      # An exception carried on a failed result is caller-supplied, and `inspect` is called from loggers,
      # debuggers and spec failure output — the places a raise is hardest to trace back. So both the class
      # and the message come from the one reader that dispatches nothing the exception can override and
      # renders the bytes it answers with.
      def exception_message = Axn::Internal::Rendering.exception_message(context.exception)

      # One entry per declared field, and the middle of the three joins: it normalizes BOTH of its operands
      # rather than either the name or the formatter's answer.
      #
      # The name goes through the shared NAME renderer, which is a different question from `rendered` and has a
      # better answer for it — a Symbol's escaped spelling, or the property it canonicalizes to — so a declared
      # name reads the way it reads in every other axn message. The formatter's answer goes through `rendered`
      # AFTER `format_for_inspect` has finished, which is what makes this independent of how many branches that
      # method has and of what any of them returns. Rendering its branches individually is what missed the
      # `to_fs(:inspect)` and ActiveRecord-relation ones (see `call`).
      #
      # Deliberately AFTER the masking and filtering too, so redaction decides what the text is and this only
      # decides its encoding: `[FILTERED]` is ASCII and renders byte-identically.
      #
      # `inspect` is read from loggers, debuggers and spec-failure output, which makes a raise here the hardest
      # kind to trace back to its cause: an exposed Latin-1 field name holding a UTF-8 value made
      # `result.inspect` raise with the result itself perfectly intact underneath.
      def visible_fields
        declared_fields.map do |field|
          value = facade.public_send(field)

          "#{rendered_field_name(field)}: #{rendered(format_for_inspect(field, value))}"
        end.join(", ")
      end

      # The reflection layer's renderer, reached directly rather than re-derived: `facade_inspector` sits ABOVE
      # that layer (nothing it requires reaches `axn/core`), so there is no cycle to route around — unlike
      # `Internal::FieldConfig`, which the reflection layer requires and which therefore composes its own.
      def rendered_field_name(field) = Axn::Internal::Reflection::PropertyNames.renderable_label(field)

      def class_name = facade.class.name
      def declared_fields = facade.send(:declared_fields)

      def format_for_inspect(field, value)
        return value.inspect if value.nil?

        # A sensitive shape member inside a non-Hash value (an object-backed shape, or malformed input) is
        # opaque to the key-name filter below, so mask that value wholesale first; a Hash value is left for
        # the per-key filtering path to redact precisely. See `_mask_unfilterable_shape_value`.
        value = action.class._mask_unfilterable_shape_value(field, value, action)

        # Initially based on https://github.com/rails/rails/blob/800976975253be2912d09a80757ee70a2bb1e984/activerecord/lib/active_record/attribute_methods.rb#L527
        #
        # Undispatched (`Module#===`) throughout, on the same terms as `day_only?` below: which arm of this
        # chain a value takes decides whether its records get LOADED, and the value is the caller's.
        inspected_value = if Axn::Internal::Identity.kind?(value, String) && value.length > 50
                            "#{value[0, 50]}...".inspect
                          elsif Axn::Internal::Identity.kind?(value, Date) || Axn::Internal::Identity.kind?(value, Time)
                            %("#{timestamp_rendering(value)}")
                          elsif defined?(::ActiveRecord::Relation) && Axn::Internal::Identity.kind?(value, ::ActiveRecord::Relation)
                            # Avoid hydrating the relation — i.e. avoid loading records just to report an error.
                            #
                            # `kind?`, not `instance_of?`: a real relation's class is the model's own
                            # `User::ActiveRecord_Relation`, so `instance_of?(::ActiveRecord::Relation)` is false
                            # for every relation an app can produce and only a bare `.allocate` satisfies it. The
                            # branch never fired, and a relation fell through to `inspect` below — hydrating
                            # exactly the records this exists to avoid loading.
                            #
                            # Named through the shared renderer rather than composed from `value.name`, which is
                            # a third dispatch and answers `"User"`. Note `Identity.class_of(value).name` is NOT
                            # the same string: ActiveRecord overrides `Class#name` on the generated relation
                            # class to return `"ActiveRecord::Relation"`, and only `Module#to_s` — what
                            # `class_name` reads — answers `"User::ActiveRecord_Relation"`.
                            Axn::Internal::Rendering.class_name(value)
                          else
                            # `Internal::Identity.describe`, not a bare `inspect`: this is a caller's value and
                            # `inspect` is its own code, so the call is made (its rendering is what makes this
                            # line useful) but its failure absorbed. That is the DISPATCH half, and it has to
                            # live here rather than at the join — a raise from `inspect` happens while this
                            # value is being formatted, before there is anything to normalize. The ENCODING
                            # half is settled once, at the join in `visible_fields`, for whichever branch of
                            # this method answered.
                            Axn::Internal::Identity.describe(value)
                          end

        # Sensitive subfields and shape members live nested inside a structured value; once it has been
        # stringified above, `filter_param(field, ...)` (which matches on the top-level key only) can no
        # longer reach the nested keys. So filter the structure itself first — Hash or Array, since an
        # Array-element member redacts per element — then inspect the filtered result. If nothing nested
        # matched, fall through so a sensitive top-level field (whose whole value is redacted by name) is
        # still handled.
        if value.is_a?(Hash) || value.is_a?(Array)
          nested_keys = nested_sensitive_keys(field)
          unless nested_keys.empty?
            filtered = ActiveSupport::ParameterFilter.new(nested_keys).filter({ field => value })[field]
            # Route the filtered structure back through the top-level filter (same as the scalar path
            # below) so a field that is ITSELF sensitive redacts wholesale by name — otherwise the
            # partially-filtered structure would expose the parent's non-sensitive keys. Read through the same
            # guarded reader as the scalar path, for the same dispatch reason: the container is axn's own copy,
            # but its CONTENTS are the caller's, and `Hash#inspect`/`Array#inspect` dispatch each element's own
            # `inspect`.
            return inspection_filter.filter_param(field, Axn::Internal::Identity.describe(filtered))
          end
        end

        inspection_filter.filter_param(field, inspected_value)
      end

      # ISO-8601: unambiguous, sorts lexicographically, and assumes no locale — the right default for a value
      # written into debug output that a human and a log search both read.
      #
      # Two formats rather than one, because a `DateTime` IS a `Date`: rendering both the same way would mean
      # rendering a DateTime as a bare day and silently dropping its time. So the day-only form belongs to the
      # value that carries no time of day, and the date-and-offset form to the two that do.
      ISO8601_DAY = "%Y-%m-%d"
      ISO8601_TIMESTAMP = "%Y-%m-%dT%H:%M:%S%:z"
      private_constant :ISO8601_DAY, :ISO8601_TIMESTAMP

      # How a Date/DateTime/Time is displayed: ActiveSupport's `to_fs(:inspect)` when the value actually answers
      # to it, and axn's own ISO-8601 rendering when it does not.
      #
      # `to_fs` is preferred because it is the only thing that honours an app's registered
      # `Date::DATE_FORMATS[:inspect]`, so an app that has customized how a date reads sees its own format here.
      # Axn deliberately does NOT require the core_exts that define it: loading those replaces `Date#inspect`
      # and `DateTime#inspect` process-wide, so requiring them would redecorate a core class in every host
      # process that loads this gem, for the sake of this gem's own debug output. A library does not get to do
      # that to its host. Degrading locally instead keeps the whole cost inside axn — the only difference is the
      # exact spelling of a date in an `inspect` string when ActiveSupport's conversions are not loaded.
      #
      # Availability is read out of the METHOD TABLE (`NativeMethods.method_owner`, which answers nil when there
      # is no such method) rather than asked of the value: the value is caller-supplied, a `Date` subclass can
      # define `respond_to?`, and this is a display path that must not raise.
      def timestamp_rendering(value)
        return value.to_fs(:inspect) if Axn::Internal::NativeMethods.method_owner(value, :to_fs)

        value.strftime(day_only?(value) ? ISO8601_DAY : ISO8601_TIMESTAMP)
      end

      # Whether this value carries a date and no time of day. `DateTime` is EXCLUDED rather than left to be
      # tested first: it subclasses `Date`, so a plain `kind?(value, ::Date)` is true for one, and the ordering
      # of two tests is a weaker guarantee than saying which class is meant. Undispatched (`Module#===`), on the
      # same terms as every other type test in this file.
      def day_only?(value)
        Axn::Internal::Identity.kind?(value, ::Date) && !Axn::Internal::Identity.kind?(value, ::DateTime)
      end

      def inspection_filter
        @inspection_filter ||= if action.class._has_dynamic_sensitive_fields?
                                 action.class._build_instance_filter(action)
                               else
                                 action.class.inspection_filter
                               end
      end

      # ParameterFilter keys for sensitive values nested inside `field`'s structured value: sensitive
      # subfield wire paths (dotted, precise to their parent) plus sensitive shape-member names (flat —
      # a member redacts by name wherever it appears, i.e. every array element and any nesting depth).
      def nested_sensitive_keys(field)
        subfield_paths = action.class.subfield_configs
                               .select { |config| sensitive_subfield_on?(config, field) }
                               .map { |config| action.class._resolved_subfields.index[config].wire_path.join(".") }

        subfield_paths + sensitive_member_names(field)
      end

      # `field` is the top-level parent's wire key; the config's resolved wire path (from the per-class
      # SubfieldTree cache) already translated any `as:`/`prefix:` alias and nested `on:` chain back to
      # wire keys, so a sensitive subfield matches whichever top-level value it ultimately lives under.
      def sensitive_subfield_on?(config, field)
        path = action.class._resolved_subfields.index[config]
        path && path.wire_path.first == field && action.class._resolve_sensitive_value(config.sensitive, action, field: config.field)
      end

      # Names of sensitive shape members that render inside `field`'s displayed value (nested shapes
      # included), with dynamic `sensitive:` predicates resolved against the action instance — matching
      # how inputs_for_logging filters. The walk itself belongs to the contract (see
      # `Contract#_sensitive_member_names`), which reuses the answer when no `sensitive:` needs an
      # instance; `inspect` asks once per displayed field, over the whole stored graph.
      def sensitive_member_names(field)
        shape_bearing_configs_under(field).flat_map { |config| action.class._sensitive_member_names(config, action) }
      end

      # Configs whose shape members would appear inside `field`'s value: the top-level field config
      # itself, plus any subfield config resolving to a wire path rooted at `field` (a shape block
      # declared on a subfield). Logging redacts both because `_sensitive_candidate_configs` walks
      # `subfield_configs`; inspect must match rather than only covering top-level shapes.
      def shape_bearing_configs_under(field)
        top_level = (action.class.internal_field_configs + action.class.external_field_configs).select { |c| c.field == field }
        subfields = action.class.subfield_configs.select do |config|
          path = action.class._resolved_subfields.index[config]
          path && path.wire_path.first == field
        end
        top_level + subfields
      end
    end
  end
end
