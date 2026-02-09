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

    context "with optional: true on subfields" do
      let(:action) do
        build_axn do
          expects :foo, optional: true
          expects :bar, :baz, on: :foo, optional: true, type: String
          exposes :output, optional: true

          def call
            expose output: "success"
          end
        end
      end

      context "when subfield is missing" do
        subject { action.call(foo: {}) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield is nil" do
        subject { action.call(foo: { bar: nil, baz: nil }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield is blank" do
        subject { action.call(foo: { bar: "", baz: "   " }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield has valid value" do
        subject { action.call(foo: { bar: "hello", baz: "world" }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end
    end

    context "with optional: true and type validation on subfields" do
      let(:action) do
        build_axn do
          expects :foo, optional: true
          expects :name, on: :foo, type: String, optional: true
          exposes :output, optional: true

          def call
            expose output: "success"
          end
        end
      end

      context "when subfield is missing" do
        subject { action.call(foo: {}) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield is nil" do
        subject { action.call(foo: { name: nil }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield is empty string" do
        subject { action.call(foo: { name: "" }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield has valid string value" do
        subject { action.call(foo: { name: "John" }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield has invalid type" do
        subject { action.call(foo: { name: 123 }) }

        it "fails validation" do
          is_expected.not_to be_ok
          expect(subject.exception.message).to include("is not a String")
        end
      end
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

          it "does not create reader methods but still validates correctly" do
            expect { action }.not_to raise_error

            # Should not create a reader method for the nested field when readers: false
            expect(action).not_to respond_to(:foo)

            # But validation should still work correctly - with improved validation system,
            # validation works regardless of whether reader methods are created
            expect(action.call(foo: { bar: { foo: 3 } })).to be_ok
            expect(action.call(foo: { bar: { baz: 3 } })).not_to be_ok # Still fails validation as expected
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

          # Sensitive subfields should now be filtered in inspection
          expect(result.internal_ctx.inspect).to include("[FILTERED]")
          expect(result.internal_ctx.inspect).not_to include("secret123")
        end

        it "filters sensitive subfield in execution_context" do
          # Test that execution_context filters sensitive subfields
          instance = action.send(:new, user_data:)
          exec_ctx = instance.execution_context

          expect(exec_ctx[:inputs][:user_data]).to include(password: "[FILTERED]")
          expect(exec_ctx[:inputs][:user_data]).to include(email: "user@example.com")

          # Ensure the actual sensitive value is NOT present
          expect(exec_ctx.to_s).not_to include("secret123")
          expect(exec_ctx[:inputs][:user_data][:password]).not_to eq("secret123")
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
          # Test that sensitive data is filtered in error logging by checking execution_context
          instance = action.send(:new, user_data:)
          exec_ctx = instance.execution_context

          expect(exec_ctx[:inputs][:user_data]).to include(password: "[FILTERED]")
          expect(exec_ctx[:inputs][:user_data]).to include(email: "invalid-email")

          # Ensure the actual sensitive value is NOT present
          expect(exec_ctx.to_s).not_to include("secret123")
          expect(exec_ctx[:inputs][:user_data][:password]).not_to eq("secret123")
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
          expect(Axn.config).to receive(:on_exception).with(
            anything,
            action:,
            context: hash_including(
              inputs: {
                user_data: { password: "[FILTERED]", email: "user@example.com" },
              },
              outputs: {},
            ),
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

            log_calls :info
          end
        end

        it "filters sensitive subfield in logging context" do
          # Test that inputs_for_logging filters sensitive subfields for automatic logging
          instance = action.send(:new, user_data:)
          filtered_inputs = instance.send(:inputs_for_logging)

          expect(filtered_inputs[:user_data]).to include(password: "[FILTERED]")
          expect(filtered_inputs[:user_data]).to include(email: "user@example.com")

          # Ensure the actual sensitive value is NOT present
          expect(filtered_inputs.to_s).not_to include("secret123")
          expect(filtered_inputs[:user_data][:password]).not_to eq("secret123")
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

    context "when fail! is called in subfield preprocess block" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(_email) { fail!("Invalid email") }
        end
      end

      it "fails with Axn::Failure" do
        result = action.call(user_data:)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::Failure)
        expect(result.exception).not_to be_a(Axn::ContractViolation::PreprocessingError)
      end

      it "sets the error message" do
        result = action.call(user_data:)
        expect(result.error).to eq("Invalid email")
      end

      it "triggers on_failure handlers, not on_exception" do
        failure_called = false
        exception_called = false

        action = build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(_email) { fail!("Invalid email") }

          on_failure { failure_called = true }
          on_exception { exception_called = true }
        end

        action.call(user_data:)
        expect(failure_called).to be true
        expect(exception_called).to be false
      end
    end

    context "when done! is called in subfield preprocess block" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(_email) { done!("Early completion") }
        end
      end

      it "returns a successful result" do
        result = action.call(user_data:)
        expect(result).to be_ok
      end

      it "sets the success message" do
        result = action.call(user_data:)
        expect(result.success).to eq("Early completion")
      end

      it "triggers on_success handlers" do
        success_called = false

        action = build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(_email) { done!("Early completion") }

          on_success { success_called = true }
        end

        result = action.call(user_data:)
        expect(result).to be_ok
        expect(success_called).to be true
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

        result = action.call(user_data:)
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
          expects :bio, on: :user_object, default: "Default bio", type: String
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
          expects :bio, on: :missing_profile, default: "Default bio", type: String
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
          expects :missing_field, on: :user_data, default: -> { raise "Default error" }, type: String
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

    context "subfield defaults with blank values" do
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

      shared_examples "subfield default behavior with blank values" do |default_value, allow_blank, expected_behavior|
        let(:action) do
          build_axn do
            expects :user_data
            expects :bio, on: :user_data, default: default_value, allow_blank:, type: String
            expects "profile.description", on: :user_data, default: default_value, allow_blank:, type: String
          end
        end

        context "when subfield is missing" do
          it "applies default and #{expected_behavior[:missing]}" do
            result = action.call(user_data:)
            if expected_behavior[:missing][:success]
              expect(result).to be_ok
              expect(result.__action__.bio).to eq default_value
              expect(user_data.dig(:profile, :description)).to eq default_value
            else
              expect(result).not_to be_ok
              expect(result.exception).to be_a(Axn::InboundValidationError)
              expect(result.exception.message).to include("can't be blank")
            end
          end
        end

        context "when subfield is explicitly nil" do
          before do
            user_data[:bio] = nil
            user_data[:profile][:description] = nil
          end

          it "applies default and #{expected_behavior[:nil]}" do
            result = action.call(user_data:)
            if expected_behavior[:nil][:success]
              expect(result).to be_ok
              expect(result.__action__.bio).to eq default_value
              expect(user_data.dig(:profile, :description)).to eq default_value
            else
              expect(result).not_to be_ok
              expect(result.exception).to be_a(Axn::InboundValidationError)
              expect(result.exception.message).to include("can't be blank")
            end
          end
        end

        context "when subfield has blank string value" do
          before do
            user_data[:bio] = ""
            user_data[:profile][:description] = ""
          end

          it "preserves existing blank value and #{expected_behavior[:blank]}" do
            result = action.call(user_data:)
            if expected_behavior[:blank][:success]
              expect(result).to be_ok
              expect(result.__action__.bio).to eq ""
              expect(user_data.dig(:profile, :description)).to eq ""
            else
              expect(result).not_to be_ok
              expect(result.exception).to be_a(Axn::InboundValidationError)
              expect(result.exception.message).to include("can't be blank")
            end
          end
        end

        context "when subfield has non-blank value" do
          before do
            user_data[:bio] = "Existing bio"
            user_data[:profile][:description] = "Existing description"
          end

          it "preserves existing value and passes validation" do
            result = action.call(user_data:)
            expect(result).to be_ok
            expect(result.__action__.bio).to eq "Existing bio"
            expect(user_data.dig(:profile, :description)).to eq "Existing description"
          end
        end
      end

      context "with blank string default and allow_blank: true" do
        include_examples "subfield default behavior with blank values", "", true, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: true, description: "passes validation (does not apply default)" },
        }
      end

      context "with blank string default and allow_blank: false" do
        include_examples "subfield default behavior with blank values", "", false, {
          missing: { success: false, description: "fails validation" },
          nil: { success: false, description: "fails validation" },
          blank: { success: false, description: "fails validation" },
        }
      end

      context "with non-blank default and allow_blank: true" do
        include_examples "subfield default behavior with blank values", "Default bio", true, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: true, description: "passes validation (does not apply default)" },
        }
      end

      context "with non-blank default and allow_blank: false" do
        include_examples "subfield default behavior with blank values", "Default bio", false, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: false, description: "fails validation" },
        }
      end
    end
  end
end
