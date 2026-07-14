# frozen_string_literal: true

require "axn/core/field_resolvers/model"
require "axn/core/field_resolvers/extract"

module Axn
  module Core
    module FieldResolvers
      # Registry for field resolvers
      # This allows us to easily add new field types in the future
      RESOLVERS = {
        model: FieldResolvers::Model,
        extract: FieldResolvers::Extract,
      }.freeze

      # `permit_method_call:` opts a resolution into the sharp path — resolving a segment by INVOKING
      # it as a method (Array methods, PORO readers, Data behavioral methods). It defaults to false so
      # the safe default reads declared data only (Hash keys, Struct/OpenStruct/Data members); a
      # segment that can only be method-dispatched raises MethodCallNotPermittedError unless permitted.
      # The flag is a per-declaration fact (`expects ..., method_call: true`) threaded from the
      # config-bearing call sites; see the PRO-2898 design.
      def self.resolve(type:, field:, provided_data:, options: {}, permit_method_call: false)
        resolver_class = RESOLVERS[type]
        raise ArgumentError, "Unknown field resolver type: #{type}" unless resolver_class

        # A nil source means "absent": there's nothing to extract or look up, so every resolver yields
        # nil rather than reaching into it. This is what lets a subfield hang off a nil/omitted parent —
        # its own optional/required rules then apply against nil (optional passes, required fails with a
        # clean validation error) instead of the resolver blowing up mid-resolution (PRO-2857).
        return nil if provided_data.nil?

        resolver_class.new(field:, options:, provided_data:, permit_method_call:).call
      end

      # THE tolerant read for the subfield contract machinery: a source that can't answer the named
      # path (a malformed value where an object was declared — Extract's UnextractableError) reads
      # as ABSENT, the same way a nil source does above. The field's own validators then report
      # against nil while the malformed ancestor's own type validation classifies the bad value —
      # one doctrine, applied by every reader, validation source, and pre-validation pass, so
      # malformed caller input always settles as a contract error rather than a raw exception.
      # (Consumers that want the loud typed error call .resolve directly.)
      #
      # `permit_method_call:` is forwarded so a config that opted into method dispatch still resolves
      # here; the rescue is deliberately narrowed to UnextractableError, so a
      # MethodCallNotPermittedError (a forgotten `method_call:`) is NOT swallowed to absent — it
      # propagates loudly, exactly the "loud, never silent" guarantee the design requires.
      def self.extract_or_nil(field:, provided_data:, permit_method_call: false)
        resolve(type: :extract, field:, provided_data:, permit_method_call:)
      rescue Axn::ContractViolation::UnextractableError
        nil
      end
    end
  end
end
