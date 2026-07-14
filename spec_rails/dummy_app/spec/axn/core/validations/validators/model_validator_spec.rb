# frozen_string_literal: true

RSpec.describe Axn::Validators::ModelValidator do
  before(:all) do
    Rails.application.initialize! unless Rails.application.initialized?
    expect(Rails.env).to eq("test")

    unless ActiveRecord::Base.connection.table_exists?(:users)
      ActiveRecord::Base.connection.create_table :users do |t|
        t.string :name, null: false
        t.timestamps
      end
    end
  end

  let(:user) { User.create!(name: "Test User") }

  describe "basic model validation" do
    let(:action) do
      build_axn do
        expects :user, model: { klass: User }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end
    end

    it "accepts user object directly" do
      result = action.call(user:)
      expect(result).to be_ok
      expect(result.the_user).to eq(user)
    end

    it "finds user by ID when user_id provided" do
      result = action.call(user_id: user.id)
      expect(result).to be_ok
      expect(result.the_user).to eq(user)
    end

    it "uses the record when a record and a matching user_id are both provided" do
      result = action.call(user:, user_id: user.id)
      expect(result).to be_ok
      expect(result.the_user).to eq(user)
    end

    it "raises InboundValidationError when the record and user_id disagree" do
      other_user = User.create!(name: "Other User")
      result = action.call(user:, user_id: other_user.id)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end

    it "validates user object type" do
      result = action.call(user: "not a user")
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to include("is not a User")
    end

    it "fails when user not found by ID" do
      result = action.call(user_id: 99_999)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end

    it "fails when neither user nor user_id provided" do
      result = action.call
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end
  end

  describe "nil/blank handling" do
    context "with allow_nil" do
      let(:action) do
        build_axn do
          expects :user, model: { klass: User }, allow_nil: true
        end
      end

      it "allows nil user" do
        expect(action.call).to be_ok
      end

      it "allows nil user_id" do
        expect(action.call(user_id: nil)).to be_ok
      end
    end

    context "with allow_blank" do
      let(:action) do
        build_axn do
          expects :user, model: { klass: User }, allow_blank: true
        end
      end

      it "allows blank user" do
        expect(action.call).to be_ok
      end

      it "allows blank user_id" do
        expect(action.call(user_id: nil)).to be_ok
      end
    end
  end

  describe "custom finder methods" do
    it "uses custom finder method" do
      action = build_axn do
        expects :user, model: { klass: User, finder: :find }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end

      result = action.call(user_id: user.id)
      expect(result).to be_ok
      expect(result.the_user).to eq(user)
    end

    it "works with external API service using Method object" do
      api_service = Class.new do
        def self.find_by_id(id)
          return User.new(id:, name: "API User") if id == 123

          nil
        end
      end

      action = build_axn do
        expects :user, model: { klass: User, finder: api_service.method(:find_by_id) }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end

      result = action.call(user_id: 123)
      expect(result).to be_ok
      expect(result.the_user.id).to eq(123)
      expect(result.the_user.name).to eq("API User")
    end

    it "handles finder exceptions gracefully" do
      error_service = Class.new do
        def self.find_by_id(_id)
          raise ArgumentError, "Database connection failed"
        end
      end

      action = build_axn do
        expects :user, model: { klass: error_service, finder: :find_by_id }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end

      allow(Axn::Internal::PipingError).to receive(:swallow).and_call_original

      result = action.call(user_id: 123)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(Axn::Internal::PipingError).to have_received(:swallow).with(
        "finding user with find_by_id",
        exception: an_instance_of(ArgumentError),
      ).at_least(:once)
    end
  end

  describe "syntactic sugar" do
    it "defaults klass to field.classify when not provided" do
      action = build_axn do
        expects :user, model: { finder: :find }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end

      allow(User).to receive(:find).with(1).and_return(User.new(id: 1, name: "Test User"))

      result = action.call(user_id: 1)
      expect(result).to be_ok
      expect(result.the_user).to be_a(User)
    end

    it "constantizes string klass names" do
      action = build_axn do
        expects :user, model: { klass: "User", finder: :find }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end

      allow(User).to receive(:find).with(1).and_return(User.new(id: 1, name: "Test User"))

      result = action.call(user_id: 1)
      expect(result).to be_ok
      expect(result.the_user).to be_a(User)
    end

    it "handles model: true syntax" do
      action = build_axn do
        expects :user, model: true
        exposes :user_name

        def call
          expose :user_name, user.name
        end
      end

      allow(User).to receive(:find).with(1).and_return(User.new(id: 1, name: "Test User"))

      result = action.call(user_id: 1)
      expect(result).to be_ok
      expect(result.user_name).to eq("Test User")
    end
  end

  describe "error handling and logging" do
    it "logs exceptions during model resolution" do
      action = build_axn do
        expects :user, model: { klass: User }
      end

      allow(User).to receive(:find).and_raise(ArgumentError, "Database error")
      allow(Axn::Internal::PipingError).to receive(:swallow).and_call_original

      result = action.call(user_id: 1)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(Axn::Internal::PipingError).to have_received(:swallow).with(
        "finding user with find",
        exception: an_instance_of(ArgumentError),
      ).at_least(:once)
    end
  end

  describe "model validation as subfields" do
    let(:user) { User.create!(name: "Test User") }

    it "validates model fields within nested data structures" do
      action = build_axn do
        expects :data
        expects :user, model: { klass: User }, on: :data
        exposes :the_user

        def call
          expose :the_user, user
        end
      end

      # Test with user object directly in nested data
      result = action.call(data: { user: })
      expect(result).to be_ok
      expect(result.the_user).to eq(user)
    end

    it "finds user by ID when user_id provided in nested data" do
      action = build_axn do
        expects :data
        expects :user, model: { klass: User }, on: :data
        exposes :the_user

        def call
          expose :the_user, user
        end
      end

      result = action.call(data: { user_id: user.id })
      expect(result).to be_ok
      expect(result.the_user).to eq(user)
    end

    context "with an aliased reader (as:)" do
      it "resolves the model under the alias when the object is provided directly" do
        action = build_axn do
          expects :data
          expects :user, model: { klass: User }, on: :data, as: :event_user
          exposes :the_user

          def call = expose(:the_user, event_user)
        end

        result = action.call(data: { user: })
        expect(result).to be_ok
        expect(result.the_user).to eq(user)
      end

      it "resolves the model under the alias from the wire-key _id" do
        action = build_axn do
          expects :data
          expects :user, model: { klass: User }, on: :data, as: :event_user
          exposes :the_user

          def call = expose(:the_user, event_user)
        end

        result = action.call(data: { user_id: user.id })
        expect(result).to be_ok
        expect(result.the_user).to eq(user)
      end

      it "fails validation (under the wire key) when the aliased model can't be resolved" do
        action = build_axn do
          expects :data
          expects :user, model: { klass: User }, on: :data, as: :event_user
        end

        result = action.call(data: { user_id: 99_999 })
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::InboundValidationError)
      end
    end

    it "raises InboundValidationError when the nested record and user_id disagree" do
      other_user = User.create!(name: "Other User")
      action = build_axn do
        expects :data
        expects :user, model: { klass: User }, on: :data
        exposes :the_user

        def call
          expose :the_user, user
        end
      end

      result = action.call(data: { user:, user_id: other_user.id })
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end

    it "validates user object type in nested data" do
      action = build_axn do
        expects :data
        expects :user, model: { klass: User }, on: :data
      end

      result = action.call(data: { user: "not a user" })
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to include("is not a User")
    end

    it "fails when user not found by ID in nested data" do
      action = build_axn do
        expects :data
        expects :user, model: { klass: User }, on: :data
      end

      result = action.call(data: { user_id: 99_999 })
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end

    it "fails when neither user nor user_id provided in nested data" do
      action = build_axn do
        expects :data
        expects :user, model: { klass: User }, on: :data
      end

      result = action.call(data: {})
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end

    it "works with allow_nil for nested model fields" do
      action = build_axn do
        expects :data
        expects :user, model: { klass: User }, on: :data, allow_nil: true
        exposes :user_name, allow_nil: true

        def call
          expose :user_name, user&.name
        end
      end

      result = action.call(data: { some_field: "value" })
      expect(result).to be_ok
      expect(result.user_name).to be_nil
    end

    it "resolves an optional nested model to nil when the parent is nil (no blow-up on a nil parent)" do
      # A `model:` subfield hanging off a nil/absent parent is treated as absent (PRO-2857): the model
      # resolves to nil rather than reaching into nil for the record/id.
      action = build_axn do
        expects :data, optional: true
        expects :user, model: { klass: User }, on: :data, optional: true
        exposes :user_name, allow_nil: true

        def call = expose(:user_name, user&.name)
      end

      result = action.call(data: nil)
      expect(result).to be_ok
      expect(result.user_name).to be_nil
    end

    it "rejects the contract at declaration: an optional parent can never rescue a required nested model (PRO-2889)" do
      # No contract-valid input ever satisfies a required :user under a nil-tolerant :data (every
      # nil/omitted :data fails validation before :user is even reached), so the tolerance on :data
      # is dead machinery — Axn::Reflection::SubfieldContradictions rejects it at declaration.
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, model: { klass: User }, on: :data
        end
      end.to raise_error(ArgumentError, /:data is declared nil-tolerant/)
    end

    it "handles model: true syntax for nested fields" do
      action = build_axn do
        expects :data
        expects :user, model: true, on: :data
        exposes :user_name

        def call
          expose :user_name, user.name
        end
      end

      allow(User).to receive(:find).with(user.id).and_return(user)

      result = action.call(data: { user_id: user.id })
      expect(result).to be_ok
      expect(result.user_name).to eq("Test User")
    end
  end
end
