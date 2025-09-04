# frozen_string_literal: true

RSpec.describe Axn do
  describe ".axnable_method" do
    let(:client) do
      build_action do
        error "bad"

        axnable_method :number, error: "badbadbad" do |arg:|
          fail! "arg was all 1s" if arg.to_s.chars.uniq == ["1"]
          raise "arg was all 2s" if arg.to_s.chars.uniq == ["2"]

          10 + arg.to_i
        end
      end
    end

    it "exposes expected API" do
      expect(client).not_to respond_to(:number)
      expect(client).to respond_to(:number!)
      expect(client).to respond_to(:number_axn)
    end

    describe "when called as axn" do
      it "handles success" do
        result = client.number_axn(arg: 123)
        expect(result).to be_ok
        expect(result.value).to eq(133)
      end

      it "handles fail!" do
        result = client.number_axn(arg: 111)
        expect(result).not_to be_ok
        expect(result.error).to eq("arg was all 1s")
        expect(result.exception).to be_a(Axn::Failure)
        expect(result.exception.message).to eq("arg was all 1s")
        expect(result.value).to eq(nil)
      end

      it "handles raise" do
        result = client.number_axn(arg: 22)
        expect(result).not_to be_ok
        expect(result.error).to eq("badbadbad")
        expect(result.exception).to be_a(RuntimeError)
        expect(result.value).to eq(nil)
      end
    end

    describe "when called as method" do
      it "handles success" do
        result = client.number!(arg: 123)
        expect(result).to eq(133)
      end

      it "handles fail!" do
        expect { client.number!(arg: 111) }.to raise_error(Axn::Failure) do |error|
          expect(error.message).to eq("arg was all 1s")
        end
      end

      it "handles raise" do
        expect { client.number!(arg: 22) }.to raise_error(RuntimeError) do |error|
          expect(error.message).to eq("arg was all 2s")
        end
      end
    end
  end
end
