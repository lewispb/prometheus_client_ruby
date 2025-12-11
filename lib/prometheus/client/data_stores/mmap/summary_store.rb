# frozen_string_literal: true

module Prometheus
  module Client
    module DataStores
      class MmapFileStore
        # Mmap-backed store for summary metrics.
        #
        # Summaries track count and sum of observations.
        # Each is stored as a separate value with the :quantile label.
        #
        # File format (32 bytes):
        #   - magic: 4 bytes ("SUMM")
        #   - version: 4 bytes (uint32)
        #   - count: 8 bytes (float64)
        #   - sum: 8 bytes (float64)
        #   - timestamp: 8 bytes (float64)
        #
        class SummaryStore
          MAGIC = "SUMM"
          VERSION = 1
          FILE_SIZE = 32

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
              base_labels = labels.reject { |k, _| k == :quantile }
              quantile = labels[:quantile]

              store_for(base_labels).set(quantile, val.to_f)
            end
          end

          def increment(labels:, by: 1)
            @lock.synchronize do
              base_labels = labels.reject { |k, _| k == :quantile }
              quantile = labels[:quantile]

              store_for(base_labels).increment(quantile, by.to_f)
            end
          end

          def get(labels:)
            @lock.synchronize do
              base_labels = labels.reject { |k, _| k == :quantile }
              quantile = labels[:quantile]
              key = store_key(base_labels)

              store = @stores[key]
              return 0.0 unless store

              store.get(quantile) || 0.0
            end
          end

          def all_values
            aggregator = MultiprocessAggregator.new(@store_settings[:dir])
            summaries = aggregator.aggregate_all_summaries

            # The aggregator returns {metric_name => {base_labels => {quantile => value}}}
            # We need to flatten to {labels_with_quantile => value}
            result = {}
            (summaries[@metric_name] || {}).each do |base_labels, quantile_values|
              quantile_values.each do |quantile, value|
                full_labels = base_labels.merge(quantile: quantile)
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
            MmapSummary.new(file_path)
          end

          def store_key(base_labels)
            base_labels.to_a.sort.map { |k, v| "#{k}=#{v}" }.join("&")
          end

          def generate_filename(base_labels)
            label_part = Support::LabelEncoder.encode_labels(base_labels)
            metric_part = Support::LabelEncoder.encode(@metric_name)

            "#{metric_part}__#{label_part}__#{worker_pid}.summary"
          end

          def worker_pid
            Support::PidProvider.worker_pid
          end
        end

        # Single mmap file for summary count and sum.
        class MmapSummary
          def initialize(path)
            @path = path
            @file = nil
            @mmap = nil
            @mutex = Mutex.new

            initialize_file
          end

          def set(quantile, value)
            @mutex.synchronize do
              offset = offset_for(quantile)
              return unless offset

              @mmap.set_value(:F64, offset, value)
              @mmap.set_value(:F64, 24, Process.clock_gettime(Process::CLOCK_MONOTONIC))
            end
          end

          def increment(quantile, by)
            @mutex.synchronize do
              offset = offset_for(quantile)
              return unless offset

              current = @mmap.get_value(:F64, offset)
              @mmap.set_value(:F64, offset, current + by)
              @mmap.set_value(:F64, 24, Process.clock_gettime(Process::CLOCK_MONOTONIC))
            end
          end

          def get(quantile)
            @mutex.synchronize do
              offset = offset_for(quantile)
              return nil unless offset

              @mmap.get_value(:F64, offset)
            end
          end

          def all_values
            @mutex.synchronize do
              {
                "count" => @mmap.get_value(:F64, 8),
                "sum" => @mmap.get_value(:F64, 16)
              }
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

          def offset_for(quantile)
            case quantile.to_s
            when "count" then 8
            when "sum" then 16
            end
          end

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
            @file.truncate(SummaryStore::FILE_SIZE)
            @file.flush

            @mmap = IO::Buffer.map(@file, SummaryStore::FILE_SIZE, 0, IO::Buffer::SHARED)

            # Write header
            magic_buf = IO::Buffer.for(SummaryStore::MAGIC)
            @mmap.copy(magic_buf, 0)
            @mmap.set_value(:U32, 4, SummaryStore::VERSION)
            @mmap.set_value(:F64, 8, 0.0)  # count
            @mmap.set_value(:F64, 16, 0.0) # sum
            @mmap.set_value(:F64, 24, 0.0) # timestamp
          end

          def open_existing_file
            @file = File.open(@path, "r+b")
            @mmap = IO::Buffer.map(@file, SummaryStore::FILE_SIZE, 0, IO::Buffer::SHARED)

            magic = @mmap.get_string(0, 4, Encoding::BINARY)
            raise "Invalid summary file: #{@path}" unless magic == SummaryStore::MAGIC
          end
        end

        private_constant :MmapSummary
      end
    end
  end
end
