# frozen_string_literal: true

require "active_model"

require "axn/core/validation/validators/whole_value_clusivity"

module Axn
  module Validators
    # ActiveModel's inclusion check with the positional reading — see WholeValueClusivity. Exposed as a
    # constant on `Validation::Base`, which is how `validates inclusion: …` resolves to this class rather than
    # ActiveModel's for axn's one-off validator classes, and only for those.
    class InclusionValidator < ActiveModel::Validations::InclusionValidator
      include WholeValueClusivity
    end
  end
end
