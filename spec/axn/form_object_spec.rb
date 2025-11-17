# frozen_string_literal: true

RSpec.describe Axn::FormObject do
  describe "inheritance" do
    it "inherits field_names from parent" do
      parent = Class.new(described_class) do
        attr_accessor :parent_field
      end

      child = Class.new(parent) do
        attr_accessor :child_field
      end

      expect(child.field_names).to include(:parent_field, :child_field)
    end

    it "handles anonymous classes gracefully" do
      anonymous = Class.new(described_class)
      expect { anonymous.new }.not_to raise_error
    end
  end

  describe "attr_accessor" do
    let(:form_class) do
      Class.new(described_class) do
        attr_accessor :name, :email
      end
    end

    it "tracks field names" do
      expect(form_class.field_names).to include(:name, :email)
    end

    it "creates accessor methods" do
      form = form_class.new(name: "John", email: "john@example.com")
      expect(form.name).to eq("John")
      expect(form.email).to eq("john@example.com")
    end
  end

  describe "validates" do
    let(:form_class) do
      Class.new(described_class) do
        def self.name
          "TestForm"
        end

        validates :name, presence: true
        validates :email, presence: true, format: { with: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i }
      end
    end

    it "automatically creates attr_accessor for validated fields" do
      expect(form_class.field_names).to include(:name, :email)
    end

    it "validates presence" do
      form = form_class.new
      expect(form).not_to be_valid
      expect(form.errors[:name]).to be_present
      expect(form.errors[:email]).to be_present
    end

    it "validates format" do
      form = form_class.new(name: "John", email: "invalid-email")
      expect(form).not_to be_valid
      expect(form.errors[:email]).to be_present
    end

    it "is valid when all validations pass" do
      form = form_class.new(name: "John", email: "john@example.com")
      expect(form).to be_valid
    end
  end

  describe "nested_forms" do
    let(:child_form_class) do
      Class.new(described_class) do
        def self.name
          "ChildForm"
        end

        attr_accessor :child_field
        validates :child_field, presence: true
      end
    end

    let(:parent_form_class) do
      child = child_form_class
      Class.new(described_class) do
        def self.name
          "ParentForm"
        end

        nested_forms child_form: child
      end
    end

    it "creates nested form accessor" do
      form = parent_form_class.new(child_form: { child_field: "value" })
      expect(form.child_form).to be_a(child_form_class)
      expect(form.child_form.child_field).to eq("value")
    end

    it "validates nested form" do
      form = parent_form_class.new(child_form: {})
      expect(form).not_to be_valid
      expect(form.errors[:"child_form.child_field"]).to be_present
    end

    it "handles nil nested form" do
      form = parent_form_class.new(child_form: nil)
      expect(form.child_form).to be_nil
    end

    it "injects parent form if child has parent_form= method" do
      child_with_parent = Class.new(described_class) do
        attr_accessor :parent_form, :child_field
      end

      parent = Class.new(described_class) do
        nested_forms child_form: child_with_parent
      end

      form = parent.new(child_form: { child_field: "value" })
      expect(form.child_form.parent_form).to eq(form)
    end

    it "supports nested_form alias" do
      child = child_form_class
      parent = Class.new(described_class) do
        def self.name
          "ParentForm"
        end

        nested_form child_form: child
      end

      form = parent.new(child_form: { child_field: "value" })
      expect(form.child_form).to be_a(child_form_class)
    end
  end

  describe "#to_h" do
    let(:form_class) do
      Class.new(described_class) do
        attr_accessor :name, :email, :age
      end
    end

    it "converts form to hash" do
      form = form_class.new(name: "John", email: "john@example.com", age: 30)
      expect(form.to_h).to eq({ name: "John", email: "john@example.com", age: 30 })
    end

    it "handles nested forms" do
      child = Class.new(described_class) do
        attr_accessor :child_field
      end

      parent = Class.new(described_class) do
        attr_accessor :parent_field
        nested_forms child_form: child
      end

      form = parent.new(parent_field: "parent", child_form: { child_field: "child" })
      expect(form.to_h).to eq({
        parent_field: "parent",
        child_form: { child_field: "child" },
      })
    end

    it "returns empty hash when field_names is nil" do
      form_class.field_names = nil
      form = form_class.new(name: "John")
      expect(form.to_h).to eq({})
    end

    it "only includes fields that respond to the method" do
      form_class = Class.new(described_class) do
        attr_accessor :name
      end

      form = form_class.new(name: "John")
      # Add a field_name that doesn't have an accessor
      form_class.field_names = [:name, :nonexistent]
      expect(form.to_h).to eq({ name: "John" })
    end
  end

  describe "ActiveModel::Model integration" do
    let(:form_class) do
      Class.new(described_class) do
        attr_accessor :name
        validates :name, presence: true
      end
    end

    it "includes ActiveModel::Model" do
      expect(described_class.included_modules).to include(ActiveModel::Model)
    end

    it "accepts attributes in initializer" do
      form = form_class.new(name: "John")
      expect(form.name).to eq("John")
    end

    it "supports valid? method" do
      form = form_class.new
      expect(form).not_to be_valid
      form.name = "John"
      expect(form).to be_valid
    end

    it "supports errors object" do
      form = form_class.new
      expect(form.errors).to be_a(ActiveModel::Errors)
    end
  end
end

