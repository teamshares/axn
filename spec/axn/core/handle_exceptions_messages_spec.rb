# frozen_string_literal: true

RSpec.describe Axn do
  describe "#error configuration (for #error when swallowing exceptions)" do
    let(:klass) { nil }

    let(:action) do
      build_axn do
        expects :klass, allow_blank: true

        success "great news"
        error lambda { |e|
          case e
          when RuntimeError then "RUN RUN RUN"
          when ArgumentError then "Bad args: #{e.message}"
          else "baseline message"
          end
        }

        def call
          return if klass.blank?

          raise klass, "Pretending something went wrong"
        end
      end
    end

    subject { action.call(klass:) }

    it { is_expected.to be_ok }
    it { expect(subject.success).to eq("great news") }
    it { expect(subject.message).to eq("great news") }

    context "with RuntimeError" do
      let(:klass) { RuntimeError }

      it { is_expected.not_to be_ok }
      it { expect(subject.error).to eq("RUN RUN RUN") }
      it { expect(subject.message).to eq("RUN RUN RUN") }
    end

    context "with ArgumentError" do
      let(:klass) { ArgumentError }

      it { is_expected.not_to be_ok }
      it { expect(subject.error).to eq("Bad args: Pretending something went wrong") }
      it { expect(subject.message).to eq("Bad args: Pretending something went wrong") }
    end

    context "with other error" do
      let(:klass) { StandardError }

      it { is_expected.not_to be_ok }
      it { expect(subject.error).to eq("baseline message") }
      it { expect(subject.message).to eq("baseline message") }
    end
  end
end
