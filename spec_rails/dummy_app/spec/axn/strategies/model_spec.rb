# frozen_string_literal: true

# Full behavioral coverage for `use :model`. The strategy is built on ActiveRecord persistence
# (`save`, `previously_new_record?`, the `model: true` `.find` resolver, `ActiveRecord::RecordInvalid`),
# so it lives here in the Rails suite where AR + the real dummy-app models (`User`, `Profile`) are
# present. The non-Rails `spec/` suite only proves it *refuses to run* without ActiveRecord.
RSpec.describe "use :model strategy" do
  before(:all) do
    Rails.application.initialize! unless Rails.application.initialized?
  end

  before { allow(Axn.config).to receive(:on_exception) }
  before do
    Profile.delete_all
    User.delete_all
  end

  describe "create mode (create: Klass)" do
    let(:action) do
      build_axn do
        use :model, create: User, as: :user

        def model_params = { name: params[:name] }
      end
    end

    it "builds and persists a new record from model_params" do
      result = action.call(params: { name: "Sprocket" })
      expect(result).to be_ok
      expect(result.user).to be_persisted
      expect(result.user.name).to eq("Sprocket")
      expect(User.count).to eq(1)
    end

    it "auto-declares expects :params (no manual declaration needed)" do
      expect { action.call }.not_to raise_error # missing params → handled, not a NoMethodError
    end

    context "when validation fails" do
      subject(:result) { action.call(params: { name: "" }) }

      it "settles as a failure, not an exception" do
        expect(result).not_to be_ok
        expect(result.outcome).to be_failure
      end

      it "does not persist" do
        result
        expect(User.count).to eq(0)
      end

      it "exposes the invalid record with errors populated (for re-rendering)" do
        expect(result.user.errors[:name]).to be_present
      end

      it "skips the global on_exception report" do
        result
        expect(Axn.config).not_to have_received(:on_exception)
      end

      it "produces a validation error message" do
        expect(result.error).to eq("Name can't be blank")
      end
    end

    it "sets a mode-aware success message (i18n-derived model name)" do
      expect(action.call(params: { name: "Sprocket" }).success).to eq("Created User")
    end
  end

  describe "default model_params" do
    let(:action) do
      build_axn do
        use :model, create: User, as: :user
      end
    end

    it "defaults to the full params hash" do
      result = action.call(params: { name: "Default" })
      expect(result).to be_ok
      expect(result.user.name).to eq("Default")
    end
  end

  describe "update mode (update: :user)" do
    let(:action) do
      build_axn do
        use :model, update: :user

        def model_params = { name: params[:name] }
      end
    end
    let(:existing) { User.create!(name: "Old") }

    it "updates the passed-in record" do
      result = action.call(user: existing, params: { name: "New" })
      expect(result).to be_ok
      expect(result.user.name).to eq("New")
      expect(existing.reload.name).to eq("New")
    end

    it "uses an Updated success message" do
      expect(action.call(user: existing, params: { name: "New" }).success).to eq("Updated User")
    end

    it "requires the record (inbound validation fails when absent)" do
      expect(action.call(params: { name: "New" })).not_to be_ok
    end
  end

  describe "upsert mode (as: :user)" do
    let(:action) do
      build_axn do
        use :model, as: :user

        def model_params = { name: params[:name] }
      end
    end

    it "creates an autoloaded-constant record when none is provided" do
      result = action.call(params: { name: "Fresh" })
      expect(result).to be_ok
      expect(result.user).to be_persisted
      expect(result.success).to eq("Created User")
    end

    it "updates when a record is provided directly" do
      existing = User.create!(name: "Old")
      result = action.call(user: existing, params: { name: "New" })
      expect(result.user.name).to eq("New")
      expect(result.success).to eq("Updated User")
    end

    it "finds and updates an existing record from a *_id* (via the model: true contract)" do
      existing = User.create!(name: "Old")
      result = action.call(user_id: existing.id, params: { name: "New" })
      expect(result).to be_ok
      expect(result.success).to eq("Updated User")
      expect(result.user).to eq(existing)
      expect(existing.reload.name).to eq("New")
    end

    it "surfaces a supplied-but-unresolvable *_id* instead of silently creating a second record" do
      result = action.call(user_id: 999_999, params: { name: "New" })
      expect(result).not_to be_ok
      expect(result.exception).to be_a(ArgumentError)
      expect(result.exception.message).to include("could not be resolved")
      expect(User.count).to eq(0) # did NOT build a new record
    end
  end

  describe "as: is optional (defaults to result.model)" do
    let(:action) do
      build_axn do
        use :model, create: User

        def model_params = { name: params[:name] }
      end
    end

    it "exposes the record as result.model" do
      result = action.call(params: { name: "X" })
      expect(result.model).to be_persisted
      expect(result.model.name).to eq("X")
    end
  end

  describe "inject:" do
    let(:action) do
      build_axn do
        use :model, create: User, as: :user, inject: [:email]

        def model_params = { name: params[:name] }
        def email = "premium@example.com"
      end
    end

    it "merges injected context fields into model_params" do
      expect(action.call(params: { name: "X" }).user.email).to eq("premium@example.com")
    end

    it "lets an explicit model_params key win over an injected one on collision" do
      action = build_axn do
        use :model, create: User, as: :user, inject: [:email]

        def model_params = { name: "X", email: "from_params@example.com" }
        def email = "from_inject@example.com"
      end
      expect(action.call(params: {}).user.email).to eq("from_params@example.com")
    end
  end

  describe "respecting a pre-declared model field" do
    let(:action) do
      build_axn do
        expects :user, model: true
        use :model, update: :user

        def model_params = { name: params[:name] }
      end
    end

    it "works without conflicting on the duplicate declaration" do
      existing = User.create!(name: "Old")
      expect(action.call(user: existing, params: { name: "New" })).to be_ok
    end

    it "raises if the model field is re-declared AFTER use :model (declare custom options before)" do
      expect do
        build_axn do
          use :model, update: :user
          expects :user, model: true
        end
      end.to raise_error(Axn::DuplicateFieldError, /user/)
    end
  end

  describe "strong parameters" do
    let(:action) do
      build_axn do
        use :model, create: User, as: :user
      end
    end

    it "accepts permitted ActionController::Parameters" do
      permitted = ActionController::Parameters.new(name: "Permitted").permit(:name)
      result = action.call(params: permitted)
      expect(result).to be_ok
      expect(result.user.name).to eq("Permitted")
    end

    it "raises an actionable error for unpermitted ActionController::Parameters (rather than a cryptic UnfilteredParameters)" do
      unpermitted = ActionController::Parameters.new(name: "Nope")
      result = action.call(params: unpermitted)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(ArgumentError)
      # Assert on our specific guidance — `UnfilteredParameters` is itself an ArgumentError whose
      # message also says "unpermitted parameters", so we must match the actionable wording.
      expect(result.exception.message).to include("use :model").and include("override `model_params`")
    end
  end

  describe "message resolution for an unrelated failure" do
    it "does not build the model (no model_params side effects) when the failure is unrelated" do
      calls = []
      action = build_axn do
        before { raise "boom before the model is built" }
        use :model, create: User, as: :user

        define_method(:model_params) do
          calls << :called
          { name: "X" }
        end
      end

      result = action.call(params: {})
      expect(result.outcome).to be_exception
      result.error # force message resolution (where the error matcher runs)

      # The matcher must not construct the record during message resolution.
      expect(calls).to be_empty
    end
  end

  describe "message overrides" do
    it "prepends error_prefix to the validation message" do
      action = build_axn do
        use :model, create: User, as: :user, error_prefix: "Couldn't save: "
        def model_params = { name: "" }
      end
      expect(action.call(params: {}).error).to eq("Couldn't save: Name can't be blank")
    end

    it "honors a success declared after use :model (later declarations win)" do
      action = build_axn do
        use :model, create: User, as: :user
        success "Done!"

        def model_params = { name: "X" }
      end
      expect(action.call(params: {}).success).to eq("Done!")
    end

    it "honors an error declared after use :model (later declarations win)" do
      action = build_axn do
        use :model, create: User, as: :user
        error "Could not save the user"

        def model_params = { name: "" }
      end
      expect(action.call(params: {}).error).to eq("Could not save the user")
    end
  end

  describe "safety net for a raised RecordInvalid" do
    let(:action) do
      build_axn do
        use :model, update: :user

        def model_params = {}
        # raises ActiveRecord::RecordInvalid
        def call = user.update!(name: "")
      end
    end

    it "reclassifies the raised RecordInvalid as a failure with no global report" do
      existing = User.create!(name: "Old")
      result = action.call(user: existing, params: {})
      expect(result.outcome).to be_failure
      expect(Axn.config).not_to have_received(:on_exception)
    end
  end

  describe "safety-net message for a RecordInvalid raised on a DIFFERENT real record (post-save)" do
    let(:action) do
      build_axn do
        use :model, update: :user

        def model_params = { name: "Valid" }
        # post-save work that raises RecordInvalid on a *different* record (the Profile)
        def call = Profile.create!(user:, nickname: "")
      end
    end

    it "uses the raised record's clean validation message (not the raw exception.message)" do
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

  describe "expect: custom params key" do
    let(:action) do
      build_axn do
        use :model, create: User, as: :user, expect: :user_params
      end
    end

    it "reads the default model_params from the named field instead of :params" do
      result = action.call(user_params: { name: "Custom" })
      expect(result).to be_ok
      expect(result.user.name).to eq("Custom")
    end
  end

  describe "persist: override" do
    it "persist: :update makes the (otherwise-optional) upsert field required" do
      action = build_axn do
        use :model, as: :user, persist: :update

        def model_params = { name: params[:name] }
      end

      # upsert would build a fresh record; forcing :update requires the field be supplied
      expect(action.call(params: { name: "X" })).not_to be_ok
    end

    it "persist: :create forces a fresh insert even when a record is in context (does not update it)" do
      existing = User.create!(name: "Old")
      action = build_axn do
        use :model, as: :user, persist: :create

        def model_params = { name: params[:name] }
      end

      result = action.call(user: existing, params: { name: "New" })
      expect(result).to be_ok
      expect(User.count).to eq(2)                  # a NEW row was inserted
      expect(existing.reload.name).to eq("Old")    # provided record left untouched
      expect(result.success).to eq("Created User")
      expect(result.user).to be_persisted
      expect(result.user.id).not_to eq(existing.id) # exposed record is the freshly-built one
    end
  end

  describe "prepare_model (imperative pre-save hook)" do
    it "runs after attribute assignment and before the save, mutating the record" do
      action = build_axn do
        use :model, create: User, as: :user

        def model_params = { name: params[:name] }

        # derive a field imperatively from the assigned attributes (the kind of tweak that
        # doesn't fit a flat model_params hash)
        def prepare_model(user)
          user.email = "#{user.name.parameterize}@example.com"
        end
      end

      result = action.call(params: { name: "Ada Lovelace" })
      expect(result).to be_ok
      expect(result.user.email).to eq("ada-lovelace@example.com")
      expect(result.user).to be_persisted
    end

    it "can fix up a record so an otherwise-invalid save succeeds (proving it runs before save)" do
      action = build_axn do
        use :model, create: User, as: :user

        # invalid as-assigned; prepare_model fixes it up before the save
        def model_params = { name: "" }
        def prepare_model(user) = user.name = "Backfilled"
      end

      result = action.call(params: {})
      expect(result).to be_ok
      expect(result.user.name).to eq("Backfilled")
    end
  end

  describe "composing with use :transaction" do
    let(:action) do
      build_axn do
        use :model, create: User, as: :user
        use :transaction

        def model_params = { name: params[:name] }
        def call = fail!("post-save boom")
      end
    end

    it "rolls back the persisted record when post-save call fails" do
      result = action.call(params: { name: "Sprocket" })
      expect(result).not_to be_ok
      expect(result.error).to eq("post-save boom")
      expect(User.count).to eq(0)
    end
  end
end
