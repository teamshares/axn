# frozen_string_literal: true

module Axn
  module Attachable
    # Descriptor holds the information needed to attach an action
    class Descriptor
      attr_reader :name, :options, :attached_axn, :mount_strategy

      def initialize(name:, as:, axn_klass: nil, block: nil, kwargs: {})
        @mount_strategy = AttachmentStrategies.find(as)
        @existing_axn_klass = axn_klass

        @name = name
        @block = block
        @raw_kwargs = kwargs
        @kwargs = mount_strategy.preprocess_kwargs(**kwargs.except(*mount_strategy.strategy_specific_kwargs))
        @options = kwargs.slice(*mount_strategy.strategy_specific_kwargs)
        validate!
      end

      def mount(target:)
        validate_before_mount!(target:)
        attach_axn_to!(target:)

        mount_strategy.mount(descriptor: self, target:)
      end

      def attached? = @axn.present?

      private

      def attach_axn_to!(target:)
        raise "axn already attached" if attached?

        @attached_axn = @existing_axn_klass || begin
          # TODO: what if in kwargs? how make configurable
          superclass = target.axn_namespace

          Axn::Factory.build(superclass:, **@kwargs, &@block)
        end.tap do |axn|
          ConstantManager.configure_class_name_and_constant(axn, @name.to_s, target.axn_namespace)
        end
      end

      def method_name = @name.to_s.underscore

      def validate_before_mount!(target:)
        return unless target.respond_to?(method_name)

        invalid!("unable to attach -- '#{method_name}' is already taken")
      end

      def attachment_type_name
        mount_strategy.name.split("::").last.underscore.to_s.humanize
      end

      def invalid!(msg)
        raise AttachmentError, "#{attachment_type_name} #{msg}"
      end

      def validate!
        invalid!("name must be a string or symbol") unless @name.is_a?(String) || @name.is_a?(Symbol)
        invalid!("must be given an existing axn class or a block") if @existing_axn_klass.nil? && !@block.present?

        return unless @existing_axn_klass

        invalid!("was given both an existing axn class and also a block - only one is allowed") if @block.present?
        if @raw_kwargs.present? && mount_strategy != AttachmentStrategies::Step
          invalid!("was given an existing axn class and also keyword arguments - only one is allowed")
        end

        return if @existing_axn_klass.respond_to?(:<) && @existing_axn_klass < ::Axn

        invalid!("was given an already-existing class #{@existing_axn_klass.name} that does NOT inherit from Axn as expected")
      end
    end
  end
end
