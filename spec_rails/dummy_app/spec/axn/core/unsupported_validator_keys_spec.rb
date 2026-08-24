# frozen_string_literal: true

# The Rails half of spec/axn/core/validations/unsupported_validator_keys_spec.rb.
#
# The whole premise of refusing `uniqueness:` is that it stays unreachable even where ActiveRecord IS loaded —
# which is the only environment an author would reach for it in. The non-Rails suite cannot show that: it
# proves the constant is missing from a process that never had ActiveRecord to begin with, which is true and
# beside the point. So the load-bearing assertion lives here, where `ActiveRecord::Validations::
# UniquenessValidator` genuinely exists in the process and the refusal has something to be wrong about.
RSpec.describe "validator keys ActiveModel cannot resolve, with ActiveRecord loaded" do
  before(:all) { Rails.application.initialize! unless Rails.application.initialized? }

  # The controls that keep everything below non-vacuous: without these, a Rails suite that had quietly
  # stopped loading ActiveRecord would still pass every example here while testing nothing.
  it "really does have ActiveRecord and its UniquenessValidator loaded" do
    expect(defined?(ActiveRecord)).to eq("constant")
    expect(defined?(ActiveRecord::Validations::UniquenessValidator)).to eq("constant")
  end

  # `validates` resolves a validator by `const_get` from the class being declared on — for axn a
  # `Validation::Base` subclass, whose ancestry is `ActiveModel::Validations` plus axn's own validator
  # constants. `ActiveRecord::Validations::UniquenessValidator` is namespaced under ActiveRecord, so it is not
  # reachable from there however much of Rails is booted.
  it "still cannot reach UniquenessValidator from an axn validator class" do
    expect { Axn::Validation::Base.const_get("UniquenessValidator") }.to raise_error(NameError)
  end

  it "refuses uniqueness: at declaration rather than raising on every call" do
    expect { build_axn { expects :v, type: String, uniqueness: true } }
      .to raise_error(ArgumentError, /uniqueness: on :v is not supported.*ActiveRecord validator/m)
  end

  # A `model:` field is the one place a record genuinely exists, and is exactly where the option looks most
  # plausible — so it is refused there too rather than acquiring a second, model-only meaning.
  it "refuses uniqueness: on a model: field, where a record does exist" do
    expect { build_axn { expects :user, model: { klass: User }, uniqueness: true } }
      .to raise_error(ArgumentError, /uniqueness: on :user is not supported/)
  end

  it "refuses a bare message: at declaration" do
    expect { build_axn { expects :v, type: String, message: "nope" } }
      .to raise_error(ArgumentError, /message: on :v is not an option at this level/)
  end

  # The controls, mirrored on the Rails side: the bag spelling is what the refusal points at, and a field
  # NAMED `message` is untouched.
  it "leaves message: inside a validator's own bag working" do
    action = build_axn { expects :v, type: { klass: String, message: "must be a string" } }

    expect(action.call(v: 1).exception.message).to include("must be a string")
  end

  it "leaves a field named message alone" do
    action = build_axn { expects :message, type: String }

    expect(action.call(message: "a")).to be_ok
  end
end
