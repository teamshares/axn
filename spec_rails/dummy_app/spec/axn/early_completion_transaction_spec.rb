# frozen_string_literal: true

RSpec.describe Axn do
  before(:all) do
    if defined?(Rails)
      Rails.application.initialize! unless Rails.application.initialized?
      expect(Rails.env).to eq("test")
    end
  end

  describe "#done! with transaction strategy" do
    context "when done! is called" do
      let(:action) do
        build_axn do
          use :transaction

          def call
            User.create!(name: "Test User")
            done!("Early completion")
          end
        end
      end

      it "commits the transaction and persists the database changes" do
        expect { action.call }.to change(User, :count).by(1)
        expect(User.last.name).to eq("Test User")
      end
    end

    context "when done! is called in before hook" do
      let(:action) do
        build_axn do
          use :transaction
          before do
            User.create!(name: "Before Hook User")
            done!("Early completion in before")
          end

          def call
            # This should not be executed
            User.create!(name: "Call Method User")
          end
        end
      end

      it "commits the transaction and persists the database changes" do
        expect { action.call }.to change(User, :count).by(1)
        expect(User.last.name).to eq("Before Hook User")
        expect(User.where(name: "Call Method User")).to be_empty
      end
    end

    context "when done! is called in after hook" do
      let(:action) do
        build_axn do
          use :transaction
          after do
            User.create!(name: "After Hook User")
            done!("Early completion in after")
          end

          def call
            User.create!(name: "Call Method User")
          end
        end
      end

      it "commits the transaction and persists the database changes" do
        expect { action.call }.to change(User, :count).by(2)
        expect(User.where(name: "Call Method User")).to exist
        expect(User.where(name: "After Hook User")).to exist
      end
    end

    context "when done! is called - explicit transaction commit verification" do
      let(:action) do
        build_axn do
          use :transaction

          def call
            User.create!(name: "Transaction Test User")
            done!("Early completion")
            # This should not execute, but if it did, the transaction should still commit
            User.create!(name: "After Done User")
          end
        end
      end

      it "does NOT rollback the transaction when done! is called" do
        initial_count = User.count
        result = action.call

        # Transaction should have committed, not rolled back
        expect(result).to be_ok
        expect(User.count).to eq(initial_count + 1)
        expect(User.find_by(name: "Transaction Test User")).to be_present
        # Verify the code after done! did not execute
        expect(User.find_by(name: "After Done User")).to be_nil
      end

      it "persists changes across transaction boundaries" do
        result = action.call
        expect(result).to be_ok

        # Verify the record persists and can be queried in a new transaction context
        user = nil
        ActiveRecord::Base.transaction do
          user = User.find_by(name: "Transaction Test User")
          expect(user).to be_present
        end

        # Verify outside any transaction
        expect(user).to be_present
        expect(user.name).to eq("Transaction Test User")
      end

      it "commits the transaction successfully even with early completion" do
        # Use a nested transaction to verify the outer transaction commits
        outer_user = nil
        ActiveRecord::Base.transaction do
          result = action.call
          expect(result).to be_ok

          # The user created inside the action's transaction should be visible
          outer_user = User.find_by(name: "Transaction Test User")
        end

        # After the outer transaction commits, the user should still exist
        expect(outer_user).to be_present
        expect(User.find_by(name: "Transaction Test User")).to be_present
      end
    end

    context "when an error occurs (for comparison)" do
      let(:action) do
        build_axn do
          use :transaction

          def call
            User.create!(name: "Error Test User")
            raise "Something went wrong"
          end
        end
      end

      it "rolls back the transaction and does not persist database changes" do
        expect do
          action.call
        rescue StandardError
          nil
        end.not_to change(User, :count)
        expect(User.where(name: "Error Test User")).to be_empty
      end
    end
  end
end
