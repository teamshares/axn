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
        :build_class, :field, :mode, :exposed_as, :expect_attr, :inject_attrs, :error_prefix, :success,
        keyword_init: true
      )

      # @param create [Class] create-mode: the model class to instantiate
      # @param update [Symbol] update-mode: the (required) input field holding the record
      # @param as [Symbol] upsert-mode: input field; class derived from the name; exposure name
      # @param expect [Symbol] the params field name (default :params)
      # @param persist [Symbol, nil] force :create or :update (overrides inference)
      # @param error_prefix [String, nil] prefix prepended to the validation-error message
      # @param success [String, nil] override the default mode-aware success message
      # @param inject [Symbol, Array<Symbol>] context fields merged into model_params
      def self.configure(create: nil, update: nil, as: nil, expect: :params, persist: nil,
                         error_prefix: nil, success: nil, inject: nil, &block)
        raise ArgumentError, "model strategy: does not accept a block" if block

        build_class, field, mode = resolve_mode(create:, update:, as:, persist:)
        config = Config.new(
          build_class:, field:, mode:,
          exposed_as: (as || field || :model).to_sym,
          expect_attr: expect, inject_attrs: Array(inject).freeze,
          error_prefix:, success:
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

          # Final attributes: model_params (default or overridden) + injected context fields.
          # Injection applies regardless of whether model_params is overridden.
          define_method(:__axn_attributes) do
            attrs = model_params || {}
            attrs = attrs.to_h if attrs.respond_to?(:to_h)
            inject_attrs.each_with_object(attrs.dup) { |key, h| h[key] = public_send(key) }
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
        configured_success = config.success

        base.class_eval do
          # Clean validation body (NOT exception.message). Matched when the record is invalid.
          error(if: -> { __axn_model.errors.any? }, prefix: configured_prefix) do
            __axn_model.errors.full_messages.to_sentence
          end

          if configured_success
            success configured_success
          else
            success { "#{__axn_model.previously_new_record? ? 'Created' : 'Updated'} #{__axn_model.class.model_name.human}" }
          end

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
