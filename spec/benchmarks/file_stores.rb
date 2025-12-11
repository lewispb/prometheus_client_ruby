#!/usr/bin/env ruby
# frozen_string_literal: true

require 'benchmark'
require 'benchmark/ips'
require 'fileutils'
require 'prometheus/client'
require 'prometheus/client/counter'
require 'prometheus/client/gauge'
require 'prometheus/client/histogram'
require 'prometheus/client/summary'
require 'prometheus/client/native_histogram'
require 'prometheus/client/formats/text'
require 'prometheus/client/data_stores/direct_file_store'
require 'prometheus/client/data_stores/mmap_file_store'

# Comprehensive benchmark suite comparing DirectFileStore and MmapFileStore
#
# This benchmark:
# - Tests all metric types: Counter, Gauge, Histogram, Summary, NativeHistogram
# - Simulates multiprocess writing (fork workers)
# - Tests single-process reading (aggregation)
# - Uses at least 500 histograms with 1,000,000 total writes
#
# Run with: bundle exec ruby spec/benchmarks/file_stores.rb

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

RANDOM_SEED = 12345678

# Metric counts
NUM_COUNTERS = 100
NUM_GAUGES = 100
NUM_HISTOGRAMS = 500
NUM_SUMMARIES = 100
NUM_NATIVE_HISTOGRAMS = 100

# Write configuration
TOTAL_WRITES = 1_000_000
MIN_LABELS = 0
MAX_LABELS = 3

# Process configuration
WORKER_COUNTS = [1, 2, 4, 8]

# Directories
DIRECT_STORE_DIR = "/tmp/prometheus_benchmark_direct"
MMAP_STORE_DIR = "/tmp/prometheus_benchmark_mmap"

#------------------------------------------------------------------------------
# Store definitions
#------------------------------------------------------------------------------

def cleanup_dir(dir)
  FileUtils.rm_rf(dir)
  FileUtils.mkdir_p(dir)
end

def create_stores
  [
    {
      name: "DirectFileStore",
      store: -> { Prometheus::Client::DataStores::DirectFileStore.new(dir: DIRECT_STORE_DIR) },
      dir: DIRECT_STORE_DIR,
      supports_native_histograms: false,
    },
    {
      name: "MmapFileStore",
      store: -> { Prometheus::Client::DataStores::MmapFileStore.new(dir: MMAP_STORE_DIR) },
      dir: MMAP_STORE_DIR,
      supports_native_histograms: true,
    }
  ]
end

#------------------------------------------------------------------------------
# Metric Setup
#------------------------------------------------------------------------------

class BenchmarkSetup
  attr_reader :registry, :metrics, :random, :supports_native_histograms

  def initialize(store, seed = RANDOM_SEED, supports_native_histograms: true)
    Prometheus::Client.config.data_store = store
    @random = Random.new(seed)
    @supports_native_histograms = supports_native_histograms
    @registry = Prometheus::Client::Registry.new
    @metrics = {
      counters: [],
      gauges: [],
      histograms: [],
      summaries: [],
      native_histograms: []
    }
    setup_metrics
  end

  def setup_metrics
    NUM_COUNTERS.times do |i|
      labelset = generate_labelset
      counter = Prometheus::Client::Counter.new(
        :"counter_#{i}",
        docstring: "Counter #{i}",
        labels: labelset.keys,
        preset_labels: labelset
      )
      @metrics[:counters] << counter
      @registry.register(counter)
    end

    NUM_GAUGES.times do |i|
      labelset = generate_labelset
      gauge = Prometheus::Client::Gauge.new(
        :"gauge_#{i}",
        docstring: "Gauge #{i}",
        labels: labelset.keys,
        preset_labels: labelset
      )
      @metrics[:gauges] << gauge
      @registry.register(gauge)
    end

    NUM_HISTOGRAMS.times do |i|
      labelset = generate_labelset
      histogram = Prometheus::Client::Histogram.new(
        :"histogram_#{i}",
        docstring: "Histogram #{i}",
        labels: labelset.keys,
        preset_labels: labelset,
        buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
      )
      @metrics[:histograms] << histogram
      @registry.register(histogram)
    end

    NUM_SUMMARIES.times do |i|
      labelset = generate_labelset
      summary = Prometheus::Client::Summary.new(
        :"summary_#{i}",
        docstring: "Summary #{i}",
        labels: labelset.keys,
        preset_labels: labelset
      )
      @metrics[:summaries] << summary
      @registry.register(summary)
    end

    # Native histograms are only supported by MmapFileStore
    if @supports_native_histograms
      NUM_NATIVE_HISTOGRAMS.times do |i|
        labelset = generate_labelset
        native_histogram = Prometheus::Client::NativeHistogram.new(
          :"native_histogram_#{i}",
          docstring: "Native Histogram #{i}",
          labels: labelset.keys,
          preset_labels: labelset,
          schema: 3
        )
        @metrics[:native_histograms] << native_histogram
        @registry.register(native_histogram)
      end
    end
  end

  def generate_labelset
    num_labels = @random.rand(MAX_LABELS - MIN_LABELS + 1) + MIN_LABELS
    (1..num_labels).map { |j| [:"label#{j}", "value#{@random.rand(5)}"] }.to_h
  end

  def all_metrics
    @metrics.values.flatten
  end

  def random_metric
    all_metrics[@random.rand(all_metrics.count)]
  end

  def random_counter
    @metrics[:counters][@random.rand(@metrics[:counters].count)]
  end

  def random_gauge
    @metrics[:gauges][@random.rand(@metrics[:gauges].count)]
  end

  def random_histogram
    @metrics[:histograms][@random.rand(@metrics[:histograms].count)]
  end

  def random_summary
    @metrics[:summaries][@random.rand(@metrics[:summaries].count)]
  end

  def random_native_histogram
    @metrics[:native_histograms][@random.rand(@metrics[:native_histograms].count)]
  end
