# frozen_string_literal: true

require 'prometheus/client/metric'

module Prometheus
  module Client
    # A native histogram samples observations (usually things like request durations
    # or response sizes) and counts them in automatically-determined buckets.
    # Unlike classic histograms, native histograms use exponential bucketing with
    # sparse storage and automatic resolution adjustment.
    #
    # Native histograms require protobuf format for export as they cannot be
    # represented in the text format.
    #
    # @example
    #   histogram = Prometheus::Client::NativeHistogram.new(
    #     :request_duration_seconds,
    #     docstring: 'Request duration in seconds',
    #     labels: [:method, :path],
    #     schema: 3,
    #     store_settings: { aggregation: :sum }
    #   )
    #   histogram.observe(0.123, labels: { method: 'GET', path: '/users' })
    #
    # @see https://prometheus.io/docs/specs/native_histograms/
    class NativeHistogram < Metric
      # Default schema (-4 to +8)
      # Higher values = more precision, more buckets
      DEFAULT_SCHEMA = 3

      # Default zero threshold (2^-128)
      # Values with |v| <= zero_threshold go to zero bucket
      DEFAULT_ZERO_THRESHOLD = 2.938735877055719e-39

      # Default max buckets before resolution reduction
      DEFAULT_MAX_BUCKETS = 160

      attr_reader :schema, :zero_threshold, :max_buckets

      def initialize(name,
                     docstring:,
                     labels: [],
                     preset_labels: {},
                     schema: nil,
                     zero_threshold: nil,
                     max_buckets: nil,
                     store_settings: {})
        @schema = schema || Prometheus::Client.config.native_histogram_default_schema
        @zero_threshold = zero_threshold || Prometheus::Client.config.native_histogram_default_zero_threshold
        @max_buckets = max_buckets || Prometheus::Client.config.native_histogram_default_max_buckets

        # Pass native histogram settings to the store
        store_settings = store_settings.merge(
          schema: @schema,
          zero_threshold: @zero_threshold,
          max_buckets: @max_buckets
        )

        super(name,
              docstring: docstring,
              labels: labels,
              preset_labels: preset_labels,
              store_settings: store_settings)
      end

      def type
        :native_histogram
      end

      # Record an observation.
      #
      # @param value [Numeric] The value to observe (usually positive, but negative supported)
      # @param labels [Hash] Label name => value pairs
      def observe(value, labels: {})
        label_set = label_set_for(labels)

        @store.synchronize do
          @store.observe(labels: label_set, value: value)
        end
      end

      # Returns histogram data for the given label set.
      #
      # @param labels [Hash] Label name => value pairs
      # @return [Hash] Histogram data with spans and deltas
      def get(labels: {})
        label_set = label_set_for(labels)
        @store.get(labels: label_set)
      end

      # Returns all label sets with their histogram data.
      #
      # @return [Hash<Hash, Hash>] label_set => histogram_data
      def values
        @store.all_values
      end

      def with_labels(labels)
        new_metric = self.class.new(name,
                                    docstring: docstring,
                                    labels: @labels,
                                    preset_labels: preset_labels.merge(labels),
                                    schema: @schema,
                                    zero_threshold: @zero_threshold,
                                    max_buckets: @max_buckets,
                                    store_settings: @store_settings)

        # The new metric needs to use the same store as the "main" declared one
        new_metric.replace_internal_store(@store)

        new_metric
      end

      # Initialize a label set with empty histogram data.
      # This ensures the label set exists even without observations.
      def init_label_set(labels)
        label_set = label_set_for(labels)
        @store.init_label_set(labels: label_set)
      end
    end
  end
end
