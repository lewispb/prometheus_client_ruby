# frozen_string_literal: true

require 'fileutils'
require 'prometheus/client'
require 'prometheus/client/data_stores/mmap_file_store'

RSpec.describe Prometheus::Client::DataStores::MmapFileStore do
  let(:dir) { '/tmp/prometheus_mmap_store_spec' }

  before do
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
  end

  after do
    FileUtils.rm_rf(dir)
  end

  let(:store) { described_class.new(dir: dir) }

  before do
    Prometheus::Client.config.data_store = store
  end

  describe '#for_metric' do
    it 'returns a counter store for counter metrics' do
      metric_store = store.for_metric(:test_counter, metric_type: :counter, metric_settings: {})
      expect(metric_store).to be_a(described_class::CounterStore)
    end

    it 'returns a gauge store for gauge metrics' do
      metric_store = store.for_metric(:test_gauge, metric_type: :gauge, metric_settings: {})
      expect(metric_store).to be_a(described_class::GaugeStore)
    end

    it 'returns a histogram store for histogram metrics' do
      metric_store = store.for_metric(:test_histogram, metric_type: :histogram, metric_settings: {})
      expect(metric_store).to be_a(described_class::HistogramStore)
    end

    it 'returns a summary store for summary metrics' do
      metric_store = store.for_metric(:test_summary, metric_type: :summary, metric_settings: {})
      expect(metric_store).to be_a(described_class::SummaryStore)
    end

    it 'returns a native histogram store for native_histogram metrics' do
      metric_store = store.for_metric(:test_native, metric_type: :native_histogram, metric_settings: {})
      expect(metric_store).to be_a(described_class::NativeHistogramStore)
    end
  end

  describe 'counter operations' do
    let(:counter) do
      Prometheus::Client::Counter.new(:test_counter, docstring: 'Test counter')
    end

    it 'increments and reads counter values' do
      counter.increment(by: 5)
      expect(counter.get).to eq(5.0)

      counter.increment(by: 3)
      expect(counter.get).to eq(8.0)
    end

    it 'creates mmap files' do
      counter.increment
      files = Dir.glob(File.join(dir, '*.counter'))
      expect(files.length).to eq(1)
    end

    it 'supports labels with underscores' do
      c = Prometheus::Client::Counter.new(:api_requests, docstring: 'Test', labels: [:http_method])
      c.increment(labels: { http_method: 'GET' })

      expect(c.get(labels: { http_method: 'GET' })).to eq(1.0)
      expect(c.values).to eq({ { http_method: 'GET' } => 1.0 })
    end
  end

  describe 'gauge operations' do
    let(:gauge) do
      Prometheus::Client::Gauge.new(:test_gauge, docstring: 'Test gauge')
    end

    it 'sets and reads gauge values' do
      gauge.set(42.0)
      expect(gauge.get).to eq(42.0)
    end

    it 'increments gauge values' do
      gauge.set(10.0)
      gauge.increment(by: 5)
      expect(gauge.get).to eq(15.0)
    end
  end

  describe 'native histogram operations' do
    let(:histogram) do
      Prometheus::Client::NativeHistogram.new(:test_histogram, docstring: 'Test histogram')
    end

    it 'observes and reads histogram values' do
      histogram.observe(1.0)
      histogram.observe(2.0)

      data = histogram.get
      expect(data[:sample_count]).to eq(2)
      expect(data[:sample_sum]).to eq(3.0)
    end

    it 'creates mmap files' do
      histogram.observe(1.0)
      files = Dir.glob(File.join(dir, '*.mmap'))
      expect(files.length).to eq(1)
    end
  end

  describe 'multiprocess aggregation' do
    it 'aggregates counter values from multiple files' do
      counter = Prometheus::Client::Counter.new(:test_counter, docstring: 'Test')
      counter.increment(by: 10)

      # Simulate another process by creating another file
      # IO::Buffer uses big-endian for :F64 on this platform
      other_file = File.join(dir, 'test_counter__default__other_pid.counter')
      File.open(other_file, 'wb') do |f|
        f.truncate(16)
        f.write("CNTR")
        f.write([1].pack('N'))   # version (big-endian uint32)
        f.write([5.0].pack('G')) # value (big-endian double)
      end

      expect(counter.values).to eq({ {} => 15.0 })
    end
  end

  describe 'thread safety' do
    let(:counter) do
      Prometheus::Client::Counter.new(:thread_test, docstring: 'Thread test')
    end

    it 'handles concurrent increments correctly' do
      threads = 10.times.map do
        Thread.new { 100.times { counter.increment } }
      end
      threads.each(&:join)

      expect(counter.get).to eq(1000.0)
    end
  end
end