end

#------------------------------------------------------------------------------
# Single-process write benchmark
#------------------------------------------------------------------------------

def benchmark_single_process_writes(store_config, num_writes)
  cleanup_dir(store_config[:dir])
  store = store_config[:store].call
  setup = BenchmarkSetup.new(store, RANDOM_SEED, supports_native_histograms: store_config[:supports_native_histograms])

  random = Random.new(RANDOM_SEED)

  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  num_writes.times do
    metric = setup.random_metric

    case metric.type
    when :counter
      metric.increment
    when :gauge
      metric.set(random.rand * 100)
    when :histogram
      metric.observe(random.rand * 10)
    when :summary
      metric.observe(random.rand * 10)
    when :native_histogram
      metric.observe(random.rand * 10)
    end
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
  elapsed
end

#------------------------------------------------------------------------------
# Multiprocess write simulation
#------------------------------------------------------------------------------

def benchmark_multiprocess_writes(store_config, num_workers, writes_per_worker)
  cleanup_dir(store_config[:dir])

  # Track child PIDs
  child_pids = []

  # Fork workers
  num_workers.times do |worker_id|
    pid = fork do
      # Child process
      store = store_config[:store].call
      setup = BenchmarkSetup.new(store, RANDOM_SEED + worker_id, supports_native_histograms: store_config[:supports_native_histograms])
      random = Random.new(RANDOM_SEED + worker_id)

      writes_per_worker.times do
        metric = setup.random_metric

        case metric.type
        when :counter
          metric.increment
        when :gauge
          metric.set(random.rand * 100)
        when :histogram
          metric.observe(random.rand * 10)
        when :summary
          metric.observe(random.rand * 10)
        when :native_histogram
          metric.observe(random.rand * 10)
        end
      end

      exit!(0)
    end

    child_pids << pid
  end

  # Wait for all workers
  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  child_pids.each { |pid| Process.wait(pid) }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

  elapsed
end

#------------------------------------------------------------------------------
# Read/Aggregation benchmark
#------------------------------------------------------------------------------

def benchmark_read_aggregation(store_config)
  # Use the aggregator directly (like the exporter would) rather than
  # calling values on each metric, which would re-scan the directory
  # for each metric (N^2 behavior)
  aggregator = Prometheus::Client::DataStores::MmapFileStore::MultiprocessAggregator.new(store_config[:dir])

  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # This is how the exporter should work - aggregate once for all metrics
  aggregator.aggregate_all_counters
  aggregator.aggregate_all_gauges
  aggregator.aggregate_all_histograms
  aggregator.aggregate_all_summaries
  aggregator.aggregate_all_native_histograms if store_config[:supports_native_histograms]

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
  elapsed
end

