# frozen_string_literal: true

module Axn
  module Attachable
    # Descriptor holds the information needed to attach an action
    Descriptor = Data.define(:name, :axn_klass, :as)
  end
end
