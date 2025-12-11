# frozen_string_literal: true

require 'prometheus/client/data_stores/native_histogram_storage/span_delta_codec'

RSpec.describe Prometheus::Client::DataStores::NativeHistogramStorage::SpanDeltaCodec do
  describe '.encode' do
    it 'returns empty arrays for empty input' do
      spans, deltas = described_class.encode({})
      expect(spans).to eq([])
      expect(deltas).to eq([])
    end

    it 'encodes a single bucket' do
      spans, deltas = described_class.encode({ 5 => 10 })
      expect(spans.length).to eq(1)
      expect(spans[0].offset).to eq(5)
      expect(spans[0].length).to eq(1)
      expect(deltas).to eq([10])
    end

    it 'encodes consecutive buckets as single span' do
      spans, deltas = described_class.encode({ 0 => 5, 1 => 3, 2 => 7 })
      expect(spans.length).to eq(1)
      expect(spans[0].offset).to eq(0)
      expect(spans[0].length).to eq(3)
      expect(deltas).to eq([5, -2, 4])
    end

    it 'encodes non-consecutive buckets as multiple spans' do
      spans, deltas = described_class.encode({ 0 => 5, 1 => 3, 5 => 2, 6 => 4 })
      expect(spans.length).to eq(2)
      expect(spans[0].to_h).to eq({ offset: 0, length: 2 })
      expect(spans[1].to_h).to eq({ offset: 3, length: 2 })
    end

    it 'uses delta encoding for counts' do
      spans, deltas = described_class.encode({ 0 => 10, 1 => 15, 2 => 12 })
      # Deltas: 10, 15-10=5, 12-15=-3
      expect(deltas).to eq([10, 5, -3])
    end
  end

  describe '.decode' do
    it 'returns empty hash for empty input' do
      expect(described_class.decode([], [])).to eq({})
      expect(described_class.decode(nil, nil)).to eq({})
    end

    it 'decodes single span' do
      span = Prometheus::Client::DataStores::NativeHistogramStorage::Span.new(offset: 5, length: 1)
      result = described_class.decode([span], [10])
      expect(result).to eq({ 5 => 10 })
    end

    it 'decodes consecutive buckets' do
      span = Prometheus::Client::DataStores::NativeHistogramStorage::Span.new(offset: 0, length: 3)
      result = described_class.decode([span], [5, -2, 4])
      expect(result).to eq({ 0 => 5, 1 => 3, 2 => 7 })
    end

    it 'decodes hash-based spans (from protobuf)' do
      spans = [{ offset: 0, length: 2 }, { offset: 3, length: 2 }]
      result = described_class.decode(spans, [5, -2, 2, 2])
      expect(result).to eq({ 0 => 5, 1 => 3, 5 => 5, 6 => 7 })
    end
  end

  describe 'round-trip' do
    [
      {},
      { 0 => 1 },
      { 0 => 5, 1 => 3, 2 => 7 },
      { 0 => 5, 1 => 3, 5 => 2, 6 => 4 },
      { -5 => 1, -4 => 2, 0 => 5, 1 => 3 },
      { 100 => 50, 101 => 60, 200 => 10 },
    ].each do |buckets|
      it "round-trips #{buckets.inspect}" do
        spans, deltas = described_class.encode(buckets)
        decoded = described_class.decode(spans, deltas)
        expect(decoded).to eq(buckets)
      end
    end
  end
end

RSpec.describe Prometheus::Client::DataStores::NativeHistogramStorage::Span do
  it 'is a Data class' do
    expect(described_class).to be < Data
  end

  it 'has offset and length attributes' do
    span = described_class.new(offset: 5, length: 3)
    expect(span.offset).to eq(5)
    expect(span.length).to eq(3)
  end

  it 'is immutable' do
    span = described_class.new(offset: 5, length: 3)
    expect { span.instance_variable_set(:@offset, 10) }.to raise_error(FrozenError)
  end

  describe '#to_h' do
    it 'returns hash representation' do
      span = described_class.new(offset: 5, length: 3)
      expect(span.to_h).to eq({ offset: 5, length: 3 })
    end
  end
end
