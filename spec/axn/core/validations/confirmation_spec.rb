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
