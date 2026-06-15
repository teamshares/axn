# frozen_string_literal: true

# Rails-integration coverage for `use :model` against the dummy app's *real* models —
# the paths the non-Rails `spec/` suite (in-memory sqlite + stub_const) structurally can't
# reach: resolving a record by `_id` through the `model: true` contract, autoloaded constant
# derivation (`as: :user → User`), and a raised RecordInvalid on a *different* real record.
RSpec.describe "use :model strategy (Rails integration)" do
  before(:all) do
    Rails.application.initialize! unless Rails.application.initialized?
  end

  before { allow(Axn.config).to receive(:on_exception) }
  before do
    Profile.delete_all
    User.delete_all
  end

  describe "upsert mode (as: :user) resolving the record via the model: true contract" do
    let(:action) do
      build_axn do
        use :model, as: :user

        def model_params = { name: params[:name] }
      end
    end

    it "finds and updates an existing record from a *_id* (not the record itself)" do
      existing = User.create!(name: "Old")

      result = action.call(user_id: existing.id, params: { name: "New" })

      expect(result).to be_ok
      expect(result.success).to eq("Updated User")
      expect(result.user).to eq(existing)
      expect(existing.reload.name).to eq("New")
    end

    it "builds a fresh record (autoloaded User constant) when neither record nor id is supplied" do
      result = action.call(params: { name: "Fresh" })

      expect(result).to be_ok
      expect(result.success).to eq("Created User")
      expect(result.user).to be_persisted
      expect(User.count).to eq(1)
    end
  end

  describe "create mode deriving the autoloaded class from as:" do
    let(:action) do
      build_axn do
        use :model, create: User, as: :user

        def model_params = { name: params[:name] }
      end
    end

    it "persists through the real model and i18n-derived success message" do
      result = action.call(params: { name: "Sprocket" })

      expect(result).to be_ok
      expect(result.user).to be_persisted
      expect(result.success).to eq("Created User")
    end

    it "settles a real validation failure as a failure with no global report" do
      result = action.call(params: { name: "" })

      expect(result.outcome).to be_failure
      expect(result.error).to eq("Name can't be blank")
      expect(Axn.config).not_to have_received(:on_exception)
    end
  end

  describe "safety net for a RecordInvalid raised on a DIFFERENT real record (post-save)" do
    let(:action) do
      build_axn do
        use :model, update: :user

        def model_params = { name: "Valid" }
        # post-save work that raises RecordInvalid on a *different* record (the Profile)
        def call = Profile.create!(user:, nickname: "")
      end
    end

    it "reclassifies the raised RecordInvalid and uses the raised record's clean message" do
      existing = User.create!(name: "Old")

      result = action.call(user: existing, params: {})

      expect(result.outcome).to be_failure
      expect(result.error).to eq("Nickname can't be blank")
      expect(Axn.config).not_to have_received(:on_exception)
    end
  end

  describe "association autosave validation failure on the gated save" do
    let(:action) do
      build_axn do
        use :model, update: :user

        # A nested (autosaved) child that fails validation — the non-bang gated `save`
        # returns false rather than raising, so this is the gated-save failure path.
        def model_params = { name: "Valid", profiles_attributes: [{ nickname: "" }] }
      end
    end

    it "settles as a failure (autosave invalidates the parent save) without a global report" do
      existing = User.create!(name: "Old")

      result = action.call(user: existing, params: {})

      expect(result.outcome).to be_failure
      expect(Axn.config).not_to have_received(:on_exception)
      expect(Profile.count).to eq(0)
    end
  end
end
