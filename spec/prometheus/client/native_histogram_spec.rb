# frozen_string_literal: true

require 'fileutils'
require 'prometheus/client'
require 'prometheus/client/native_histogram'
require 'prometheus/client/data_stores/mmap_file_store'

RSpec.describe Prometheus::Client::NativeHistogram do
  let(:dir) { '/tmp/prometheus_native_histogram_spec' }

  before do
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    Prometheus::Client.config.data_store = Prometheus::Client::DataStores::MmapFileStore.new(dir: dir)
  end

  after do
    FileUtils.rm_rf(dir)
  end

  let(:histogram) do
    described_class.new(:test_histogram, docstring: 'Test histogram')
  end

  describe '#initialize' do
    it 'creates a native histogram with default settings' do
      h = described_class.new(:test, docstring: 'Test')
      expect(h.name).to eq(:test)
      expect(h.type).to eq(:native_histogram)
    end

    it 'accepts custom schema' do
      h = described_class.new(:test, docstring: 'Test', schema: 5)
      expect(h).to be_a(described_class)
    end

    it 'accepts custom zero_threshold' do
      h = described_class.new(:test, docstring: 'Test', zero_threshold: 0.001)
      expect(h).to be_a(described_class)
    end

    it 'accepts custom max_buckets' do
      h = described_class.new(:test, docstring: 'Test', max_buckets: 50)
      expect(h).to be_a(described_class)
    end

    it 'accepts labels' do
      h = described_class.new(:test, docstring: 'Test', labels: [:method])
      expect(h.labels).to eq([:method])
    end
  end

  describe '#type' do
    it 'returns :native_histogram' do
      expect(histogram.type).to eq(:native_histogram)
    end
  end

  describe '#observe' do
    it 'records observations' do
      histogram.observe(1.0)
      histogram.observe(2.0)

      data = histogram.get
      expect(data[:sample_count]).to eq(2)
      expect(data[:sample_sum]).to eq(3.0)
    end

    it 'accepts labels' do
      h = described_class.new(:test, docstring: 'Test', labels: [:method])
      h.observe(1.0, labels: { method: 'GET' })
      h.observe(2.0, labels: { method: 'POST' })

      expect(h.get(labels: { method: 'GET' })[:sample_count]).to eq(1)
      expect(h.get(labels: { method: 'POST' })[:sample_count]).to eq(1)
    end

    it 'tracks positive values in positive buckets' do
      histogram.observe(1.5)
      data = histogram.get
      expect(data[:positive_spans]).not_to be_empty
    end

    it 'tracks negative values in negative buckets' do
      histogram.observe(-1.5)
      data = histogram.get
      expect(data[:negative_spans]).not_to be_empty
    end

    it 'tracks zero values in zero bucket' do
      histogram.observe(0.0)
      data = histogram.get
      expect(data[:zero_count]).to eq(1)
    end
  end

  describe '#get' do
    it 'returns proto-compatible data structure' do
      histogram.observe(1.0)
      data = histogram.get

      expect(data).to include(
        :sample_count,
        :sample_sum,
        :schema,
        :zero_threshold,
        :zero_count,
        :positive_spans,
        :positive_deltas,
        :negative_spans,
        :negative_deltas
      )
    end

    it 'returns empty data for unobserved histogram' do
      data = histogram.get
      expect(data[:sample_count]).to eq(0)
      expect(data[:sample_sum]).to eq(0.0)
    end
  end

  describe '#values' do
    it 'returns all label sets with their data' do
      h = described_class.new(:test, docstring: 'Test', labels: [:method])
      h.observe(1.0, labels: { method: 'GET' })
      h.observe(2.0, labels: { method: 'POST' })

      values = h.values
      expect(values.keys).to contain_exactly({ method: 'GET' }, { method: 'POST' })
    end
  end

  describe '#with_labels' do
    it 'creates a new histogram with preset labels' do
      h = described_class.new(:test, docstring: 'Test', labels: [:method, :path])
      preset = h.with_labels(method: 'GET')

      preset.observe(1.0, labels: { path: '/users' })

      data = h.get(labels: { method: 'GET', path: '/users' })
      expect(data[:sample_count]).to eq(1)
    end
  end
end
