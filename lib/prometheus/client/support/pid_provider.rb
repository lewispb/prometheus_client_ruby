# frozen_string_literal: true

require 'prometheus/client'

module Prometheus
  module Client
    module Support
      # PID provider for generating stable process identifiers.
      #
      # In forking servers like Puma, Unicorn, or Resque, using raw PIDs leads to
      # file proliferation as each fork creates new mmap files. This module provides
      # stable identifiers (e.g., "puma_0", "puma_1") that persist across restarts.
      #
      # @example Configure a custom provider
      #   Prometheus::Client.config.pid_provider = -> { "worker_#{ENV['WORKER_ID']}" }
      #
      module PidProvider
        extend self

        # Detect and return a stable process identifier.
        #
        # Checks for common forking servers in order:
        # 1. Custom provider (if configured)
        # 2. Puma (cluster worker or master)
        # 3. Unicorn (worker or master)
        # 4. Passenger
        # 5. Solid Queue (supervisor or worker)
        # 6. Resque (worker with JOB_INDEX or WORKER_ID)
        # 7. Falls back to Process.pid
        #
        # @return [String] A stable process identifier
        def worker_pid
          custom_provider = Prometheus::Client.config.pid_provider
          return custom_provider.call.to_s if custom_provider

          detect_puma_worker ||
            detect_unicorn_worker ||
            detect_passenger_worker ||
            detect_solid_queue_worker ||
            detect_resque_worker ||
            Process.pid.to_s
        end

        private

        # Detect Puma worker identity from $PROGRAM_NAME or ObjectSpace.
        #
        # @return [String, nil] "puma_N" for workers, "puma_master" for master, nil if not Puma
        def detect_puma_worker
          return unless defined?(::Puma)

          # Try $PROGRAM_NAME first (e.g., "puma: cluster worker 0: ...")
          if (match = $PROGRAM_NAME.match(/puma.*cluster worker (\d+):/i))
            return "puma_#{match[1]}"
          end

          # Try ObjectSpace for Puma::Cluster::Worker
          if defined?(::Puma::Cluster::Worker)
            workers = ObjectSpace.each_object(::Puma::Cluster::Worker).first
            return "puma_#{workers.index}" if workers&.respond_to?(:index)
          end

          # Check if we're the master process
          return "puma_master" if $PROGRAM_NAME.include?("puma")

          nil
        end

        # Detect Unicorn worker identity from environment or $PROGRAM_NAME.
        #
        # @return [String, nil] "unicorn_N" for workers, "unicorn_master" for master
        def detect_unicorn_worker
          return unless defined?(::Unicorn)

          # Unicorn sets worker number in $PROGRAM_NAME
          if (match = $PROGRAM_NAME.match(/unicorn.*worker\[(\d+)\]/i))
            return "unicorn_#{match[1]}"
          end

          return "unicorn_master" if $PROGRAM_NAME.include?("unicorn")

          nil
        end

        # Detect Passenger worker identity.
        #
        # @return [String, nil] "passenger_N" based on PASSENGER_APP_GROUP_NAME
        def detect_passenger_worker
          return unless ENV["PASSENGER_APP_GROUP_NAME"]

          # Passenger doesn't expose worker index easily, use a hash of group + pid
          # This at least groups by application
          "passenger_#{Process.pid}"
        end

        # Detect Solid Queue worker identity.
        #
        # @return [String, nil] "solid_queue_worker_N" or "solid_queue_supervisor"
        def detect_solid_queue_worker
          return unless defined?(::SolidQueue)

          # Check for supervisor
          if $PROGRAM_NAME.include?("solid_queue:supervisor")
            return "solid_queue_supervisor"
          end

          # Check for worker with index in program name
          if (match = $PROGRAM_NAME.match(/solid_queue:worker[_-]?(\d+)/i))
            return "solid_queue_worker_#{match[1]}"
          end

          # Check for dispatcher
          if $PROGRAM_NAME.include?("solid_queue:dispatcher")
            return "solid_queue_dispatcher"
          end

          # Generic solid queue process
          return "solid_queue_#{Process.pid}" if $PROGRAM_NAME.include?("solid_queue")

          nil
        end

        # Detect Resque worker identity from environment variables.
        #
        # @return [String, nil] "resque_N" based on JOB_INDEX, WORKER_ID, or QUEUE
        def detect_resque_worker
          return unless defined?(::Resque) || ENV["RESQUE_WORKER"] || ENV["QUEUE"]

          # Common environment variables for worker identity
          if (index = ENV["JOB_INDEX"] || ENV["WORKER_ID"] || ENV["RESQUE_WORKER_ID"])
            return "resque_#{index}"
          end

          # Fall back to queue name if available
          if (queue = ENV["QUEUE"] || ENV["QUEUES"])
            # Use queue name + pid for uniqueness within same queue
            return "resque_#{queue.split(',').first}_#{Process.pid}"
          end

          nil
        end
      end
    end
  end
end
