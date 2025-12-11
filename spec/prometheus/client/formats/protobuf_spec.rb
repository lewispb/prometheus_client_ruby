# frozen_string_literal: true

require 'fileutils'
require 'prometheus/client'
require 'prometheus/client/formats/protobuf'
require 'prometheus/client/data_stores/mmap_file_store'

RSpec.describe Prometheus::Client::Formats::Protobuf do
  let(:dir) { '/tmp/prometheus_protobuf_spec' }

  before do
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    Prometheus::Client.config.data_store = Prometheus::Client::DataStores::MmapFileStore.new(dir: dir)
  end

  after do
    FileUtils.rm_rf(dir)
  end

  let(:registry) { Prometheus::Client::Registry.new }

  describe '.marshal' do
    it 'returns binary string' do
      counter = registry.counter(:test_counter, docstring: 'Test counter')
      counter.increment

      output = described_class.marshal(registry)
      expect(output).to be_a(String)
      expect(output.encoding).to eq(Encoding::BINARY)
    end

    it 'serializes counter metrics' do
      counter = registry.counter(:test_counter, docstring: 'Test counter')
      counter.increment(by: 5)

      output = described_class.marshal(registry)
      expect(output.bytesize).to be > 0

      # Decode and verify
      family = decode_first_family(output)
      expect(family.name).to eq('test_counter')
      expect(family.type).to eq(:COUNTER)
      expect(family.metric.first.counter.value).to eq(5.0)
    end

    it 'serializes gauge metrics' do
      gauge = registry.gauge(:test_gauge, docstring: 'Test gauge')
      gauge.set(42.0)

      output = described_class.marshal(registry)
      family = decode_first_family(output)

      expect(family.name).to eq('test_gauge')
      expect(family.type).to eq(:GAUGE)
      expect(family.metric.first.gauge.value).to eq(42.0)
    end

    it 'serializes histogram metrics' do
      histogram = registry.histogram(:test_histogram, docstring: 'Test', buckets: [1, 5, 10])
      histogram.observe(3)
      histogram.observe(7)

      output = described_class.marshal(registry)
      family = decode_first_family(output)

      expect(family.name).to eq('test_histogram')
      expect(family.type).to eq(:HISTOGRAM)
      expect(family.metric.first.histogram.sample_count).to eq(2)
      expect(family.metric.first.histogram.sample_sum).to eq(10.0)
    end

    it 'serializes summary metrics' do
      summary = registry.summary(:test_summary, docstring: 'Test')
      summary.observe(1.0)
      summary.observe(2.0)

      output = described_class.marshal(registry)
      family = decode_first_family(output)

      expect(family.name).to eq('test_summary')
      expect(family.type).to eq(:SUMMARY)
      expect(family.metric.first.summary.sample_count).to eq(2)
      expect(family.metric.first.summary.sample_sum).to eq(3.0)
    end

    it 'serializes native histogram metrics' do
      histogram = registry.native_histogram(:test_native, docstring: 'Test')
      histogram.observe(1.0)
      histogram.observe(2.0)

      output = described_class.marshal(registry)
      family = decode_first_family(output)

      expect(family.name).to eq('test_native')
      expect(family.type).to eq(:HISTOGRAM)
      expect(family.metric.first.histogram.sample_count).to eq(2)
      expect(family.metric.first.histogram.sample_sum).to eq(3.0)
      expect(family.metric.first.histogram.schema).to eq(3)
      expect(family.metric.first.histogram.positive_span).not_to be_empty
    end

    it 'includes labels' do
      counter = registry.counter(:test_counter, docstring: 'Test', labels: [:method])
      counter.increment(labels: { method: 'GET' })

      output = described_class.marshal(registry)
      family = decode_first_family(output)

      labels = family.metric.first.label
      expect(labels.length).to eq(1)
      expect(labels.first.name).to eq('method')
      expect(labels.first.value).to eq('GET')
    end

    it 'serializes multiple metrics' do
      registry.counter(:counter1, docstring: 'C1').increment
      registry.counter(:counter2, docstring: 'C2').increment
      registry.gauge(:gauge1, docstring: 'G1').set(10)

      output = described_class.marshal(registry)

      families = decode_all_families(output)
      names = families.map(&:name)

      expect(names).to contain_exactly('counter1', 'counter2', 'gauge1')
    end
  end

  describe 'CONTENT_TYPE' do
    it 'is the protobuf content type' do
      expect(described_class::CONTENT_TYPE).to include('application/vnd.google.protobuf')
      expect(described_class::CONTENT_TYPE).to include('proto=io.prometheus.client.MetricFamily')
      expect(described_class::CONTENT_TYPE).to include('encoding=delimited')
    end
  end

  private

  def decode_first_family(output)
    decode_all_families(output).first
  end

  def decode_all_families(output)
    families = []
    pos = 0

    while pos < output.bytesize
      len, bytes_read = read_varint(output, pos)
      pos += bytes_read
      break if pos + len > output.bytesize

      family = Io::Prometheus::Client::MetricFamily.decode(output[pos, len])
      families << family
      pos += len
    end

    families
  end

  def read_varint(data, start_pos)
    len = 0
    shift = 0
    pos = start_pos

    loop do
      byte = data.getbyte(pos)
      pos += 1
      len |= (byte & 0x7F) << shift
      break if (byte & 0x80).zero?
      shift += 7
    end

    [len, pos - start_pos]
  end
end