def benchmark_text_export(store_config)
  store = store_config[:store].call
  setup = BenchmarkSetup.new(store, RANDOM_SEED, supports_native_histograms: store_config[:supports_native_histograms])

  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Export to text format (excludes native histograms)
  output = Prometheus::Client::Formats::Text.marshal(setup.registry)

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
  [elapsed, output.length]
end

#------------------------------------------------------------------------------
# Per-metric-type benchmarks
#------------------------------------------------------------------------------

def benchmark_metric_type_writes(store_config, metric_type, num_writes)
  # Skip native histograms for stores that don't support them
  if metric_type == :native_histogram && !store_config[:supports_native_histograms]
    return nil
  end

  cleanup_dir(store_config[:dir])
  store = store_config[:store].call
  setup = BenchmarkSetup.new(store, RANDOM_SEED, supports_native_histograms: store_config[:supports_native_histograms])

  random = Random.new(RANDOM_SEED)

  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  num_writes.times do
    case metric_type
    when :counter
      setup.random_counter.increment
    when :gauge
      setup.random_gauge.set(random.rand * 100)
    when :histogram
      setup.random_histogram.observe(random.rand * 10)
    when :summary
      setup.random_summary.observe(random.rand * 10)
    when :native_histogram
      setup.random_native_histogram.observe(random.rand * 10)
    end
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
  elapsed
end

#------------------------------------------------------------------------------
# High-throughput benchmark with benchmark-ips
#------------------------------------------------------------------------------

def benchmark_ips_comparison
  puts "\n" + "=" * 80
  puts "Iterations per second comparison (single process, warm cache)"
  puts "=" * 80

  create_stores.each do |store_config|
    puts "\n--- #{store_config[:name]} ---\n"

    cleanup_dir(store_config[:dir])
    store = store_config[:store].call
    setup = BenchmarkSetup.new(store, RANDOM_SEED, supports_native_histograms: store_config[:supports_native_histograms])
    random = Random.new(RANDOM_SEED)

    # Pre-warm: initialize some label sets
    1000.times do
      setup.random_metric.tap do |m|
        case m.type
        when :counter then m.increment
        when :gauge then m.set(1.0)
        when :histogram then m.observe(1.0)
        when :summary then m.observe(1.0)
        when :native_histogram then m.observe(1.0)
        end
      end
    end

    Benchmark.ips do |x|
      x.config(time: 5, warmup: 2)

      x.report("Counter increment") do
        setup.random_counter.increment
      end

      x.report("Gauge set") do
        setup.random_gauge.set(random.rand * 100)
      end

      x.report("Histogram observe") do
        setup.random_histogram.observe(random.rand * 10)
      end

      x.report("Summary observe") do
        setup.random_summary.observe(random.rand * 10)
      end

      if store_config[:supports_native_histograms]
        x.report("NativeHistogram observe") do
          setup.random_native_histogram.observe(random.rand * 10)
        end
      end

      x.compare!
    end
  end
end

#------------------------------------------------------------------------------
# Histogram-focused benchmark (500 histograms, 1M writes)
#------------------------------------------------------------------------------

def benchmark_histograms_intensive
  puts "\n" + "=" * 80
  puts "Histogram-intensive benchmark (#{NUM_HISTOGRAMS} histograms, 1M observations)"
  puts "=" * 80

  results = {}

  create_stores.each do |store_config|
    puts "\n--- #{store_config[:name]} ---"

    # Single process writes
    elapsed = benchmark_metric_type_writes(store_config, :histogram, TOTAL_WRITES)
    ops_per_sec = TOTAL_WRITES / elapsed
    results[store_config[:name]] = { write_time: elapsed, ops_per_sec: ops_per_sec }

    puts format("  Single process: %.2f seconds (%.0f ops/sec)", elapsed, ops_per_sec)

    # Read aggregation
    read_time = benchmark_read_aggregation(store_config)
    results[store_config[:name]][:read_time] = read_time
    puts format("  Read aggregation: %.4f seconds", read_time)
  end

  results
end

#------------------------------------------------------------------------------
# Multiprocess benchmark
#------------------------------------------------------------------------------

