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
        expects :user, model: { klass: User }
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
          expects :user, model: { klass: User }, allow_nil: true
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
          expects :user, model: { klass: User }, allow_blank: true
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

  describe "custom finder methods" do
    let(:action) do
      build_axn do
        expects :user, model: { klass: User, finder: :find }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end
    end

    context "when user_id is provided" do
      let!(:user) { User.create!(name: "Test User") }

      it "finds user using custom finder method" do
        result = action.call(user_id: user.id)
        expect(result).to be_ok
        expect(result.the_user).to eq(user)
      end

      it "fails when user not found" do
        result = action.call(user_id: 99_999)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::InboundValidationError)
        expect(result.exception.message).to include("is not a User")
      end
    end

    context "with external API service" do
      let(:api_service) do
        Class.new do
          def self.find_by_id(id)
            return User.new(id:, name: "API User") if id == 123

            nil
          end
        end
      end

      let(:action) do
        api_service_class = api_service
        build_axn do
          expects :user, model: { klass: User, finder: api_service_class.method(:find_by_id) }
          exposes :the_user

          def call
            expose :the_user, user
          end
        end
      end

      it "finds user using external API service" do
        result = action.call(user_id: 123)
        expect(result).to be_ok
        expect(result.the_user.id).to eq(123)
        expect(result.the_user.name).to eq("API User")
      end

      it "fails when API service returns nil" do
        result = action.call(user_id: 999)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::InboundValidationError)
      end
    end

    context "with finder that raises exception" do
      let(:error_service) do
        Class.new do
          def self.find_by_id(_id)
            raise ArgumentError, "Database connection failed"
          end
        end
      end

      let(:action) do
        error_service_class = error_service
        build_axn do
          expects :user, model: { klass: error_service_class, finder: :find_by_id }
          exposes :the_user

          def call
            expose :the_user, user
          end
        end
      end

      before do
        allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
      end

      it "logs the exception and fails validation" do
        result = action.call(user_id: 123)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::InboundValidationError)
        expect(Axn::Internal::Logging).to have_received(:piping_error).with(
          "finding user with find_by_id",
          exception: an_instance_of(ArgumentError),
        ).at_least(:once)
      end
    end
  end

  describe "Axn::Internal::Logging.piping_error integration for model validation" do
    let(:action) do
      build_axn do
        expects :user, model: { klass: User }
      end
    end

    before do
      allow(User).to receive(:find).and_raise(ArgumentError, "fail model validation")
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
    end

    it "calls Axn::Internal::Logging.piping_error when model validation raises" do
      result = action.call(user_id: 1)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(Axn::Internal::Logging).to have_received(:piping_error).with(
        "finding user with find",
        exception: an_instance_of(ArgumentError),
      ).at_least(:once)
    end
  end

  describe "field-based klass defaulting" do
    let(:action) do
      build_axn do
        expects :user, model: { finder: :find }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end
    end

    it "defaults klass to field.classify when not provided" do
      allow(User).to receive(:find).with(1).and_return(User.new(id: 1, name: "Test User"))

      result = action.call(user_id: 1)
      expect(result).to be_ok
      expect(result.the_user).to be_a(User)
    end
  end

  describe "string klass constantization" do
    let(:action) do
      build_axn do
        expects :user, model: { klass: "User", finder: :find }
        exposes :the_user

        def call
          expose :the_user, user
        end
      end
    end

    it "constantizes string klass names" do
      allow(User).to receive(:find).with(1).and_return(User.new(id: 1, name: "Test User"))

      result = action.call(user_id: 1)
      expect(result).to be_ok
      expect(result.the_user).to be_a(User)
    end
  end
end
