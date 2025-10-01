# frozen_string_literal: true

RSpec.describe Axn do
  describe "problematic method names and constant collisions" do
    describe "method names with spaces and special characters" do
      context "with spaces in method names" do
        it "fails validation for method names with spaces" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method with spaces") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method with spaces' contains whitespace characters that make it uncallable with normal Ruby syntax/)
        end
      end

      context "with special characters in method names" do
        it "fails validation with $%@ characters" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method$%@name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method\$%@name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with !@# characters" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method!@#name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method!@#name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with brackets and braces" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method[]{}name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method\[\]{}name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with pipes and backslashes" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method|\\name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method\|\\name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with angle brackets" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method<>name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name 'method<>name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with colons and semicolons" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method:;name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name 'method:;name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with commas and periods" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method,.name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name 'method,.name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with ampersands and asterisks" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method&*name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method&.*name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with tildes and backticks" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method~`name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name 'method~`name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with carets and dollars" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method^$name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method\^.*name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with percent and hash" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method%#name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name 'method%#name' contains characters that make it uncallable with normal Ruby syntax/)
        end
      end

      context "with newlines and tabs in method names" do
        it "fails validation with newlines" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method\nname") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method[\s\S]*name' contains whitespace characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with tabs" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method\tname") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method.*name' contains whitespace characters that make it uncallable with normal Ruby syntax/)
        end
      end

      context "with quotes in method names" do
        it "fails validation with double quotes" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method('method"name') do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name 'method"name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation with single quotes" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method'name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name 'method'name' contains characters that make it uncallable with normal Ruby syntax/)
        end
      end
    end

    describe "constant name collisions" do
      context "when different method names generate the same constant name" do
        it "allows both 'a name' and 'a\tname' since they both fail validation" do
          # Both should fail validation before reaching constant collision
          client_class1 = Class.new do
            include Axn
          end

          expect do
            client_class1.class_eval do
              axn_method("a name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'a name' contains whitespace characters that make it uncallable with normal Ruby syntax/)

          client_class2 = Class.new do
            include Axn
          end

          expect do
            client_class2.class_eval do
              axn_method("a\tname") do
                456
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'a\tname' contains whitespace characters that make it uncallable with normal Ruby syntax/)
        end

        it "allows both 'method name' and 'method\tname' since they both fail validation" do
          # Both should fail validation before reaching constant collision
          client_class1 = Class.new do
            include Axn
          end

          expect do
            client_class1.class_eval do
              axn_method("method name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method name' contains whitespace characters that make it uncallable with normal Ruby syntax/)

          client_class2 = Class.new do
            include Axn
          end

          expect do
            client_class2.class_eval do
              axn_method("method\tname") do
                456
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method\tname' contains whitespace characters that make it uncallable with normal Ruby syntax/)
        end
      end

      context "when method names with different whitespace generate the same constant name" do
        it "allows both 'method name' and 'method  name' since they both fail validation" do
          # Both should fail validation before reaching constant collision
          client_class1 = Class.new do
            include Axn
          end

          expect do
            client_class1.class_eval do
              axn_method("method name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method name' contains whitespace characters that make it uncallable with normal Ruby syntax/)

          client_class2 = Class.new do
            include Axn
          end

          expect do
            client_class2.class_eval do
              axn_method("method  name") do
                456
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method  name' contains whitespace characters that make it uncallable with normal Ruby syntax/)
        end
      end
    end

    describe "method name callability" do
      context "with method names that are not callable with normal Ruby syntax" do
        it "fails validation for methods with spaces" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method with spaces") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method with spaces' contains whitespace characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation for methods with special characters" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method$%@name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method\$%@name' contains characters that make it uncallable with normal Ruby syntax/)
        end

        it "fails validation for methods with brackets" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("method[]name") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name 'method\[\]name' contains characters that make it uncallable with normal Ruby syntax/)
        end
      end
    end

    describe "edge cases with empty and invalid names" do
      context "with empty method names" do
        it "fails validation for empty string" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name cannot be empty/)
        end

        it "fails validation for whitespace-only string" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("   ") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError,
                             /method name '   ' contains whitespace characters that make it uncallable with normal Ruby syntax/)
        end
      end

      context "with method names that don't start with a letter" do
        it "fails validation for names starting with numbers" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("123method") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name '123method' cannot start with a number/)
        end

        it "fails validation for names starting with special characters" do
          client_class = Class.new do
            include Axn
          end

          expect do
            client_class.class_eval do
              axn_method("@method") do
                123
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /method name '@method' contains characters that make it uncallable with normal Ruby syntax/)
        end
      end
    end

    describe "successful cases with valid names" do
      context "with valid method names" do
        it "works with simple method names" do
          client_class = Class.new do
            include Axn
          end

          client_class.class_eval do
            axn_method("simple_method") do
              123
            end
          end

          expect(client_class.simple_method!).to eq(123)
        end

        it "works with method names containing underscores" do
          client_class = Class.new do
            include Axn
          end

          client_class.class_eval do
            axn_method("method_with_underscores") do
              123
            end
          end

          expect(client_class.method_with_underscores!).to eq(123)
        end

        it "works with method names containing numbers" do
          client_class = Class.new do
            include Axn
          end

          client_class.class_eval do
            axn_method("method123") do
              123
            end
          end

          expect(client_class.method123!).to eq(123)
        end

        it "works with method names containing question marks" do
          client_class = Class.new do
            include Axn
          end

          client_class.class_eval do
            axn_method("method?") do
              123
            end
          end

          expect(client_class.public_send("method?!")).to eq(123)
        end

        it "works with method names containing exclamation marks" do
          client_class = Class.new do
            include Axn
          end

          client_class.class_eval do
            axn_method("method!") do
              123
            end
          end

          expect(client_class.public_send("method!!")).to eq(123)
        end

        it "works with method names containing equals signs" do
          client_class = Class.new do
            include Axn
          end

          client_class.class_eval do
            axn_method("method=") do
              123
            end
          end

          expect(client_class.public_send("method=!")).to eq(123)
        end
      end
    end

    describe "constant name sanitization and uniqueness" do
      context "when method names would generate the same constant name" do
        it "allows both 'method_name' and 'methodname' since they're both valid" do
          # Both should work since they're valid method names
          client_class = Class.new do
            include Axn
          end

          client_class.class_eval do
            axn_method("method_name") do
              123
            end
          end

          client_class.class_eval do
            axn_method("methodname") do
              456
            end
          end

          expect(client_class.method_name!).to eq(123)
          expect(client_class.methodname!).to eq(456)
        end

        it "handles constant name collisions with unique suffixes" do
          # Create a class that will have constant collisions
          client_class = Class.new do
            include Axn
          end

          client_class.class_eval do
            axn_method("test") do
              123
            end
          end

          # The second one should fail due to method name collision
          expect do
            client_class.class_eval do
              axn_method("test") do
                456
              end
            end
          end.to raise_error(Axn::Attachable::AttachmentError, /Method unable to attach -- method 'test!' is already taken/)

          # Only the first one should work
          expect(client_class.test!).to eq(123)
        end
      end
    end
  end
end
