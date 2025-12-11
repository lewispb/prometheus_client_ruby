# frozen_string_literal: true

require 'prometheus/client/data_stores/native_histogram_storage/bucket_calculator'

RSpec.describe Prometheus::Client::DataStores::NativeHistogramStorage::BucketCalculator do
  describe '#initialize' do
    it 'accepts valid schema values from -4 to 8' do
      (-4..8).each do |schema|
        expect { described_class.new(schema) }.not_to raise_error
      end
    end

    it 'rejects schema values outside valid range' do
      expect { described_class.new(-5) }.to raise_error(ArgumentError, /must be between -4 and 8/)
      expect { described_class.new(9) }.to raise_error(ArgumentError, /must be between -4 and 8/)
    end
  end

  describe '#base' do
    it 'returns 2^(2^-schema)' do
      calc = described_class.new(3)
      expect(calc.base).to be_within(0.0001).of(2**(2**-3))
    end

    it 'returns 2.0 for schema 0' do
      calc = described_class.new(0)
      expect(calc.base).to eq(2.0)
    end
  end

  describe '#bucket_index' do
    let(:calc) { described_class.new(3) }

    it 'returns [:positive, index] for positive values' do
      sign, index = calc.bucket_index(1.5)
      expect(sign).to eq(:positive)
      expect(index).to be_a(Integer)
    end

    it 'returns [:negative, index] for negative values' do
      sign, index = calc.bucket_index(-1.5)
      expect(sign).to eq(:negative)
      expect(index).to be_a(Integer)
    end

    it 'returns nil for zero' do
      expect(calc.bucket_index(0.0)).to be_nil
    end

    it 'returns nil for NaN' do
      expect(calc.bucket_index(Float::NAN)).to be_nil
    end

    it 'returns nil for Infinity' do
      expect(calc.bucket_index(Float::INFINITY)).to be_nil
    end

    it 'places 1.0 in bucket 0' do
      sign, index = calc.bucket_index(1.0)
      expect([sign, index]).to eq([:positive, 0])
    end

    it 'places 2.0 in bucket 8 for schema 3' do
      sign, index = calc.bucket_index(2.0)
      expect([sign, index]).to eq([:positive, 8])
    end
  end

  describe '#upper_bound / #lower_bound' do
    let(:calc) { described_class.new(3) }

    it 'returns base^index for upper_bound' do
      expect(calc.upper_bound(1)).to be_within(0.0001).of(calc.base**1)
    end

    it 'returns base^(index-1) for lower_bound' do
      expect(calc.lower_bound(1)).to be_within(0.0001).of(calc.base**0)
    end

    it 'has upper_bound(0) = 1.0' do
      expect(calc.upper_bound(0)).to eq(1.0)
    end
  end

  describe '.merge_index' do
    it 'maps index 0 to 0' do
      expect(described_class.merge_index(0)).to eq(0)
    end

    it 'maps positive indices in pairs' do
      expect(described_class.merge_index(1)).to eq(1)
      expect(described_class.merge_index(2)).to eq(1)
      expect(described_class.merge_index(3)).to eq(2)
      expect(described_class.merge_index(4)).to eq(2)
    end

    it 'maps negative indices in pairs' do
      expect(described_class.merge_index(-1)).to eq(-1)
      expect(described_class.merge_index(-2)).to eq(-2)
      expect(described_class.merge_index(-3)).to eq(-2)
      expect(described_class.merge_index(-4)).to eq(-3)
    end
  end
end
