# frozen_string_literal: true

RSpec.describe "on_success transaction-commit semantics" do
  before(:all) do
    Rails.application.initialize! if defined?(Rails) && !Rails.application.initialized?
  end

  # Inner axn: writes a row, has its own transaction + an on_success side effect.
  let(:inner) do
    build_axn do
      use :transaction
      expects :collector, allow_blank: true
      expects :name
      on_success { collector << :inner_success }

      def call
        User.create!(name:)
      end
    end
  end

  describe "top-level (no enclosing axn transaction)" do
    let(:action) do
      build_axn do
        use :transaction
        expects :collector, allow_blank: true
        on_success { collector << :success }

        def call
          User.create!(name: "Top Level User")
        end
      end
    end

    it "fires on_success after the transaction commits" do
      collector = []
      expect { action.call!(collector:) }.to change(User, :count).by(1)
      expect(collector).to eq([:success])
    end
  end

  describe "nested inside an outer transaction that rolls back" do
    let(:outer) do
      build_axn do
        use :transaction
        expects :collector, allow_blank: true
        expects :inner

        def call
          inner.call!(collector:, name: "Nested User")
          raise "force rollback"
        end
      end
    end

    it "does not fire the inner on_success (skipped on rollback)" do
      collector = []
      expect { outer.call(collector:, inner:) }.not_to change(User, :count)
      expect(collector).to be_empty
    end
  end
end
