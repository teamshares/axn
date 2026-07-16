# frozen_string_literal: true

# A valid Axn tool that a sibling file requires BEFORE that sibling raises. It proves the
# failed-load rollback is scoped to the failing file's own classes: this dependency's class was
# registered inside the failing file's require window but must SURVIVE the rollback
# (spec/axn/tools/registry_spec.rb).
module NestedDep
  class Good
    include Axn
    tool

    def call = nil
  end
end
