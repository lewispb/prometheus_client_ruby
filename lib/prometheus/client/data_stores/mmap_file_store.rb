# frozen_string_literal: true

require 'fileutils'
require 'prometheus/client/support/pid_provider'
require 'prometheus/client/support/label_encoder'

module Prometheus
  module Client
    module DataStores
      # Stores metric data in mmap files using Ruby's IO::Buffer (Ruby 3.1+).
      #
      # This is a multiprocess-safe data store that uses memory-mapped files
      # for efficient cross-process metric aggregation. Each process writes
      # to its own file, and metrics are aggregated at scrape time.
      #
      # Supports all metric types:
      # - Counters (.counter files) - summed across processes
      # - Gauges (.gauge files) - configurable aggregation (sum, min, max, all, most_recent)
      # - Histograms (.histogram files) - classic histograms with fixed buckets
      # - Native Histograms (.mmap files) - exponential bucket histograms for protobuf export
      #
      # File naming: {metric_name}__{label_key}_{label_value}__...__{worker_id}.{ext}
      #
      # @example
      #   Prometheus::Client.config.data_store = Prometheus::Client::DataStores::MmapFileStore.new(
      #     dir: '/tmp/prometheus-metrics'
      #   )
      #
      class MmapFileStore
        class InvalidStoreSettingsError < StandardError; end

        AGGREGATION_MODES = [MAX = :max, MIN = :min, SUM = :sum, ALL = :all, MOST_RECENT = :most_recent].freeze
        DEFAULT_METRIC_SETTINGS = { aggregation: SUM }.freeze
        DEFAULT_GAUGE_SETTINGS = { aggregation: ALL }.freeze

        def initialize(dir:)
          @store_settings = { dir: dir }
          FileUtils.mkdir_p(dir)
        end

        def for_metric(metric_name, metric_type:, metric_settings: {})
          case metric_type
          when :counter
            settings = DEFAULT_METRIC_SETTINGS.merge(metric_settings)
            validate_metric_settings(metric_type, settings)
            CounterStore.new(
              metric_name: metric_name,
              store_settings: @store_settings,
              metric_settings: settings
            )
          when :gauge
            settings = DEFAULT_GAUGE_SETTINGS.merge(metric_settings)
            validate_metric_settings(metric_type, settings)
            GaugeStore.new(
              metric_name: metric_name,
              store_settings: @store_settings,
              metric_settings: settings
            )
          when :histogram
            settings = DEFAULT_METRIC_SETTINGS.merge(metric_settings)
            validate_metric_settings(metric_type, settings)
            HistogramStore.new(
              metric_name: metric_name,
              store_settings: @store_settings,
              metric_settings: settings
            )
          when :summary
            settings = DEFAULT_METRIC_SETTINGS.merge(metric_settings)
            validate_metric_settings(metric_type, settings)
            SummaryStore.new(
              metric_name: metric_name,
              store_settings: @store_settings,
              metric_settings: settings
            )
          when :native_histogram
            settings = { aggregation: SUM }.merge(metric_settings)
            validate_native_histogram_settings(settings)
            NativeHistogramStore.new(
              metric_name: metric_name,
              store_settings: @store_settings,
              metric_settings: settings
            )
          else
            raise InvalidStoreSettingsError, "Unknown metric type: #{metric_type}"
          end
        end

        private

        def validate_metric_settings(metric_type, settings)
          unless settings.key?(:aggregation) && AGGREGATION_MODES.include?(settings[:aggregation])
            raise InvalidStoreSettingsError, "Metrics need a valid :aggregation key"
          end

          if settings[:aggregation] == MOST_RECENT && metric_type != :gauge
            raise InvalidStoreSettingsError, "Only :gauge metrics support :most_recent aggregation"
          end
        end

        def validate_native_histogram_settings(settings)
          unless settings.key?(:aggregation) && AGGREGATION_MODES.include?(settings[:aggregation])
            raise InvalidStoreSettingsError, "Metrics need a valid :aggregation key"
          end

          valid_keys = [:aggregation, :schema, :zero_threshold, :max_buckets]
          extra_keys = settings.keys - valid_keys
          unless extra_keys.empty?
            raise InvalidStoreSettingsError, "Unknown settings: #{extra_keys.join(', ')}"
          end
        end
      end
    end
  end
end

# Load the individual store implementations
require_relative 'mmap/counter_store'
require_relative 'mmap/gauge_store'
require_relative 'mmap/histogram_store'
require_relative 'mmap/summary_store'
require_relative 'mmap/native_histogram_store'
require_relative 'mmap/multiprocess_aggregator'
