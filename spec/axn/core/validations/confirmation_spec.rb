# frozen_string_literal: true

RSpec.describe "confirmation:" do
  # Mirrors the inline `Class.new { include Axn; def call = nil }` idiom the rest of the suite uses.
  def build_axn(&declaration)
    Class.new do
      include Axn
      def call = nil
    end.tap { |klass| klass.class_eval(&declaration) }
  end

  describe "a declared pair at the top level" do
    let(:action) do
      build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true
      end
    end

    it "passes when the confirmation matches" do
      expect(action.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "fails when the confirmation does not match" do
      result = action.call(password: "s3cret", password_confirmation: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to include("Password confirmation doesn't match Password")
    end

    it "compares the companion's transformed value, not its raw wire value" do
      klass = build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true, preprocess: ->(s) { s&.strip }
      end
      expect(klass.call(password: "s3cret", password_confirmation: "  s3cret  ")).to be_ok
    end
  end

  describe "the implicit companion" do
    let(:action) { build_axn { expects :password, type: String, confirmation: true } }

    it "fails a mismatch with no companion declared by the author" do
      result = action.call(password: "s3cret", password_confirmation: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to include("Password confirmation doesn't match Password")
    end

    it "passes a match with no companion declared by the author" do
      expect(action.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "inherits coerce: so both sides compare in the same space" do
      klass = build_axn { expects :count, coerce: Integer, confirmation: true }
      expect(klass.call(count: "5", count_confirmation: "5")).to be_ok
    end

    it "inherits preprocess: so both sides compare in the same space" do
      klass = build_axn { expects :name, type: String, preprocess: ->(s) { s&.strip }, confirmation: true }
      expect(klass.call(name: " kd ", name_confirmation: " kd ")).to be_ok
    end

    it "does not inherit default:, which would satisfy its own comparison" do
      klass = build_axn { expects :password, type: String, default: "fallback", confirmation: true }
      expect(klass.call).not_to be_ok
    end

    it "names the reader off the aliased reader and the wire key off the field" do
      klass = build_axn { expects :password, as: :pw, type: String, confirmation: true }

      expect(klass.instance_methods).to include(:pw_confirmation)
      companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }
      expect(companion).not_to be_nil
      expect(companion.reader_as).to eq(:pw_confirmation)
    end

    it "stands down when the author declares the companion explicitly" do
      klass = build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true
      end
      expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "stands down when the author declares the companion first" do
      klass = build_axn do
        expects :password_confirmation, type: String, optional: true
        expects :password, type: String, confirmation: true
      end
      expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
      expect(klass.internal_field_configs.count { |c| c.field == :password_confirmation }).to eq(1)
    end

    it "requires the companion once there is something to confirm" do
      result = action.call(password: "s3cret")
      expect(result).not_to be_ok
      expect(result.exception.message).to include("Password confirmation")
    end

    it "does not require the companion when the base field is absent" do
      expect(action.call).not_to be_ok
      expect(action.call.exception.message).not_to include("Password confirmation")
    end

    it "holds its generated reader to the same collision bar as a declared one" do
      expect do
        build_axn do
          expects :other, as: :password_confirmation, type: String, optional: true
          expects :password, type: String, confirmation: true
        end
      end.to raise_error(ArgumentError, /Reader name collision: password_confirmation/)
    end

    it "still reports a genuinely duplicated explicit declaration" do
      expect do
        build_axn do
          expects :password, type: String, confirmation: true
          expects :password_confirmation, type: String, optional: true
          expects :password_confirmation, type: String, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /password_confirmation/)
    end

    it "works on a subfield" do
      klass = build_axn do
        expects :payload, type: Hash
        expects :password, on: :payload, type: String, confirmation: true
      end
      expect(klass.call(payload: { password: "a", password_confirmation: "b" })).not_to be_ok
      expect(klass.call(payload: { password: "a", password_confirmation: "a" })).to be_ok
    end

    it "stands down on a subfield when the author declares the companion explicitly, in either order" do
      after = build_axn do
        expects :payload, type: Hash
        expects :password, on: :payload, type: String, confirmation: true
        expects :password_confirmation, on: :payload, type: String, optional: true
      end
      before = build_axn do
        expects :payload, type: Hash
        expects :password_confirmation, on: :payload, type: String, optional: true
        expects :password, on: :payload, type: String, confirmation: true
      end

      [after, before].each do |klass|
        companions = klass.send(:subfield_configs).select { |c| c.field == :password_confirmation }
        expect(companions.size).to eq(1)
        # The author's declaration is the one that stands: `optional:` means an omitted companion passes.
        expect(klass.call(payload: { password: "a" })).to be_ok
        expect(klass.call(payload: { password: "a", password_confirmation: "b" })).not_to be_ok
      end
    end
  end

  describe "positions where it cannot be honored" do
    it "refuses confirmation: on exposes" do
      expect do
        build_axn { exposes :token, type: String, confirmation: true }
      end.to raise_error(ArgumentError, /does not support confirmation:/)
    end

    it "refuses confirmation: on a shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :password, type: String, confirmation: true
          end
        end
      end.to raise_error(ArgumentError, /shape member `password` does not support confirmation:/)
    end
  end
end
