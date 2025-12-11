# frozen_string_literal: true

module Prometheus
  module Client
    module DataStores
      class MmapFileStore
        # Mmap-backed store for gauge metrics.
        #
        # File format (24 bytes):
        #   - magic: 4 bytes ("GAUG")
        #   - version: 4 bytes (uint32)
        #   - value: 8 bytes (float64)
        #   - timestamp: 8 bytes (float64, monotonic clock)
        #
        # Aggregation modes for multiprocess:
        #   - :sum - sum values across processes
        #   - :min - minimum value across processes
        #   - :max - maximum value across processes
        #   - :all - report each process separately with pid label
        #   - :most_recent - value with most recent timestamp
        #
        class GaugeStore
          MAGIC = "GAUG"
          VERSION = 1
          FILE_SIZE = 24

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
            gauge_modes = { @metric_name => @values_aggregation_mode }
            gauges = aggregator.aggregate_all_gauges_with_modes(gauge_modes)

            result = gauges[@metric_name] || {}

            # For :all mode, the aggregator returns arrays of {pid:, value:}
            # We need to expand these into separate label sets with pid label
            if @values_aggregation_mode == MmapFileStore::ALL
              expanded = {}
              result.each do |labels, values|
                if values.is_a?(Array)
                  values.each do |entry|
                    combined_labels = labels.merge(pid: entry[:pid])
                    expanded[combined_labels] = entry[:value]
                  end
                else
                  expanded[labels] = values
                end
              end
              result = expanded
            end

            result
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
            MmapGauge.new(file_path)
          end

          def store_key(labels)
            if @values_aggregation_mode == MmapFileStore::ALL
              labels = labels.merge(pid: worker_pid)
            end

            labels.to_a.sort.map { |k, v| "#{k}=#{v}" }.join("&")
          end

          def generate_filename(labels)
            label_part = Support::LabelEncoder.encode_labels(labels)
            metric_part = Support::LabelEncoder.encode(@metric_name)

            "#{metric_part}__#{label_part}__#{worker_pid}.gauge"
          end

          def worker_pid
            Support::PidProvider.worker_pid
          end
        end

        # Single mmap file for a gauge value.
        class MmapGauge
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
              @mmap.set_value(:F64, 16, Process.clock_gettime(Process::CLOCK_MONOTONIC))
            end
          end

          def increment(by)
            @mutex.synchronize do
              current = @mmap.get_value(:F64, 8)
              @mmap.set_value(:F64, 8, current + by)
              @mmap.set_value(:F64, 16, Process.clock_gettime(Process::CLOCK_MONOTONIC))
            end
          end

          def get
            @mutex.synchronize do
              @mmap.get_value(:F64, 8)
            end
          end

          def get_with_timestamp
            @mutex.synchronize do
              [@mmap.get_value(:F64, 8), @mmap.get_value(:F64, 16)]
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
            @file.truncate(GaugeStore::FILE_SIZE)
            @file.flush

            @mmap = IO::Buffer.map(@file, GaugeStore::FILE_SIZE, 0, IO::Buffer::SHARED)

            # Write header
            magic_buf = IO::Buffer.for(GaugeStore::MAGIC)
            @mmap.copy(magic_buf, 0)
            @mmap.set_value(:U32, 4, GaugeStore::VERSION)
            @mmap.set_value(:F64, 8, 0.0)
            @mmap.set_value(:F64, 16, 0.0)
          end

          def open_existing_file
            @file = File.open(@path, "r+b")
            @mmap = IO::Buffer.map(@file, GaugeStore::FILE_SIZE, 0, IO::Buffer::SHARED)

            magic = @mmap.get_string(0, 4, Encoding::BINARY)
            raise "Invalid gauge file: #{@path}" unless magic == GaugeStore::MAGIC
          end
        end

        private_constant :MmapGauge
      end
    end
  end
end
