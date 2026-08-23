# frozen_string_literal: true

require "active_model"

require "axn/core/validation/validators/whole_value_clusivity"

module Axn
  module Validators
    # ActiveModel's exclusion check with the positional reading — see WholeValueClusivity. The old distributing
    # reading was wrong here under any reading, not merely unstated: `include?` is consulted by a negating
    # caller, so `all?` meant "reject only when every element is forbidden".
    class ExclusionValidator < ActiveModel::Validations::ExclusionValidator
      include WholeValueClusivity
    end
  end
end
