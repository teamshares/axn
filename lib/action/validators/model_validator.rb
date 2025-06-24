# frozen_string_literal: true

require "active_model"

module Action
  module Validators
    class ModelValidator < ActiveModel::EachValidator
      def self.model_for(attribute:, klass: nil)
        return klass if defined?(ActiveRecord::Base) && klass.is_a?(ActiveRecord::Base)

        attribute.to_s.delete_suffix("_id").classify.constantize
      end

      def validate_each(record, attribute, value)
        klass = self.class.model_for(attribute:, klass: options[:with])
        instance = klass.find_by(id: value)
        return if instance.present?

        record.errors.add(attribute, "not found for class #{klass.name} and ID #{value}")
      rescue StandardError => e
        warn("Model validation on field '#{attribute}' raised #{e.class.name}: #{e.message}")

        record.errors.add(attribute, "error raised while trying to find a valid #{klass.name}")
      end
    end
  end
end
