# frozen_string_literal: true

module Axn
  class Strategies
    # Standardizes "build/find an ActiveRecord model, apply attributes, save it, and settle
    # validation failures cleanly" actions. Sibling to `use :form`: validate via a form object
    # → `use :form`; validate-and-save a real model → `use :model`.
    #
    #   use :model, create: Widget          # create from model_params
    #   use :model, update: :widget         # update a passed-in record
    #   use :model, as: :widget             # upsert (update if provided/found, else create)
    #
    # The action supplies attributes via an overridable `model_params` (defaults to `params`).
    module Model
      Config = Struct.new(
        :build_class, :field, :mode, :exposed_as, :expect_attr, :inject_attrs, :error_prefix,
        keyword_init: true
      )

      # @param create [Class] create-mode: the model class to instantiate
      # @param update [Symbol] update-mode: the (required) input field holding the record
      # @param as [Symbol] upsert-mode: input field; class derived from the name; exposure name
      # @param expect [Symbol] the params field name (default :params)
      # @param persist [Symbol, nil] force :create or :update (overrides inference)
      # @param error_prefix [String, nil] prefix prepended to the validation-error message
      # @param inject [Symbol, Array<Symbol>] context fields merged into model_params
      #
      # To override the success or full error message, declare your own `success`/`error`
      # after `use :model` (later declarations win) — only the prefix-while-keeping-the-
      # validation-body case needs the dedicated `error_prefix:` kwarg.
      def self.configure(create: nil, update: nil, as: nil, expect: :params, persist: nil,
                         error_prefix: nil, inject: nil, &block)
        raise ArgumentError, "model strategy: does not accept a block" if block

        build_class, field, mode = resolve_mode(create:, update:, as:, persist:)
        config = Config.new(
          build_class:, field:, mode:,
          exposed_as: (as || field || :model).to_sym,
          expect_attr: expect, inject_attrs: Array(inject).freeze,
          error_prefix:
        )

        Module.new do
          extend ActiveSupport::Concern
          included { Axn::Strategies::Model.install!(self, config) }
        end
      end

      # @return [Array(Class|nil, Symbol|nil, Symbol)] (build_class, field, mode)
      def self.resolve_mode(create:, update:, as:, persist:)
        build_class, field, mode =
          if create
            [create, nil, :create]
          elsif update
            [nil, update, :update]
          elsif as
            [as.to_s.classify.constantize, as, :upsert]
          else
            raise ArgumentError, "model strategy: provide one of create:, update:, or as:"
          end

        mode = persist if persist
        [build_class, field, mode]
      end

      def self.install!(base, config)
        install_contract!(base, config)
        install_attributes!(base, config)
        install_messages!(base, config)
        install_hooks!(base, config)
      end

      def self.install_contract!(base, config)
        field = config.field
        mode = config.mode
        base.class_eval do
          expects config.expect_attr, default: {}, allow_blank: true

          # Declare the model field unless the action already declared it (custom finder/options).
          expects field, model: true, optional: (mode != :update) if field && internal_field_configs.none? { |fc| fc.field == field }

          exposes config.exposed_as
        end
      end

      def self.install_attributes!(base, config)
        expect_attr = config.expect_attr
        inject_attrs = config.inject_attrs
        field = config.field
        build_class = config.build_class
        mode = config.mode
        exposed_as = config.exposed_as

        base.class_eval do
          # Default attribute source; override with `def model_params` in the action.
          define_method(:model_params) { public_send(expect_attr) } unless method_defined?(:model_params) || private_method_defined?(:model_params)

          # Final attributes: injected context fields, with model_params layered on top.
          # Injection applies regardless of whether model_params is overridden; an explicit
          # model_params key wins over an injected one (model_params is the more direct intent).
          define_method(:__axn_attributes) do
            attrs = model_params || {}

            # Fail loudly (and actionably) on unpermitted strong params rather than letting
            # `.to_h` raise a cryptic UnfilteredParameters / assign_attributes raise ForbiddenAttributes.
            if attrs.respond_to?(:permitted?) && !attrs.permitted?
              raise ArgumentError,
                    "use :model received unpermitted parameters from `model_params`; permit them " \
                    "(e.g. `params.permit(...)`/`.slice(...)`) or override `model_params` to return a Hash"
            end

            attrs = attrs.to_h if attrs.respond_to?(:to_h)
            injected = inject_attrs.to_h { |key| [key, public_send(key)] }
            injected.merge(attrs)
          end
          private :__axn_attributes

          # Resolve + assign the record (memoized): existing for update, freshly built for create.
          # Reads the input field via its contract reader (`public_send(field)`); we must NOT
          # shadow that reader, or we'd recurse when exposed_as == field.
          define_method(:__axn_model) do
            @__axn_model ||= begin
              existing = field ? public_send(field) : nil
              record = existing || build_class&.new
              raise ArgumentError, "model strategy: no record to #{mode} (field #{field.inspect} was blank)" if record.nil?

              record.assign_attributes(__axn_attributes)
              record
            end
          end
          private :__axn_model

          # Expose under `exposed_as`. Provide a reader unless the input field already supplies one.
          define_method(exposed_as) { __axn_model } unless exposed_as == field
        end
      end

      def self.install_messages!(base, config)
        configured_prefix = config.error_prefix

        base.class_eval do
          # The record carrying the validation errors. A *raised* RecordInvalid names its own
          # record (handles association autosave / a nested `save!` on a *different* record than
          # the one we built); otherwise the gated save failed on our built/loaded model. Guard on
          # the memoized ivar so an *unrelated* failure (model never built) doesn't construct it —
          # with side effects — during message resolution.
          define_method(:__axn_invalid_record) do |exception = nil|
            if defined?(ActiveRecord::RecordInvalid) && exception.is_a?(ActiveRecord::RecordInvalid) && exception.record
              exception.record
            elsif instance_variable_defined?(:@__axn_model)
              @__axn_model
            end
          end
          private :__axn_invalid_record

          # Clean validation body (NOT exception.message). Matched when the invalid record is known.
          error(if: ->(exception: nil) { (rec = __axn_invalid_record(exception)) && rec.errors.any? }, prefix: configured_prefix) do |exception = nil|
            __axn_invalid_record(exception).errors.full_messages.to_sentence
          end

          # Default mode-aware success; override by declaring `success` after `use :model`.
          success { "#{__axn_model.previously_new_record? ? 'Created' : 'Updated'} #{__axn_model.class.model_name.human}" }

          # Safety net for a *raised* RecordInvalid (save!, association autosave, validate!, nested).
          fails_on(ActiveRecord::RecordInvalid) if defined?(ActiveRecord::RecordInvalid)
        end
      end

      def self.install_hooks!(base, config)
        exposed_as = config.exposed_as
        base.class_eval do
          # Prepare-and-gate in `before` (mirrors `use :form`); `call` is post-save logic.
          before { expose(exposed_as => __axn_model) }
          before { fail! unless __axn_model.save }
        end
      end
    end
  end
end
