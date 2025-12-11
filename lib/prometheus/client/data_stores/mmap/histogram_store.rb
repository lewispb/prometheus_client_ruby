# frozen_string_literal: true

module Prometheus
  module Client
    module DataStores
      class MmapFileStore
        # Mmap-backed store for classic histogram metrics.
        #
        # Classic histograms use fixed buckets and store bucket counts.
        # Each bucket is stored as a separate value with the :le label.
        #
        # This store delegates to a single file per label set (excluding :le),
        # with all buckets stored within that file.
        #
        # File format:
        #   - magic: 4 bytes ("HIST")
        #   - version: 4 bytes (uint32)
        #   - bucket_count: 4 bytes (uint32)
        #   - padding: 4 bytes
        #   - buckets: array of (key_len: 4, key: padded string, value: 8 bytes float64, timestamp: 8 bytes float64)
        #
        class HistogramStore
          MAGIC = "HIST"
          VERSION = 1
          HEADER_SIZE = 16
          INITIAL_FILE_SIZE = 4096

          attr_reader :metric_name, :store_settings

          def initialize(metric_name:, store_settings:, metric_settings:)
            @metric_name = metric_name
            @store_settings = store_settings
            @metric_settings = metric_settings
            @values_aggregation_mode = metric_settings[:aggregation]

            @stores = {}
            @store_opened_by_pid = nil
            @lock = Monitor.new
          end

          def synchronize
            @lock.synchronize { yield }
          end

          def set(labels:, val:)
            @lock.synchronize do
              base_labels = labels.reject { |k, _| k == :le }
              le = labels[:le]

              store_for(base_labels).set(le, val.to_f)
            end
          end

          def increment(labels:, by: 1)
            @lock.synchronize do
              base_labels = labels.reject { |k, _| k == :le }
              le = labels[:le]

              store_for(base_labels).increment(le, by.to_f)
            end
          end

          def get(labels:)
            @lock.synchronize do
              base_labels = labels.reject { |k, _| k == :le }
              le = labels[:le]
              key = store_key(base_labels)

              store = @stores[key]
              return 0.0 unless store

              store.get(le) || 0.0
            end
          end

          def all_values
            aggregator = MultiprocessAggregator.new(@store_settings[:dir])
            histograms = aggregator.aggregate_all_histograms

            # The aggregator returns {metric_name => {base_labels => {le => value}}}
            # We need to flatten to {labels_with_le => value}
            result = {}
            (histograms[@metric_name] || {}).each do |base_labels, bucket_values|
              bucket_values.each do |le, value|
                full_labels = base_labels.merge(le: le)
                result[full_labels] = value
              end
            end

            result
          end

          private

          def store_for(base_labels)
            key = store_key(base_labels)

            # Handle process forking - reopen stores if PID changed
            current_pid = worker_pid
            if @store_opened_by_pid != current_pid
              @stores.each_value(&:close)
              @stores.clear
              @store_opened_by_pid = current_pid
            end

            @stores[key] ||= create_store(key, base_labels)
          end

          def create_store(key, base_labels)
            filename = generate_filename(base_labels)
            file_path = File.join(@store_settings[:dir], filename)
            MmapHistogram.new(file_path)
          end

          def store_key(base_labels)
            base_labels.to_a.sort.map { |k, v| "#{k}=#{v}" }.join("&")
          end

          def generate_filename(base_labels)
            label_part = Support::LabelEncoder.encode_labels(base_labels)
            metric_part = Support::LabelEncoder.encode(@metric_name)

            "#{metric_part}__#{label_part}__#{worker_pid}.histogram"
          end

          def worker_pid
            Support::PidProvider.worker_pid
          end
        end

        # Single mmap file for histogram bucket values.
        # Stores multiple key-value pairs (bucket => count).
        class MmapHistogram
          def initialize(path)
            @path = path
            @file = nil
            @mmap = nil
            @positions = {}
            @used = 0
            @capacity = 0
            @mutex = Mutex.new

            initialize_file
          end

          def set(key, value)
            @mutex.synchronize do
              ensure_key(key)
              pos = @positions[key]
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              @mmap.set_value(:F64, pos, value)
              @mmap.set_value(:F64, pos + 8, now)
            end
          end

          def increment(key, by)
            @mutex.synchronize do
              ensure_key(key)
              pos = @positions[key]
              current = @mmap.get_value(:F64, pos)
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              @mmap.set_value(:F64, pos, current + by)
              @mmap.set_value(:F64, pos + 8, now)
            end
          end

          def get(key)
            @mutex.synchronize do
              pos = @positions[key]
              return nil unless pos

              @mmap.get_value(:F64, pos)
            end
          end

          def all_values
            @mutex.synchronize do
              @positions.transform_values do |pos|
                @mmap.get_value(:F64, pos)
              end
            end
          end

          def close
            @mutex.synchronize do
              @mmap = nil
              @file&.close
              @file = nil
            end
          end

          private

          def initialize_file
            @mutex.synchronize do
              if File.exist?(@path)
                open_existing_file
              else
                create_new_file
              end
            end
          end

          def create_new_file
            @file = File.open(@path, "w+b")
            @file.truncate(HistogramStore::INITIAL_FILE_SIZE)
            @file.flush

            @capacity = HistogramStore::INITIAL_FILE_SIZE
            @mmap = IO::Buffer.map(@file, @capacity, 0, IO::Buffer::SHARED)

            # Write header
            magic_buf = IO::Buffer.for(HistogramStore::MAGIC)
            @mmap.copy(magic_buf, 0)
            @mmap.set_value(:U32, 4, HistogramStore::VERSION)
            @mmap.set_value(:U32, 8, 0) # bucket_count
            @used = HistogramStore::HEADER_SIZE
          end

          def open_existing_file
            @file = File.open(@path, "r+b")
            @capacity = @file.size
            @mmap = IO::Buffer.map(@file, @capacity, 0, IO::Buffer::SHARED)

            magic = @mmap.get_string(0, 4, Encoding::BINARY)
            raise "Invalid histogram file: #{@path}" unless magic == HistogramStore::MAGIC

            # Read existing positions
            populate_positions
          end

          def populate_positions
            bucket_count = @mmap.get_value(:U32, 8)
            pos = HistogramStore::HEADER_SIZE

            bucket_count.times do
              key_len = @mmap.get_value(:U32, pos)
              pos += 4

              # Read padded key
              padded_len = ((key_len + 3) / 4) * 4 # Round up to 4-byte alignment
              key = @mmap.get_string(pos, key_len, Encoding::UTF_8)
              pos += padded_len

              # Position points to the value
              @positions[key] = pos
              pos += 16 # value (8) + timestamp (8)
            end

            @used = pos
          end

          def ensure_key(key)
            return if @positions.key?(key)

            key_bytes = key.to_s.encode(Encoding::UTF_8)
            key_len = key_bytes.bytesize
            padded_len = ((key_len + 3) / 4) * 4

            entry_size = 4 + padded_len + 16 # key_len + padded_key + value + timestamp

            # Grow file if needed
            while @used + entry_size > @capacity
              grow_file
            end

            # Write key
            @mmap.set_value(:U32, @used, key_len)
            key_buf = IO::Buffer.for(key_bytes)
            @mmap.copy(key_buf, @used + 4)
            if padded_len > key_len
              # Zero padding
              (padded_len - key_len).times do |i|
                @mmap.set_value(:U8, @used + 4 + key_len + i, 0)
              end
            end

            # Position points to value
            @positions[key] = @used + 4 + padded_len

            # Initialize value and timestamp
            @mmap.set_value(:F64, @positions[key], 0.0)
            @mmap.set_value(:F64, @positions[key] + 8, 0.0)

            @used += entry_size

            # Update bucket count
            bucket_count = @mmap.get_value(:U32, 8)
            @mmap.set_value(:U32, 8, bucket_count + 1)
          end

          def grow_file
            @mmap = nil
            new_capacity = @capacity * 2
            @file.truncate(new_capacity)
            @file.flush
            @capacity = new_capacity
            @mmap = IO::Buffer.map(@file, @capacity, 0, IO::Buffer::SHARED)
          end
        end

        private_constant :MmapHistogram
      end
    end
  end
end
