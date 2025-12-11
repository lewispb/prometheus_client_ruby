# frozen_string_literal: true

require_relative 'bucket_calculator'
require_relative 'span_delta_codec'

module Prometheus
  module Client
    module DataStores
      module NativeHistogramStorage
        # Memory-mapped file store with growing capacity for histogram data.
        #
        # Uses Ruby 3.4's IO::Buffer for memory-mapped file access with a growing
        # file strategy. The file is organized as a header followed by bucket data.
        #
        # File layout:
        #   Header (64 bytes):
        #     - magic: 4 bytes (NHST)
        #     - version: 4 bytes
        #     - schema: 4 bytes (signed int32)
        #     - zero_threshold: 8 bytes (float64)
        #     - count: 8 bytes (uint64)
        #     - sum: 8 bytes (float64)
        #     - zero_count: 8 bytes (uint64)
        #     - positive_bucket_count: 4 bytes (uint32)
        #     - negative_bucket_count: 4 bytes (uint32)
        #     - timestamp: 8 bytes (float64) - monotonic clock for MOST_RECENT
        #     - reserved: 4 bytes
        #
        #   Positive buckets (variable):
        #     Each bucket: 12 bytes (4 byte int32 index + 8 byte uint64 count)
        #
        #   Negative buckets (variable):
        #     Each bucket: 12 bytes (4 byte int32 index + 8 byte uint64 count)
        #
        # @see https://prometheus.io/docs/specs/native_histograms/
        class MmapFileStore
          MAGIC = "NHST"
          VERSION = 1
          HEADER_SIZE = 64
          BUCKET_SIZE = 12 # 4 bytes index + 8 bytes count
          INITIAL_CAPACITY = 256 # Initial number of buckets per side
          GROWTH_FACTOR = 2
          TIMESTAMP_OFFSET = 52

          class Error < StandardError; end
          class CorruptedFileError < Error; end
          class CapacityError < Error; end

          attr_reader :path, :schema, :zero_threshold, :max_buckets

          # @param path [String] Path to the mmap file
          # @param schema [Integer] Bucket resolution schema (-4 to +8)
          # @param zero_threshold [Float] Values below this go to zero bucket
          # @param max_buckets [Integer] Maximum buckets before resolution reduction
          # @param initial_capacity [Integer] Initial number of buckets to allocate per side
          def initialize(path:,
                         schema: Prometheus::Client.config.native_histogram_default_schema,
                         zero_threshold: Prometheus::Client.config.native_histogram_default_zero_threshold,
                         max_buckets: Prometheus::Client.config.native_histogram_default_max_buckets,
                         initial_capacity: INITIAL_CAPACITY)
            @path = path
            @schema = schema
            @zero_threshold = zero_threshold
            @max_buckets = max_buckets
            @initial_capacity = initial_capacity
            @calculator = BucketCalculator.new(schema)

            # File and mmap state
            @file = nil
            @mmap = nil
            @file_mutex = Mutex.new
            @capacity = 0

            initialize_file
          end

          # Record an observation.
          #
          # Writes directly to mmap for immediate multiprocess visibility.
          #
          # @param value [Numeric] The value to observe
          def observe(value)
            value = value.to_f

            @file_mutex.synchronize do
              # Update count and sum
              write_u64(20, read_u64(20) + 1)
              write_f64(28, read_f64(28) + value)

              # Update timestamp for MOST_RECENT aggregation
              write_f64(TIMESTAMP_OFFSET, Process.clock_gettime(Process::CLOCK_MONOTONIC))

              # Determine bucket
              if value.abs <= @zero_threshold
                write_u64(36, read_u64(36) + 1)
              else
                bucket_info = @calculator.bucket_index(value)
                if bucket_info
                  sign, index = bucket_info
                  increment_bucket(sign == :positive ? :positive : :negative, index)
                end
              end

              maybe_reduce_resolution!
            end
          end

          # Flush is now a no-op since we write directly to mmap.
          # Kept for API compatibility.
          def flush
            # No-op - writes go directly to mmap
          end

          # Get current state as hash suitable for protobuf serialization.
          #
          # @return [Hash] Histogram data with spans and deltas
          def to_proto_data
            flush

            @file_mutex.synchronize do
              read_proto_data_from_mmap
            end
          end

          # Get timestamp of last observation (for MOST_RECENT aggregation).
          #
          # @return [Float] Monotonic clock timestamp
          def timestamp
            @file_mutex.synchronize do
              read_f64(TIMESTAMP_OFFSET)
            end
          end

          # Merge another store's data into this one.
          # Used for multiprocess aggregation.
          #
          # @param other_data [Hash] Data from another store's to_proto_data
          def merge!(other_data)
            flush

            @file_mutex.synchronize do
              merge_data_into_mmap(other_data)
            end
          end

          # Reset all observations.
          def reset!
            @file_mutex.synchronize do
              reset_mmap_data
            end
          end

          # Total number of populated buckets.
          #
          # @return [Integer]
          def bucket_count
            flush

            @file_mutex.synchronize do
              read_u32(44) + read_u32(48) # positive + negative counts
            end
          end

          # Close the mmap and file handles.
          def close
            flush
            @file_mutex.synchronize do
              @mmap = nil
              @file&.close
              @file = nil
            end
          end

          private

          # Initialize or open the mmap file.
          def initialize_file
            @file_mutex.synchronize do
              if File.exist?(@path)
                open_existing_file
              else
                create_new_file
              end
            end
          end

          def create_new_file
            @capacity = @initial_capacity
            file_size = calculate_file_size(@capacity)

            FileUtils.mkdir_p(File.dirname(@path))
            @file = File.open(@path, "w+b")
            @file.truncate(file_size)
            @file.flush

            @mmap = IO::Buffer.map(@file, file_size, 0, IO::Buffer::SHARED)

            write_header
          end

          def open_existing_file
            @file = File.open(@path, "r+b")
            file_size = @file.size

            raise CorruptedFileError, "File too small for header" if file_size < HEADER_SIZE

            @mmap = IO::Buffer.map(@file, file_size, 0, IO::Buffer::SHARED)

            validate_header
            @capacity = (file_size - HEADER_SIZE) / (2 * BUCKET_SIZE)
          end

          def calculate_file_size(capacity)
            HEADER_SIZE + (capacity * 2 * BUCKET_SIZE)
          end

          def write_header
            # Magic - use copy with a buffer for string data
            magic_buf = IO::Buffer.for(MAGIC)
            @mmap.copy(magic_buf, 0)
            # Version
            write_u32(4, VERSION)
            # Schema
            write_i32(8, @schema)
            # Zero threshold
            write_f64(12, @zero_threshold)
            # Count
            write_u64(20, 0)
            # Sum
            write_f64(28, 0.0)
            # Zero count
            write_u64(36, 0)
            # Positive bucket count
            write_u32(44, 0)
            # Negative bucket count
            write_u32(48, 0)
            # Timestamp
            write_f64(TIMESTAMP_OFFSET, 0.0)
            # Reserved bytes are zero-initialized
          end

          def validate_header
            # Read magic bytes into a string
            magic = @mmap.get_string(0, 4, Encoding::BINARY)
            raise CorruptedFileError, "Invalid magic: #{magic.inspect}" unless magic == MAGIC

            version = read_u32(4)
            raise CorruptedFileError, "Unsupported version: #{version}" unless version == VERSION

            file_schema = read_i32(8)
            if file_schema != @schema
              # Update schema from file
              @schema = file_schema
              @calculator = BucketCalculator.new(@schema)
            end

            @zero_threshold = read_f64(12)
          end

          def increment_bucket(side, bucket_index)
            count_offset = side == :positive ? 44 : 48
            bucket_count = read_u32(count_offset)
            offset = bucket_offset(side)

            # Search for existing bucket
            bucket_count.times do |i|
              pos = offset + (i * BUCKET_SIZE)
              idx = read_i32(pos)
              if idx == bucket_index
                # Found - increment and return
                write_u64(pos + 4, read_u64(pos + 4) + 1)
                return
              end
            end

            # Not found - add new bucket
            ensure_capacity!(bucket_count + 1, side)
            # Re-read offset after potential resize
            offset = bucket_offset(side)
            pos = offset + (bucket_count * BUCKET_SIZE)
            write_i32(pos, bucket_index)
            write_u64(pos + 4, 1)
            write_u32(count_offset, bucket_count + 1)
          end

          def merge_buckets(side, new_buckets)
            return if new_buckets.empty?

            existing = read_buckets(side)

            new_buckets.each do |index, count|
              existing[index] ||= 0
              existing[index] += count
            end

            ensure_capacity!(existing.size, side)
            write_buckets(side, existing)
          end

          def read_buckets(side)
            count_offset = side == :positive ? 44 : 48
            bucket_count = read_u32(count_offset)
            return {} if bucket_count.zero?

            offset = bucket_offset(side)
            buckets = {}

            bucket_count.times do |i|
              pos = offset + (i * BUCKET_SIZE)
              index = read_i32(pos)
              value = read_u64(pos + 4)
              buckets[index] = value if value.positive?
            end

            buckets
          end

          def write_buckets(side, buckets)
            sorted = buckets.sort_by { |idx, _| idx }
            count_offset = side == :positive ? 44 : 48
            offset = bucket_offset(side)

            write_u32(count_offset, sorted.size)

            sorted.each_with_index do |(index, value), i|
              pos = offset + (i * BUCKET_SIZE)
              write_i32(pos, index)
              write_u64(pos + 4, value)
            end
          end

          def bucket_offset(side)
            if side == :positive
              HEADER_SIZE
            else
              HEADER_SIZE + (@capacity * BUCKET_SIZE)
            end
          end

          def ensure_capacity!(needed, _side)
            return if needed <= @capacity

            new_capacity = @capacity
            new_capacity *= GROWTH_FACTOR while new_capacity < needed

            grow_file(new_capacity)
          end

          def grow_file(new_capacity)
            # Read existing data before growing
            pos_buckets = read_buckets(:positive)
            neg_buckets = read_buckets(:negative)
            header_data = read_header_data

            # Unmap and resize
            @mmap = nil
            new_size = calculate_file_size(new_capacity)
            @file.truncate(new_size)
            @file.flush

            # Remap
            @mmap = IO::Buffer.map(@file, new_size, 0, IO::Buffer::SHARED)
            @capacity = new_capacity

            # Restore header
            write_header_data(header_data)

            # Rewrite buckets at new positions
            write_buckets(:positive, pos_buckets)
            write_buckets(:negative, neg_buckets)
          end

          def read_header_data
            {
              count: read_u64(20),
              sum: read_f64(28),
              zero_count: read_u64(36),
              timestamp: read_f64(TIMESTAMP_OFFSET)
            }
          end

          def write_header_data(data)
            write_u64(20, data[:count])
            write_f64(28, data[:sum])
            write_u64(36, data[:zero_count])
            write_f64(TIMESTAMP_OFFSET, data[:timestamp])
          end

          def read_proto_data_from_mmap
            pos_buckets = read_buckets(:positive)
            neg_buckets = read_buckets(:negative)

            pos_spans, pos_deltas = SpanDeltaCodec.encode(pos_buckets)
            neg_spans, neg_deltas = SpanDeltaCodec.encode(neg_buckets)

            {
              sample_count: read_u64(20),
              sample_sum: read_f64(28),
              schema: @schema,
              zero_threshold: @zero_threshold,
              zero_count: read_u64(36),
              positive_spans: pos_spans,
              positive_deltas: pos_deltas,
              negative_spans: neg_spans,
              negative_deltas: neg_deltas,
              timestamp: read_f64(TIMESTAMP_OFFSET)
            }
          end

          def merge_data_into_mmap(other_data)
            # Update scalar values
            write_u64(20, read_u64(20) + other_data[:sample_count])
            write_f64(28, read_f64(28) + other_data[:sample_sum])
            write_u64(36, read_u64(36) + other_data[:zero_count])

            # Expand and merge positive buckets
            other_positive = SpanDeltaCodec.decode(
              other_data[:positive_spans],
              other_data[:positive_deltas]
            )
            merge_buckets(:positive, other_positive)

            # Expand and merge negative buckets
            other_negative = SpanDeltaCodec.decode(
              other_data[:negative_spans],
              other_data[:negative_deltas]
            )
            merge_buckets(:negative, other_negative)
          end

          def reset_mmap_data
            write_u64(20, 0)
            write_f64(28, 0.0)
            write_u64(36, 0)
            write_u32(44, 0)
            write_u32(48, 0)
            write_f64(TIMESTAMP_OFFSET, 0.0)
          end

          def maybe_reduce_resolution!
            total_buckets = read_u32(44) + read_u32(48)

            while total_buckets > @max_buckets && @schema > -4
              @schema -= 1
              @calculator = BucketCalculator.new(@schema)
              write_i32(8, @schema)

              merge_adjacent_buckets!(:positive)
              merge_adjacent_buckets!(:negative)

              total_buckets = read_u32(44) + read_u32(48)
            end
          end

          def merge_adjacent_buckets!(side)
            buckets = read_buckets(side)
            return if buckets.empty?

            new_buckets = Hash.new(0)
            buckets.each do |old_index, count|
              new_index = BucketCalculator.merge_index(old_index)
              new_buckets[new_index] += count
            end

            write_buckets(side, new_buckets)
          end

          # IO::Buffer read/write helpers
          def read_u32(offset)
            @mmap.get_value(:U32, offset)
          end

          def write_u32(offset, value)
            @mmap.set_value(:U32, offset, value)
          end

          def read_i32(offset)
            @mmap.get_value(:S32, offset)
          end

          def write_i32(offset, value)
            @mmap.set_value(:S32, offset, value)
          end

          def read_u64(offset)
            @mmap.get_value(:U64, offset)
          end

          def write_u64(offset, value)
            @mmap.set_value(:U64, offset, value)
          end

          def read_f64(offset)
            @mmap.get_value(:F64, offset)
          end

          def write_f64(offset, value)
            @mmap.set_value(:F64, offset, value)
          end
        end
      end
    end
  end
end
