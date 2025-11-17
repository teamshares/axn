# frozen_string_literal: true

# This is a base class for all form objects that are used with Axn actions.
#
# It provides a number of conveniences for working with form objects, including:
# - Automatically attr_accessor any attribute for which we add a validation
# - Add support for nested forms
# - Add support for money objects (analogous to 'include MoneyRails::ActiveRecord::Monetizable' for ActiveRecord models)
module Axn
  class FormObject
    include ActiveModel::Model

    class << self
      attr_accessor :field_names

      def inherited(subclass)
        # Inherit field_names from parent class, or initialize as empty array if parent doesn't have any
        subclass.field_names = (field_names || []).dup

        super
      end

      # Override attr_accessor to track field names for automatic #to_h support
      def attr_accessor(*attributes)
        # Initialize field_names if not already set
        self.field_names ||= []

        # Add new attributes to the field_names array
        self.field_names += attributes.map(&:to_sym)

        super
      end

      # Automatically attr_accessor any attribute for which we add a validation
      def validates(*attributes)
        our_attributes = attributes.dup

        # Pulled from upstream: https://github.com/rails/rails/blob/6f0d1ad14b92b9f5906e44740fce8b4f1c7075dc/activemodel/lib/active_model/validations/validates.rb#L106
        our_attributes.extract_options!
        our_attributes.each { |attr| attr_accessor(attr) }

        super
      end

      # Add support for nested forms
      def nested_forms(**kwargs)
        kwargs.each do |name, klass|
          validates name, presence: true

          define_method("#{name}=") do |params|
            return instance_variable_set("@#{name}", nil) if params.nil?

            child_params = params.dup

            # Automatically inject the parent into the child form if it has a parent= method
            child_params[:parent_form] = self if klass.instance_methods.include?(:parent_form=)

            instance_variable_set("@#{name}", klass.new(child_params))
          end

          validation_method_name = :"validate_#{name}_form"
          validate validation_method_name
          define_method(validation_method_name) do
            return if public_send(name).nil? || public_send(name).valid?

            public_send(name).errors.each do |error|
              errors.add("#{name}.#{error.attribute}", error.message)
            end
          end
          private validation_method_name
        end
      end
      alias nested_form nested_forms
    end

    def to_h
      return {} if self.class.field_names.nil?

      self.class.field_names.each_with_object({}) do |field_name, hash|
        next unless respond_to?(field_name)

        value = public_send(field_name)
        hash[field_name] = value.is_a?(Axn::FormObject) ? value.to_h : value
      end
    end
  end
end
