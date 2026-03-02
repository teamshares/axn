# frozen_string_literal: true

RSpec.describe "Dynamic sensitive fields" do
  describe "exposes with callable sensitive" do
    context "with a proc" do
      let(:action) do
        build_axn do
          expects :redact_mode, type: :boolean, default: false

          exposes :public_data
          exposes :secret_data, sensitive: -> { redact_mode }

          def call
            expose public_data: "visible"
            expose secret_data: "hidden-value"
          end
        end
      end

      context "when redact_mode is true" do
        subject { action.call(redact_mode: true) }

        it "filters the sensitive field in inspect" do
          expect(subject.inspect).to include("secret_data: [FILTERED]")
          expect(subject.inspect).to include("public_data: \"visible\"")
        end

        it "filters the sensitive field in outputs_for_logging" do
          instance = action.send(:new, redact_mode: true)
          instance.call
          outputs = instance.send(:outputs_for_logging)

          expect(outputs[:secret_data]).to eq("[FILTERED]")
          expect(outputs[:public_data]).to eq("visible")
        end
      end

      context "when redact_mode is false" do
        subject { action.call(redact_mode: false) }

        it "does not filter the field in inspect" do
          expect(subject.inspect).to include("secret_data: \"hidden-value\"")
          expect(subject.inspect).to include("public_data: \"visible\"")
        end

        it "does not filter the field in outputs_for_logging" do
          instance = action.send(:new, redact_mode: false)
          instance.call
          outputs = instance.send(:outputs_for_logging)

          expect(outputs[:secret_data]).to eq("hidden-value")
          expect(outputs[:public_data]).to eq("visible")
        end
      end
    end

    context "with a symbol referencing an instance method" do
      let(:action) do
        build_axn do
          expects :user_role, type: String

          exposes :admin_details, sensitive: :hide_admin_details?

          def call
            expose admin_details: "admin-secret-info"
          end

          private

          def hide_admin_details?
            user_role != "admin"
          end
        end
      end

      context "when user is admin" do
        subject { action.call(user_role: "admin") }

        it "does not filter the field" do
          expect(subject.inspect).to include("admin_details: \"admin-secret-info\"")
        end
      end

      context "when user is not admin" do
        subject { action.call(user_role: "guest") }

        it "filters the field" do
          expect(subject.inspect).to include("admin_details: [FILTERED]")
        end
      end
    end
  end

  describe "expects with callable sensitive" do
    let(:action) do
      build_axn do
        expects :include_pii, type: :boolean, default: false
        expects :ssn, sensitive: -> { !include_pii }

        exposes :processed

        def call
          expose processed: "done"
        end
      end
    end

    context "when include_pii is false (default)" do
      it "filters ssn in inputs_for_logging" do
        instance = action.send(:new, ssn: "123-45-6789")
        outputs = instance.send(:inputs_for_logging)

        expect(outputs[:ssn]).to eq("[FILTERED]")
      end

      it "filters ssn in internal_context inspect" do
        result = action.call(ssn: "123-45-6789")
        expect(result.__action__.internal_context.inspect).to include("ssn: [FILTERED]")
      end
    end

    context "when include_pii is true" do
      it "does not filter ssn in inputs_for_logging" do
        instance = action.send(:new, include_pii: true, ssn: "123-45-6789")
        outputs = instance.send(:inputs_for_logging)

        expect(outputs[:ssn]).to eq("123-45-6789")
      end
    end
  end

  describe "mixed static and dynamic sensitive fields" do
    let(:action) do
      build_axn do
        expects :verbose_mode, type: :boolean, default: false

        exposes :always_hidden, sensitive: true
        exposes :conditionally_hidden, sensitive: -> { !verbose_mode }
        exposes :never_hidden

        def call
          expose always_hidden: "secret1"
          expose conditionally_hidden: "secret2"
          expose never_hidden: "public"
        end
      end
    end

    context "when verbose_mode is false" do
      subject { action.call(verbose_mode: false) }

      it "filters both sensitive fields" do
        expect(subject.inspect).to include("always_hidden: [FILTERED]")
        expect(subject.inspect).to include("conditionally_hidden: [FILTERED]")
        expect(subject.inspect).to include("never_hidden: \"public\"")
      end
    end

    context "when verbose_mode is true" do
      subject { action.call(verbose_mode: true) }

      it "still filters static sensitive but not dynamic" do
        expect(subject.inspect).to include("always_hidden: [FILTERED]")
        expect(subject.inspect).to include("conditionally_hidden: \"secret2\"")
        expect(subject.inspect).to include("never_hidden: \"public\"")
      end
    end
  end

  describe "subfields with callable sensitive" do
    let(:action) do
      build_axn do
        expects :redact_password, type: :boolean, default: true
        expects :user_data, type: Hash
        expects :password, on: :user_data, sensitive: -> { redact_password }
        expects :email, on: :user_data

        def call; end
      end
    end

    let(:user_data) { { email: "user@example.com", password: "secret123" } }

    context "when redact_password is true" do
      it "filters the password subfield in inputs_for_logging" do
        instance = action.send(:new, user_data:, redact_password: true)
        inputs = instance.send(:inputs_for_logging)

        expect(inputs[:user_data][:password]).to eq("[FILTERED]")
        expect(inputs[:user_data][:email]).to eq("user@example.com")
      end
    end

    context "when redact_password is false" do
      it "does not filter the password subfield" do
        instance = action.send(:new, user_data:, redact_password: false)
        inputs = instance.send(:inputs_for_logging)

        expect(inputs[:user_data][:password]).to eq("secret123")
        expect(inputs[:user_data][:email]).to eq("user@example.com")
      end
    end
  end

  describe "class-level methods" do
    let(:action) do
      build_axn do
        expects :mode
        exposes :data, sensitive: -> { mode == "secret" }
      end
    end

    describe "._has_dynamic_sensitive_fields?" do
      it "returns true when there are callable sensitive fields" do
        expect(action._has_dynamic_sensitive_fields?).to be true
      end

      it "returns false when all sensitive fields are static" do
        static_action = build_axn do
          expects :input, sensitive: true
          exposes :output, sensitive: false
        end
        expect(static_action._has_dynamic_sensitive_fields?).to be false
      end
    end

    describe ".sensitive_fields (static)" do
      it "only returns statically sensitive fields" do
        mixed_action = build_axn do
          expects :static_sensitive, sensitive: true
          expects :dynamic_sensitive, sensitive: -> { true }
          expects :not_sensitive
        end

        expect(mixed_action.sensitive_fields).to eq([:static_sensitive])
      end
    end

    describe "._resolve_sensitive_fields" do
      it "resolves callable sensitive values against the action instance" do
        instance = action.send(:new, mode: "secret")
        resolved = action._resolve_sensitive_fields(instance)
        expect(resolved).to include(:data)
      end

      it "returns empty when callable evaluates to false" do
        instance = action.send(:new, mode: "public")
        resolved = action._resolve_sensitive_fields(instance)
        expect(resolved).not_to include(:data)
      end
    end
  end

  describe "execution_context integration" do
    let(:action) do
      build_axn do
        expects :hide_output, type: :boolean, default: false

        exposes :output, sensitive: -> { hide_output }

        def call
          expose output: "sensitive-data"
        end
      end
    end

    it "uses dynamic filtering in execution_context" do
      instance = action.send(:new, hide_output: true)
      instance.call
      ctx = instance.execution_context

      expect(ctx[:outputs][:output]).to eq("[FILTERED]")
    end

    it "does not filter when dynamic condition is false" do
      instance = action.send(:new, hide_output: false)
      instance.call
      ctx = instance.execution_context

      expect(ctx[:outputs][:output]).to eq("sensitive-data")
    end
  end
end
