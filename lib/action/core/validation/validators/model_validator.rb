# frozen_string_literal: true

require "active_model"

module Action
  module Validators
    class ModelValidator < ActiveModel::EachValidator
      def self.model_for(field:, klass: nil)
        return klass if defined?(ActiveRecord::Base) && klass.is_a?(ActiveRecord::Base)

        field.to_s.delete_suffix("_id").classify.constantize
      end

      def self.instance_for(field:, klass:, id:)
        klass = model_for(field:, klass:)
        return unless klass.respond_to?(:find_by)

        klass.find_by(id:)
      end

      def validate_each(record, attribute, id)
        klass = self.class.model_for(field: attribute, klass: options[:with])
        instance = self.class.instance_for(field: attribute, klass:, id:)
        return if instance.present?

        msg = id.blank? ? "not found (given a blank ID)" : "not found for class #{klass.name} and ID #{id}"
        record.errors.add(attribute, msg)
      rescue StandardError => e
        warn("Model validation on field '#{attribute}' raised #{e.class.name}: #{e.message}")

        record.errors.add(attribute, "error raised while trying to find a valid #{klass.name}")
      end
    end
  end
end
