# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Axn Generator Templates" do
  describe "template rendering" do
    let(:action_template) { File.read(File.expand_path("../../../../lib/axn/rails/generators/templates/action.rb.erb", __dir__)) }
    let(:spec_template) { File.read(File.expand_path("../../../../lib/axn/rails/generators/templates/action_spec.rb.erb", __dir__)) }

    let(:class_name) { "Test::Action" }
    let(:expectations) { %w[param1 param2] }

    let(:binding_context) do
      binding.tap do |ctx|
        ctx.local_variable_set(:class_name, class_name)
        ctx.local_variable_set(:expectations, expectations)
      end
    end

    let(:action_result) { ERB.new(action_template, trim_mode: "-").result(binding_context) }
    let(:spec_result) { ERB.new(spec_template, trim_mode: "-").result(binding_context) }
    let(:multi_expectation_action_output) do
      <<~RUBY
        # frozen_string_literal: true

        class Test::Action
          include Axn

          expects :param1
          expects :param2

          def call
            # TODO: Implement action logic
          end
        end
      RUBY
    end

    let(:multi_expectation_spec_output) do
      <<~RUBY
        # frozen_string_literal: true

        RSpec.describe Test::Action do
          let(:param1) { "param1" }
          let(:param2) { "param2" }

          describe ".call" do
            subject(:result) { described_class.call(param1:, param2:) }

            it "executes successfully" do
              expect(result).to be_ok
            end

            it "TODO: replace with a meaningful failure case" do
              result = described_class.call
              expect(result).not_to be_ok
              expect(result.error).to eq("Something went wrong")
            end
          end
        end
      RUBY
    end

    let(:no_expectation_action_output) do
      <<~RUBY
        # frozen_string_literal: true

        class SimpleAction
          include Axn

          def call
            # TODO: Implement action logic
          end
        end
      RUBY
    end

    let(:single_expectation_action_output) do
      <<~RUBY
        # frozen_string_literal: true

        class SingleAction
          include Axn

          expects :param

          def call
            # TODO: Implement action logic
          end
        end
      RUBY
    end

    it "renders action template correctly" do
      expect(action_result).to eq(multi_expectation_action_output)
    end

    it "renders spec template correctly" do
      expect(spec_result).to eq(multi_expectation_spec_output)
    end

    context "with no expectations" do
      let(:class_name) { "SimpleAction" }
      let(:expectations) { [] }

      it "handles no expectations" do
        expect(action_result).to eq(no_expectation_action_output)
      end
    end

    context "with single expectation" do
      let(:class_name) { "SingleAction" }
      let(:expectations) { ["param"] }

      it "handles single expectation" do
        expect(action_result).to eq(single_expectation_action_output)
      end
    end
  end
end
