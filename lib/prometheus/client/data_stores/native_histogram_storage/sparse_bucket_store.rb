# frozen_string_literal: true

require_relative 'span_delta_codec'

module Prometheus
  module Client
    module DataStores
      module NativeHistogramStorage
        # Efficiently stores histogram observations using sparse bucket representation
        # with file storage (mmap on Ruby 3.4+, traditional I/O otherwise).
        #
        # Native histograms use spans and deltas to represent populated buckets:
        # - Spans: describe which bucket indices have observations (offset + length)
        # - Deltas: delta-encoded counts for consecutive buckets
        #
        # This is more efficient than classic histograms because:
        # - Only populated buckets are stored (sparse)
        # - Delta encoding produces smaller integers (better compression)
        # - No need to pre-allocate all bucket boundaries
        #
        # @see https://prometheus.io/docs/specs/native_histograms/
        class SparseBucketStore
          attr_reader :schema, :zero_threshold, :max_buckets

          # @param file_path [String] Path to storage file
          # @param schema [Integer] Bucket resolution schema (-4 to +8)
          # @param zero_threshold [Float] Values below this go to zero bucket
          # @param max_buckets [Integer] Maximum buckets before resolution reduction
          # @param initial_capacity [Integer] Initial number of buckets for storage
          def initialize(file_path:,
                         schema: Prometheus::Client.config.native_histogram_default_schema,
                         zero_threshold: Prometheus::Client.config.native_histogram_default_zero_threshold,
                         max_buckets: Prometheus::Client.config.native_histogram_default_max_buckets,
                         initial_capacity: 256)
            @schema = schema
            @zero_threshold = zero_threshold
            @max_buckets = max_buckets

            @file_store = create_file_store(
              path: file_path,
              schema: schema,
              zero_threshold: zero_threshold,
              max_buckets: max_buckets,
              initial_capacity: initial_capacity
            )
          end

          # Record an observation.
          #
          # @param value [Numeric] The value to observe
          def observe(value)
            @file_store.observe(value)
          end

          # Flush buffered observations to storage.
          def flush
            @file_store.flush
          end

          # Get current state as hash suitable for protobuf serialization.
          #
          # @return [Hash] Histogram data with spans and deltas
          def to_proto_data
            @file_store.to_proto_data
          end

          # Get timestamp of last observation (for MOST_RECENT aggregation).
          #
          # @return [Float] Monotonic clock timestamp
          def timestamp
            @file_store.timestamp
          end

          # Merge another store's data into this one.
          # Used for multiprocess aggregation.
          #
          # @param other_data [Hash] Data from another SparseBucketStore#to_proto_data
          def merge!(other_data)
            @file_store.merge!(other_data)
          end

          # Reset all observations.
          def reset!
            @file_store.reset!
          end

          # Total number of populated buckets.
          #
          # @return [Integer]
          def bucket_count
            @file_store.bucket_count
          end

          # Close any open resources.
          def close
            @file_store.close
          end

          private

          # Create file store using IO::Buffer-based MmapFileStore.
          # Requires Ruby 3.4+ for IO::Buffer support.
          def create_file_store(path:, schema:, zero_threshold:, max_buckets:, initial_capacity:)
            require_relative 'mmap_file_store'
            MmapFileStore.new(
              path: path,
              schema: schema,
              zero_threshold: zero_threshold,
              max_buckets: max_buckets,
              initial_capacity: initial_capacity
            )
          end
        end
      end
    end
  end
end
