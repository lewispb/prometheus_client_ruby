# frozen_string_literal: true

module Prometheus
  module Client
    module DataStores
      class MmapFileStore
        # Mmap-backed store for counter metrics.
        #
        # File format (16 bytes):
        #   - magic: 4 bytes ("CNTR")
        #   - version: 4 bytes (uint32)
        #   - value: 8 bytes (float64)
        #
        class CounterStore
          MAGIC = "CNTR"
          VERSION = 1
          FILE_SIZE = 16

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
              store_for(labels).set(val.to_f)
            end
          end

          def increment(labels:, by: 1)
            @lock.synchronize do
              store_for(labels).increment(by.to_f)
            end
          end

          def get(labels:)
            @lock.synchronize do
              store = @stores[store_key(labels)]
              store&.get || 0.0
            end
          end

          def all_values
            aggregator = MultiprocessAggregator.new(@store_settings[:dir])
            counters = aggregator.aggregate_all_counters

            counters[@metric_name] || {}
          end

          private

          def store_for(labels)
            key = store_key(labels)

            # Handle process forking - reopen stores if PID changed
            current_pid = worker_pid
            if @store_opened_by_pid != current_pid
              @stores.each_value(&:close)
              @stores.clear
              @store_opened_by_pid = current_pid
            end

            @stores[key] ||= create_store(key, labels)
          end

          def create_store(key, labels)
            filename = generate_filename(labels)
            file_path = File.join(@store_settings[:dir], filename)
            MmapCounter.new(file_path)
          end

          def store_key(labels)
            labels.to_a.sort.map { |k, v| "#{k}=#{v}" }.join("&")
          end

          def generate_filename(labels)
            label_part = Support::LabelEncoder.encode_labels(labels)
            metric_part = Support::LabelEncoder.encode(@metric_name)

            "#{metric_part}__#{label_part}__#{worker_pid}.counter"
          end

          def worker_pid
            Support::PidProvider.worker_pid
          end
        end

        # Single mmap file for a counter value.
        class MmapCounter
          def initialize(path)
            @path = path
            @file = nil
            @mmap = nil
            @mutex = Mutex.new

            initialize_file
          end

          def set(value)
            @mutex.synchronize do
              @mmap.set_value(:F64, 8, value)
            end
          end

          def increment(by)
            @mutex.synchronize do
              current = @mmap.get_value(:F64, 8)
              @mmap.set_value(:F64, 8, current + by)
            end
          end

          def get
            @mutex.synchronize do
              @mmap.get_value(:F64, 8)
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
            @file.truncate(CounterStore::FILE_SIZE)
            @file.flush

            @mmap = IO::Buffer.map(@file, CounterStore::FILE_SIZE, 0, IO::Buffer::SHARED)

            # Write header
            magic_buf = IO::Buffer.for(CounterStore::MAGIC)
            @mmap.copy(magic_buf, 0)
            @mmap.set_value(:U32, 4, CounterStore::VERSION)
            @mmap.set_value(:F64, 8, 0.0)
          end

          def open_existing_file
            @file = File.open(@path, "r+b")
            @mmap = IO::Buffer.map(@file, CounterStore::FILE_SIZE, 0, IO::Buffer::SHARED)

            magic = @mmap.get_string(0, 4, Encoding::BINARY)
            raise "Invalid counter file: #{@path}" unless magic == CounterStore::MAGIC
          end
        end

        private_constant :MmapCounter
      end
    end
  end
end
