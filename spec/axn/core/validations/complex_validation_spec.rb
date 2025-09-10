# frozen_string_literal: true

RSpec.describe Axn do
  describe "complex validation" do
    let(:action) do
      build_axn do
        expects :foo, type: String
        exposes :bar, type: String
      end
    end

    context "success" do
      subject { action.call(foo: "a", bar: "b", baz: "c") }

      it { is_expected.to be_ok }
    end

    context "failure" do
      subject { action.call(foo: 1, bar: 2, baz: 3) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Foo is not a String")
      end
    end
  end

  describe "multiple validation types combined" do
    let(:action) do
      build_axn do
        expects :user_id, type: Numeric, validate: ->(id) { "must be positive" unless id > 0 }
        expects :email, type: String, format: { with: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i }
        expects :age, type: Numeric, numericality: { greater_than: 0, less_than: 120 }
        exposes :user_id, :email, :age

        def call
          expose :user_id, user_id
          expose :email, email
          expose :age, age
        end
      end
    end

    context "when all validations pass" do
      subject { action.call(user_id: 1, email: "test@example.com", age: 25) }

      it { is_expected.to be_ok }
    end

    context "when type validation fails" do
      subject { action.call(user_id: "invalid", email: "test@example.com", age: 25) }

      it "fails with type error" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to include("is not a Numeric")
      end
    end

    context "when custom validation fails" do
      subject { action.call(user_id: -1, email: "test@example.com", age: 25) }

      it "fails with custom validation error" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to include("must be positive")
      end
    end

    context "when format validation fails" do
      subject { action.call(user_id: 1, email: "invalid-email", age: 25) }

      it "fails with format error" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to include("is invalid")
      end
    end

    context "when numericality validation fails" do
      subject { action.call(user_id: 1, email: "test@example.com", age: 150) }

      it "fails with numericality error" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to include("must be less than 120")
      end
    end
  end

  describe "validation with multiple field types" do
    let(:action) do
      build_axn do
        expects :name, type: String, presence: true
        expects :age, type: Numeric, numericality: { greater_than: 0 }
        expects :email, type: String, format: { with: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i }
        exposes :name, :age, :email

        def call
          expose :name, name
          expose :age, age
          expose :email, email
        end
      end
    end

    context "when all validations pass" do
      subject { action.call(name: "John Doe", age: 25, email: "john@example.com") }

      it { is_expected.to be_ok }
    end

    context "when multiple validations fail" do
      subject { action.call(name: "", age: -5, email: "invalid-email") }

      it "fails with multiple validation errors" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to include("can't be blank")
        expect(subject.exception.message).to include("must be greater than 0")
        expect(subject.exception.message).to include("is invalid")
      end
    end
  end
end
