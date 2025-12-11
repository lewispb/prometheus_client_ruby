# encoding: UTF-8

require 'prometheus/client/registry'
require 'prometheus/client/config'

module Prometheus
  # Client is a ruby implementation for a Prometheus compatible client.
  module Client
    # Autoload data stores to avoid loading them unless needed
    module DataStores
      autoload :DirectFileStore, 'prometheus/client/data_stores/direct_file_store'
      autoload :MmapFileStore, 'prometheus/client/data_stores/mmap_file_store'
      autoload :Synchronized, 'prometheus/client/data_stores/synchronized'
      autoload :SingleThreaded, 'prometheus/client/data_stores/single_threaded'
    end

    # Returns a default registry object
    def self.registry
      @registry ||= Registry.new
    end

    def self.config
      @config ||= Config.new
    end
  end
end
