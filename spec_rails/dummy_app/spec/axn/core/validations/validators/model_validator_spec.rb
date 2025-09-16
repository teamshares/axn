# frozen_string_literal: true

RSpec.describe Axn::Validators::ModelValidator do
  before(:all) do
    # Ensure Rails is fully initialized
    Rails.application.initialize! unless Rails.application.initialized?

    # Verify we're in test mode
    expect(Rails.env).to eq("test")
    expect(ActiveRecord::Base.connection_db_config.database).to eq(":memory:")

    # Create the users table if it doesn't exist
    unless ActiveRecord::Base.connection.table_exists?(:users)
      ActiveRecord::Base.connection.create_table :users do |t|
        t.string :name, null: false
        t.timestamps
      end
    end
  end

  describe "flexible model validation" do
    let(:action) do
      build_axn do
        expects :user, model: { with: User }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end
    end

    context "when user object is provided directly" do
      let(:user_object) { User.create!(name: "Test User") }

      it "accepts the user object" do
        result = action.call(user: user_object)
        expect(result).to be_ok
        expect(result.the_user).to eq(user_object)
      end

      it "validates the user object type" do
        result = action.call(user: "not a user")
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::InboundValidationError)
        expect(result.exception.message).to include("is not a User")
      end
    end

    context "when user_id is provided instead" do
      let!(:user) { User.create!(name: "Test User") }

      it "finds user by ID" do
        result = action.call(user_id: user.id)
        expect(result).to be_ok
        expect(result.the_user).to eq(user)
      end

      it "fails when user not found by ID" do
        result = action.call(user_id: 99_999)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::InboundValidationError)
        expect(result.exception.message).to include("is not a User")
      end

      it "fails when user_id is blank" do
        result = action.call(user_id: nil)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::InboundValidationError)
        expect(result.exception.message).to include("is not a User")
      end
    end

    context "when both user and user_id are provided" do
      let!(:user_by_id) { User.create!(name: "User by ID") }
      let(:user_direct) { User.create!(name: "User Direct") }

      it "prefers the user object over user_id" do
        result = action.call(user: user_direct, user_id: user_by_id.id)
        expect(result).to be_ok
        expect(result.the_user).to eq(user_direct)
      end
    end

    context "when neither user nor user_id is provided" do
      it "fails validation" do
        result = action.call
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::InboundValidationError)
        expect(result.exception.message).to include("is not a User")
      end
    end

    context "with allow_nil" do
      let(:action) do
        build_axn do
          expects :user, model: { with: User }, allow_nil: true
        end
      end

      it "allows nil user" do
        result = action.call
        expect(result).to be_ok
      end

      it "allows nil user_id" do
        result = action.call(user_id: nil)
        expect(result).to be_ok
      end
    end

    context "with allow_blank" do
      let(:action) do
        build_axn do
          expects :user, model: { with: User }, allow_blank: true
        end
      end

      it "allows blank user" do
        result = action.call
        expect(result).to be_ok
      end

      it "allows blank user_id" do
        result = action.call(user_id: nil)
        expect(result).to be_ok
      end
    end
  end

  describe "Axn::Internal::Logging.piping_error integration for model validation" do
    let(:action) do
      build_axn do
        expects :user, model: { with: User }
      end
    end

    before do
      allow(User).to receive(:find_by).and_raise(ArgumentError, "fail model validation")
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
    end

    it "calls Axn::Internal::Logging.piping_error when model validation raises" do
      result = action.call(user_id: 1)
      expect(result.exception).to be_a(ArgumentError)
      expect(result.exception.message).to include("fail model validation")
    end
  end
end
