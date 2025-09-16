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

    it "prefers user object over user_id when both provided" do
      other_user = User.create!(name: "Other User")
      result = action.call(user:, user_id: other_user.id)
      expect(result).to be_ok
      expect(result.the_user).to eq(user)
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

      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original

      result = action.call(user_id: 123)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(Axn::Internal::Logging).to have_received(:piping_error).with(
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
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original

      result = action.call(user_id: 1)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(Axn::Internal::Logging).to have_received(:piping_error).with(
        "finding user with find",
        exception: an_instance_of(ArgumentError),
      ).at_least(:once)
    end
  end
end
