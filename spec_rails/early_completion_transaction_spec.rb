# frozen_string_literal: true

RSpec.describe Axn do
  before(:all) do
    # Run migrations to set up the database
    ActiveRecord::Base.connection.execute(
      "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name VARCHAR(255) NOT NULL, created_at DATETIME, updated_at DATETIME)",
    )
  end

  after(:all) do
    # Clean up the database
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS users")
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
