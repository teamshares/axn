# frozen_string_literal: true

module Axn
  module Async
    module BatchEnqueue
      # Stores the configuration for a single enqueues_each declaration
      class Config
        attr_reader :field, :from, :via, :filter_block

        def initialize(field:, from:, via:, filter_block:)
          @field = field
          @from = from
          @via = via
          @filter_block = filter_block
        end

        # Resolves the source collection for iteration
        # Can be a lambda, a symbol (method name on target), or inferred from model: true
        def resolve_source(target:)
          return from.call if from.is_a?(Proc)
          return target.send(from) if from.is_a?(Symbol)

          # Infer from field's model config if 'from' is nil
          field_config = target.internal_field_configs.find { |c| c.field == field }
          model_opts = field_config&.validations&.dig(:model)
          model_class = model_opts[:klass] if model_opts.is_a?(Hash)

          unless model_class
            raise ArgumentError,
                  "enqueues_each :#{field} requires `from:` option or a `model:` declaration " \
                  "on `expects :#{field}` to infer the source collection."
          end
          model_class.all
        end
      end
    end
  end
end