def benchmark_multiprocess
  puts "\n" + "=" * 80
  puts "Multiprocess write simulation"
  puts "=" * 80

  create_stores.each do |store_config|
    puts "\n--- #{store_config[:name]} ---"

    WORKER_COUNTS.each do |num_workers|
      writes_per_worker = TOTAL_WRITES / num_workers

      # First, write data with multiple processes
      write_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      benchmark_multiprocess_writes(store_config, num_workers, writes_per_worker)
      write_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - write_start

      # Then read from single process
      read_elapsed = benchmark_read_aggregation(store_config)

      total_writes = num_workers * writes_per_worker
      write_ops_per_sec = total_writes / write_elapsed

      puts format("  %d workers x %d writes: write=%.2fs (%.0f ops/sec), read=%.4fs",
                  num_workers, writes_per_worker, write_elapsed, write_ops_per_sec, read_elapsed)
    end
  end
end

#------------------------------------------------------------------------------
# Per-metric-type comparison
#------------------------------------------------------------------------------

def benchmark_by_metric_type
  puts "\n" + "=" * 80
  puts "Per-metric-type comparison (100K writes each)"
  puts "=" * 80

  metric_types = [:counter, :gauge, :histogram, :summary, :native_histogram]
  writes_per_type = 100_000

  results = {}

  create_stores.each do |store_config|
    puts "\n--- #{store_config[:name]} ---"
    results[store_config[:name]] = {}

    metric_types.each do |metric_type|
      elapsed = benchmark_metric_type_writes(store_config, metric_type, writes_per_type)
      if elapsed.nil?
        puts format("  %-20s: (not supported)", metric_type)
        next
      end

      ops_per_sec = writes_per_type / elapsed
      results[store_config[:name]][metric_type] = { time: elapsed, ops_per_sec: ops_per_sec }

      puts format("  %-20s: %.2f seconds (%8.0f ops/sec)", metric_type, elapsed, ops_per_sec)
    end
  end

  results
end

#------------------------------------------------------------------------------
# Full comparison benchmark
#------------------------------------------------------------------------------

def benchmark_full_comparison
  puts "\n" + "=" * 80
  puts "Full benchmark (all metric types, #{TOTAL_WRITES} total writes)"
  puts "=" * 80

  results = {}

  create_stores.each do |store_config|
    puts "\n--- #{store_config[:name]} ---"

    # Write benchmark
    elapsed = benchmark_single_process_writes(store_config, TOTAL_WRITES)
    ops_per_sec = TOTAL_WRITES / elapsed
    results[store_config[:name]] = { write_time: elapsed, write_ops_per_sec: ops_per_sec }
    puts format("  Write: %.2f seconds (%.0f ops/sec)", elapsed, ops_per_sec)

    # Read aggregation
    read_time = benchmark_read_aggregation(store_config)
    results[store_config[:name]][:read_time] = read_time
    puts format("  Read aggregation: %.4f seconds", read_time)

    # Text export
    export_time, export_size = benchmark_text_export(store_config)
    results[store_config[:name]][:export_time] = export_time
    results[store_config[:name]][:export_size] = export_size
    puts format("  Text export: %.4f seconds (%d bytes)", export_time, export_size)
  end

  results
end

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

if __FILE__ == $0
  puts "Prometheus Client Ruby - File Store Benchmark Suite"
  puts "=" * 80
  puts "Configuration:"
  puts "  Counters:          #{NUM_COUNTERS}"
  puts "  Gauges:            #{NUM_GAUGES}"
  puts "  Histograms:        #{NUM_HISTOGRAMS}"
  puts "  Summaries:         #{NUM_SUMMARIES}"
  puts "  Native Histograms: #{NUM_NATIVE_HISTOGRAMS}"
  puts "  Total writes:      #{TOTAL_WRITES}"
  puts "  Worker counts:     #{WORKER_COUNTS.join(', ')}"
  puts "=" * 80

  # Check if running with specific benchmarks
  if ARGV.empty? || ARGV.include?('--all')
    benchmark_full_comparison
    benchmark_histograms_intensive
    benchmark_by_metric_type
    benchmark_multiprocess
    benchmark_ips_comparison
  else
    benchmark_full_comparison if ARGV.include?('--full')
    benchmark_histograms_intensive if ARGV.include?('--histograms')
    benchmark_by_metric_type if ARGV.include?('--by-type')
    benchmark_multiprocess if ARGV.include?('--multiprocess')
    benchmark_ips_comparison if ARGV.include?('--ips')
  end

  puts "\n" + "=" * 80
  puts "Benchmark complete!"
  puts "=" * 80
end
