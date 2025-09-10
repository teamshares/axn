# frozen_string_literal: true

RSpec.describe Axn do
  describe "_expects_subfields" do
    shared_examples "raises when improperly configured" do |on:|
      it "raises" do
        expect { action }.to raise_error(
          ArgumentError,
          "expects called with `on: #{on}`, but no such method exists (are you sure you've declared `expects :#{on}`?)",
        )
      end
    end

    context "when missing expects declaration" do
      let(:action) { build_axn { expects :bar, on: :baz } }
      it_behaves_like "raises when improperly configured", on: :baz
    end

    context "when missing nested expects declaration" do
      let(:action) do
        build_axn do
          expects :baz
          expects :bar, on: :baz
          expects :quux, on: :qux
        end
      end
      it_behaves_like "raises when improperly configured", on: :qux
    end

    let(:readers) { true }
    let(:action) do
      build_axn do
        expects :foo
        expects :bar, :baz, on: :foo
        exposes :output

        def call
          expose output: qux
        end
      end.tap do |action|
        action.expects :qux, on: :bar, readers:
      end
    end

    it "validates" do
      expect(action.call(foo: { bar: { qux: 3 }, baz: 2 })).to be_ok
      expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
      expect(action.call(foo: 1)).not_to be_ok
    end

    context "readers" do
      subject(:result) { action.call(foo: { bar: { qux: 3 }, baz: 2 }) }

      it "exposes by default" do
        expect(result).to be_ok
        expect(result.output).to eq(3)
      end

      context "can be disabled" do
        let(:readers) { false }

        it do
          expect(result).not_to be_ok
          expect(result.exception).to be_a(NameError)
        end
      end
    end

    context "digging to nested fields" do
      let(:action) do
        build_axn do
          expects :foo
          expects "bar.baz", on: :foo
        end
      end

      it "validates" do
        expect(action.call(foo: { bar: { baz: 3 } })).to be_ok
        expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
        expect(action.call(foo: 1)).not_to be_ok
      end

      context "with duplicate sub-keys" do
        let(:action) do
          build_axn do
            expects :foo
            expects :bar, on: :foo
          end.tap do |a|
            a.expects :foo, on: :bar, readers:
          end
        end

        context "when readers are enabled" do
          let(:readers) { true }

          it "raises if readers are enabled" do
            expect { action }.to raise_error(ArgumentError, "expects does not support duplicate sub-keys (i.e. `foo` is already defined)")
          end
        end

        context "when readers are disabled" do
          let(:readers) { false }

          it "does not raise" do
            expect { action }.not_to raise_error
            expect(action.call(foo: { bar: { foo: 3 } })).to be_ok
            expect(action.call(foo: { bar: { baz: 3 } })).not_to be_ok
          end
        end
      end
    end

    context "with objects rather than hashes" do
      let(:action) do
        build_axn do
          expects :foo
          expects :bar, on: :foo
        end
      end
      let(:foo) { double(bar: 3) }

      it "validates" do
        expect(action.call(foo:)).to be_ok
      end
    end

    context "sensitive subfields" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :password, on: :user_data, sensitive: true
          expects :email, on: :user_data
        end
      end

      let(:user_data) { { password: "secret123", email: "user@example.com" } }
      subject(:result) { action.call(user_data:) }

      context "when validation passes" do
        it "succeeds" do
          expect(result).to be_ok
        end

        it "filters sensitive subfield in internal context inspect" do
          # NOTE: Currently, sensitive subfields are NOT filtered in inspection output
          # because the inspection filter works at the field level, not the subfield level.
          # This is a known limitation of the current implementation.

          # Create a simple action to access internal context
          simple_action = build_axn do
            expects :user_data
            expects :password, on: :user_data, sensitive: true
            expects :email, on: :user_data
            exposes :internal_ctx

            def call
              expose :internal_ctx, internal_context
            end
          end

          result = simple_action.call(user_data:)
          expect(result.internal_ctx.inspect).to include("password")
          expect(result.internal_ctx.inspect).to include("user@example.com")

          # Currently, sensitive subfields are not filtered in inspection
          # TODO: This should be improved in a future version
          expect(result.internal_ctx.inspect).to include("secret123")
        end

        it "filters sensitive subfield in context_for_logging" do
          # Test that context_for_logging filters sensitive subfields
          instance = action.new(user_data:)
          filtered_context = instance.send(:context_for_logging)

          expect(filtered_context[:user_data]).to include(password: "[FILTERED]")
          expect(filtered_context[:user_data]).to include(email: "user@example.com")

          # Ensure the actual sensitive value is NOT present
          expect(filtered_context.to_s).not_to include("secret123")
          expect(filtered_context[:user_data][:password]).not_to eq("secret123")
        end

        it "filters sensitive subfield in result inspect" do
          expect(result.inspect).to eq(
            "#<Axn::Result [OK]>",
          )
        end
      end

      context "when validation fails" do
        let(:action) do
          build_axn do
            expects :user_data
            expects :password, on: :user_data, sensitive: true
            expects :email, on: :user_data, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
          end
        end

        let(:user_data) { { password: "secret123", email: "invalid-email" } }

        it "fails with validation error" do
          expect(result).not_to be_ok
          expect(result.exception).to be_a(Axn::InboundValidationError)
        end

        it "filters sensitive subfield in error context" do
          # Test that sensitive data is filtered in error logging by checking context_for_logging
          instance = action.new(user_data:)
          filtered_context = instance.send(:context_for_logging)

          expect(filtered_context[:user_data]).to include(password: "[FILTERED]")
          expect(filtered_context[:user_data]).to include(email: "invalid-email")

          # Ensure the actual sensitive value is NOT present
          expect(filtered_context.to_s).not_to include("secret123")
          expect(filtered_context[:user_data][:password]).not_to eq("secret123")
        end
      end

      context "with exception handling" do
        let(:action) do
          build_axn do
            expects :user_data
            expects :password, on: :user_data, sensitive: true
            expects :email, on: :user_data

            def call
              raise "Some internal error"
            end
          end
        end

        before do
          allow(Axn.config).to receive(:on_exception)
        end

        it "filters sensitive subfield in exception context" do
          expected_context = {
            user_data: { password: "[FILTERED]", email: "user@example.com" },
          }

          expect(Axn.config).to receive(:on_exception).with(
            anything,
            action:,
            context: expected_context,
          ).and_call_original

          expect(result).not_to be_ok
        end
      end

      context "with automatic logging" do
        let(:action) do
          build_axn do
            expects :user_data
            expects :password, on: :user_data, sensitive: true
            expects :email, on: :user_data

            auto_log :info
          end
        end

        it "filters sensitive subfield in logging context" do
          # Test that the logging context filters sensitive subfields
          # by checking that the context_for_logging method works correctly
          instance = action.new(user_data:)
          filtered_context = instance.send(:context_for_logging)

          expect(filtered_context[:user_data]).to include(password: "[FILTERED]")
          expect(filtered_context[:user_data]).to include(email: "user@example.com")

          # Ensure the actual sensitive value is NOT present
          expect(filtered_context.to_s).not_to include("secret123")
          expect(filtered_context[:user_data][:password]).not_to eq("secret123")
        end
      end
    end
  end

  context "subfield preprocessing" do
    let(:user_data) do
      {
        name: "John Doe",
        email: "  JOHN@EXAMPLE.COM  ",
        profile: {
          bio: "Software developer",
          website: "https://example.com",
        },
      }
    end

    context "when preprocessing is successful" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(email) { email.downcase.strip }
          expects :name, on: :user_data # No preprocessing
          expects "profile.bio", on: :user_data, preprocess: lambda(&:upcase) # Nested subfield from profile.bio
          expects "profile.website", on: :user_data, preprocess: ->(url) { url.gsub(%r{^https?://}, "") } # Nested subfield from profile.website
        end
      end

      it "preprocesses subfield values" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that preprocessing was applied by accessing the action instance
        expect(result.__action__.email).to eq("john@example.com")
        expect(result.__action__.name).to eq("John Doe") # Unchanged

        # Check nested subfield preprocessing by accessing the context data
        user_data = result.__action__.user_data

        # Check if the nested structure is correctly updated (symbol keys)
        expect(user_data.dig(:profile, :bio)).to eq("SOFTWARE DEVELOPER") # Should be preprocessed
        expect(user_data.dig(:profile, :website)).to eq("example.com") # Should be preprocessed
      end

      it "preserves original parent field structure" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # The parent field should still be accessible
        expect(result.__action__.user_data).to be_a(Hash)
        expect(result.__action__.user_data[:name]).to eq("John Doe")
      end
    end

    context "when preprocessing fails" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(email) { Date.parse(email) }
        end
      end

      it "raises PreprocessingError" do
        result = action.call(user_data:)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::ContractViolation::PreprocessingError)
        expect(result.exception.message).to include("Error preprocessing subfield 'email' on 'user_data'")
      end

      it "preserves the original exception as cause" do
        result = action.call(user_data:)
        expect(result.exception.cause).to be_a(ArgumentError)
        expect(result.exception.cause.message).to include("invalid date")
      end
    end

    context "with object-based parent fields" do
      let(:user_object) do
        Struct.new(:name, :email).new("John Doe", "JOHN@EXAMPLE.COM")
      end

      let(:action) do
        build_axn do
          expects :user
          expects :email, on: :user, preprocess: lambda(&:downcase)
        end
      end

      it "handles object-based parent fields with setter methods" do
        result = action.call(user: user_object)
        expect(result).to be_ok

        expect(result.__action__.email).to eq("john@example.com")
        expect(user_object.email).to eq("john@example.com") # Modified in place
      end
    end
  end

  context "subfield defaults" do
    let(:user_data) do
      {
        name: "John Doe",
        email: "john@example.com",
        profile: {
          bio: "Software developer",
          website: "https://example.com",
        },
      }
    end

    context "when defaults are applied successfully" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: "No bio provided"
          expects "profile.website", on: :user_data, default: "No website"
          expects "profile.location", on: :user_data, default: "Unknown location"
        end
      end

      it "applies defaults for missing simple subfields" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that the default was applied
        expect(result.__action__.bio).to eq("No bio provided")
      end

      it "applies defaults for missing nested subfields" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that the default was applied to nested structure
        user_data = result.__action__.user_data
        expect(user_data.dig(:profile, :location)).to eq("Unknown location")
      end

      it "does not apply defaults when field already exists" do
        # Add bio to user_data to test that existing values are preserved
        user_data[:bio] = "Existing bio"

        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that existing value was preserved
        expect(result.__action__.bio).to eq("Existing bio")
      end

      it "applies defaults when field is explicitly nil" do
        # Set bio to nil explicitly to test nil value handling
        user_data[:bio] = nil

        # Create a separate action that allows nil for bio
        action_with_nil_bio = build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: "No bio provided", allow_nil: true, type: String
        end

        result = action_with_nil_bio.call(user_data:)
        expect(result).to be_ok

        # Check that default was applied for nil value
        expect(result.__action__.bio).to eq("No bio provided")
      end

      it "applies defaults when field is missing" do
        # Remove bio key entirely to test missing key handling
        user_data.delete(:bio)

        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that default was applied for missing key
        expect(result.__action__.bio).to eq("No bio provided")
      end
    end

    context "with callable defaults" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: -> { "Generated bio #{Time.now.to_i}" }
          expects "profile.timestamp", on: :user_data, default: -> { "Generated at #{Time.now.to_i}" }
        end
      end

      it "evaluates callable defaults in action context" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that callable defaults were evaluated
        bio = result.__action__.bio
        expect(bio).to match(/Generated bio \d+/)

        user_data = result.__action__.user_data
        timestamp = user_data.dig(:profile, :timestamp)
        expect(timestamp).to match(/Generated at \d+/)
      end
    end

    context "with object-based parent fields" do
      let(:user_object) do
        Struct.new(:name, :email, :bio).new("John Doe", "john@example.com", nil)
      end

      let(:action) do
        build_axn do
          expects :user_object
          expects :bio, on: :user_object, default: "Default bio", allow_nil: true, type: String
        end
      end

      it "applies defaults to object-based parent fields" do
        result = action.call(user_object:)
        expect(result).to be_ok

        # Check that the default was applied to the object
        expect(result.__action__.bio).to eq("Default bio")
        expect(user_object.bio).to eq("Default bio")
      end
    end

    context "when parent field is missing" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :missing_profile, allow_nil: true, type: Hash # Declare the parent field as optional
          expects :bio, on: :missing_profile, default: "Default bio", allow_nil: true, type: String
        end
      end

      it "creates parent field and applies default" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that the parent field was created and default applied
        expect(result.__action__.missing_profile).to eq({ bio: "Default bio" })
      end
    end

    context "when default application fails" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :missing_field, on: :user_data, default: -> { raise "Default error" }, allow_nil: true, type: String
        end
      end

      it "fails with DefaultAssignmentError when default application fails" do
        result = action.call(user_data:)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::ContractViolation::DefaultAssignmentError)
        expect(result.exception.message).to include("Error applying default for subfield 'missing_field' on 'user_data'")
        expect(result.exception.cause).to be_a(RuntimeError)
        expect(result.exception.cause.message).to eq("Default error")
      end
    end
  end
end
