# frozen_string_literal: true

RSpec.describe Axn::Result, "pattern matching support" do
  describe "#deconstruct_keys" do
    context "with successful result" do
      subject(:result) { Axn::Result.ok("Operation completed", user_id: 123, data: { name: "Alice" }) }

      it "returns core attributes" do
        attrs = result.deconstruct_keys(nil)

        expect(attrs[:ok]).to be true
        expect(attrs[:success]).to eq("Operation completed")
        expect(attrs[:error]).to be_nil
        expect(attrs[:message]).to eq("Operation completed")
        expect(attrs[:outcome]).to eq(:success)
        expect(attrs[:finalized]).to be true
      end

      it "includes exposed data" do
        attrs = result.deconstruct_keys(nil)

        expect(attrs[:user_id]).to eq(123)
        expect(attrs[:data]).to eq({ name: "Alice" })
      end

      it "filters by requested keys" do
        attrs = result.deconstruct_keys(%i[ok success user_id])

        expect(attrs.keys).to match_array(%i[ok success user_id])
        expect(attrs[:ok]).to be true
        expect(attrs[:success]).to eq("Operation completed")
        expect(attrs[:user_id]).to eq(123)
      end
    end

    context "with failed result" do
      subject(:result) { Axn::Result.error("Something went wrong", error_code: 500) }

      it "returns core attributes" do
        attrs = result.deconstruct_keys(nil)

        expect(attrs[:ok]).to be false
        expect(attrs[:success]).to be_nil
        expect(attrs[:error]).to eq("Something went wrong")
        expect(attrs[:message]).to eq("Something went wrong")
        expect(attrs[:outcome]).to eq(:failure)
        expect(attrs[:finalized]).to be true
      end

      it "includes exposed data" do
        attrs = result.deconstruct_keys(nil)

        expect(attrs[:error_code]).to eq(500)
      end
    end

    context "with exception result" do
      subject(:result) do
        Axn::Result.error("Default message") do
          raise StandardError, "Something bad happened"
        end
      end

      it "returns exception outcome" do
        attrs = result.deconstruct_keys(nil)

        expect(attrs[:ok]).to be false
        expect(attrs[:outcome]).to eq(:exception)
        expect(attrs[:error]).to eq("Default message")
      end
    end
  end

  describe "pattern matching usage" do
    context "with successful result" do
      let(:action_result) { Axn::Result.ok("User created", user: { id: 1, name: "Alice" }, order_count: 5) }

      it "matches success pattern" do
        case action_result
        in ok: true, success: String => message, user: { id: Integer => id, name: String => name }, order_count: Integer => count
          expect(message).to eq("User created")
          expect(id).to eq(1)
          expect(name).to eq("Alice")
          expect(count).to eq(5)
        else
          raise "Expected success pattern to match"
        end
      end

      it "matches with outcome check" do
        case action_result
        in ok: true, outcome: :success, user: { name: String => name }
          expect(name).to eq("Alice")
        else
          raise "Expected success outcome pattern to match"
        end
      end
    end

    context "with failed result" do
      let(:action_result) { Axn::Result.error("Validation failed", field: "email", code: "invalid_format") }

      it "matches failure pattern" do
        case action_result
        in ok: false, error: String => message, field: String => field, code: String => code
          expect(message).to eq("Validation failed")
          expect(field).to eq("email")
          expect(code).to eq("invalid_format")
        else
          raise "Expected failure pattern to match"
        end
      end

      it "matches with outcome check" do
        case action_result
        in ok: false, outcome: :failure, error: String => message
          expect(message).to eq("Validation failed")
        else
          raise "Expected failure outcome pattern to match"
        end
      end
    end

    context "with exception result" do
      let(:action_result) do
        Axn::Result.error("Database error") do
          raise StandardError, "Connection timeout"
        end
      end

      it "matches exception pattern" do
        case action_result
        in ok: false, outcome: :exception, error: String => message
          expect(message).to eq("Database error")
        else
          raise "Expected exception pattern to match"
        end
      end
    end

    context "with complex nested data" do
      let(:action_result) do
        Axn::Result.ok(
          "Order processed",
          order: { id: 123, items: [{ name: "Widget", price: 19.99 }] },
          user: { id: 456, email: "user@example.com" },
        )
      end

      it "matches nested patterns" do
        case action_result
        in ok: true, order: { id: Integer => order_id, items: [{ name: String => item_name, price: Float => price }] }, user: { email: String => email }
          expect(order_id).to eq(123)
          expect(item_name).to eq("Widget")
          expect(price).to eq(19.99)
          expect(email).to eq("user@example.com")
        else
          raise "Expected nested pattern to match"
        end
      end
    end
  end
end
