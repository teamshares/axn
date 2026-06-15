# frozen_string_literal: true

require "active_record"
require "action_controller"

RSpec.describe "use :model strategy" do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :widgets, force: true do |t|
        t.string :name
        t.string :category
      end
    end
  end

  before do
    widget_class = Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
      validates :name, presence: true
      def self.name = "Widget"
    end
    stub_const("Widget", widget_class)
    Widget.delete_all
  end

  before { allow(Axn.config).to receive(:on_exception) }

  describe "create mode (create: Klass)" do
    let(:action) do
      build_axn do
        use :model, create: Widget, as: :widget

        def model_params = { name: params[:name] }
      end
    end

    it "builds and persists a new record from model_params" do
      result = action.call(params: { name: "Sprocket" })
      expect(result).to be_ok
      expect(result.widget).to be_persisted
      expect(result.widget.name).to eq("Sprocket")
      expect(Widget.count).to eq(1)
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
        expect(Widget.count).to eq(0)
      end

      it "exposes the invalid record with errors populated (for re-rendering)" do
        expect(result.widget.errors[:name]).to be_present
      end

      it "skips the global on_exception report" do
        result
        expect(Axn.config).not_to have_received(:on_exception)
      end

      it "produces a validation error message" do
        expect(result.error).to eq("Name can't be blank")
      end
    end

    it "sets a mode-aware success message" do
      expect(action.call(params: { name: "Sprocket" }).success).to eq("Created Widget")
    end
  end

  describe "default model_params" do
    let(:action) do
      build_axn do
        use :model, create: Widget, as: :widget
      end
    end

    it "defaults to the full params hash" do
      result = action.call(params: { name: "Default" })
      expect(result).to be_ok
      expect(result.widget.name).to eq("Default")
    end
  end

  describe "update mode (update: :widget)" do
    let(:action) do
      build_axn do
        use :model, update: :widget

        def model_params = { name: params[:name] }
      end
    end
    let(:existing) { Widget.create!(name: "Old") }

    it "updates the passed-in record" do
      result = action.call(widget: existing, params: { name: "New" })
      expect(result).to be_ok
      expect(result.widget.name).to eq("New")
      expect(existing.reload.name).to eq("New")
    end

    it "uses an Updated success message" do
      expect(action.call(widget: existing, params: { name: "New" }).success).to eq("Updated Widget")
    end

    it "requires the record (inbound validation fails when absent)" do
      expect(action.call(params: { name: "New" })).not_to be_ok
    end
  end

  describe "upsert mode (as: :widget)" do
    let(:action) do
      build_axn do
        use :model, as: :widget

        def model_params = { name: params[:name] }
      end
    end

    it "creates when no record is provided" do
      result = action.call(params: { name: "Fresh" })
      expect(result).to be_ok
      expect(result.widget).to be_persisted
      expect(result.success).to eq("Created Widget")
    end

    it "updates when a record is provided" do
      existing = Widget.create!(name: "Old")
      result = action.call(widget: existing, params: { name: "New" })
      expect(result.widget.name).to eq("New")
      expect(result.success).to eq("Updated Widget")
    end
  end

  describe "as: is optional (defaults to result.model)" do
    let(:action) do
      build_axn do
        use :model, create: Widget

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
        use :model, create: Widget, as: :widget, inject: [:category]

        def model_params = { name: params[:name] }
        def category = "premium"
      end
    end

    it "merges injected context fields into model_params" do
      expect(action.call(params: { name: "X" }).widget.category).to eq("premium")
    end

    it "lets an explicit model_params key win over an injected one on collision" do
      action = build_axn do
        use :model, create: Widget, as: :widget, inject: [:category]

        def model_params = { name: "X", category: "from_params" }
        def category = "from_inject"
      end
      expect(action.call(params: {}).widget.category).to eq("from_params")
    end
  end

  describe "respecting a pre-declared model field" do
    let(:action) do
      build_axn do
        expects :widget, model: true
        use :model, update: :widget

        def model_params = { name: params[:name] }
      end
    end

    it "works without conflicting on the duplicate declaration" do
      existing = Widget.create!(name: "Old")
      expect(action.call(widget: existing, params: { name: "New" })).to be_ok
    end

    it "raises if the model field is re-declared AFTER use :model (declare custom options before)" do
      expect do
        build_axn do
          use :model, update: :widget
          expects :widget, model: true
        end
      end.to raise_error(Axn::DuplicateFieldError, /widget/)
    end
  end

  describe "strong parameters" do
    let(:action) do
      build_axn do
        use :model, create: Widget, as: :widget
      end
    end

    it "accepts permitted ActionController::Parameters" do
      permitted = ActionController::Parameters.new(name: "Permitted").permit(:name)
      result = action.call(params: permitted)
      expect(result).to be_ok
      expect(result.widget.name).to eq("Permitted")
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
        use :model, create: Widget, as: :widget

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
        use :model, create: Widget, as: :widget, error_prefix: "Couldn't save: "
        def model_params = { name: "" }
      end
      expect(action.call(params: {}).error).to eq("Couldn't save: Name can't be blank")
    end

    it "honors a success: override" do
      action = build_axn do
        use :model, create: Widget, as: :widget, success: "Done!"
        def model_params = { name: "X" }
      end
      expect(action.call(params: {}).success).to eq("Done!")
    end
  end

  describe "safety net for a raised RecordInvalid" do
    let(:action) do
      build_axn do
        use :model, update: :widget

        def model_params = {}
        # raises ActiveRecord::RecordInvalid
        def call = widget.update!(name: "")
      end
    end

    it "reclassifies the raised RecordInvalid as a failure with no global report" do
      existing = Widget.create!(name: "Old")
      result = action.call(widget: existing, params: {})
      expect(result.outcome).to be_failure
      expect(Axn.config).not_to have_received(:on_exception)
    end
  end
end
