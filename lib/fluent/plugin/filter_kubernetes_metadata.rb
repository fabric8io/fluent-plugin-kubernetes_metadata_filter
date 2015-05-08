#
# Fluentd Kubernetes Metadata Filter Plugin - Enrich Fluentd events with
# Kubernetes metadata
#
# Copyright 2015 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
module Fluent
  class KubernetesMetadataFilter < Fluent::Filter
    Fluent::Plugin.register_filter('kubernetes_metadata', self)

    config_param :cache_size, :integer, :default => 1000
    config_param :kubernetes_url, :string
    config_param :apiVersion, :string, :default => 'v1beta3'
    config_param :client_cert, :string, :default => ''
    config_param :client_key, :string, :default => ''
    config_param :ca_file, :string, :default => ''
    config_param :verify_ssl, :bool, :default => true
    config_param :container_name_to_kubernetes_name_regexp,
                 :string,
                 :default => '\/?[^_]+_(?<pod_container_name>[^\.]+)[^_]+_(?<pod_name>[^_]+)_(?<namespace>[^_]+)'

    def self.get_metadata(pod_name, container_name, namespace)
      begin
        metadata = @@client.get_pod(pod_name, namespace)
        if metadata
          return {
            :uid => metadata['metadata']['uid'],
            :namespace => metadata['metadata']['namespace'],
            :pod_name => metadata['metadata']['name'],
            :container_name => container_name,
            :labels => metadata['metadata']['labels'].to_h,
            :host => metadata['spec']['host']
          }
        end
      rescue KubeException
        nil
      end
    end

    def initialize
      super
    end

    def configure(conf)
      super

      require 'kubeclient'
      require 'active_support/core_ext/object/blank'
      require 'lru_redux'

      @@client = Kubeclient::Client.new @kubernetes_url, @apiVersion

      if @client_cert.present? && @client_key.present? && @ca_file.present?

        @@client.ssl_options(
          client_cert: OpenSSL::X509::Certificate.new(File.read(@client_cert)),
          client_key: OpenSSL::PKey::RSA.new(File.read(@client_key)),
          ca_file: @ca_file,
          verify_ssl: @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        )
      end

      raise Fluent::ConfigError, 'Invalid Kubernetes API endpoint' unless @@client.api_valid?

      @cache = LruRedux::ThreadSafeCache.new(@cache_size)
      @container_name_to_kubernetes_name_regexp_compiled = Regexp.compile(@container_name_to_kubernetes_name_regexp)
    end

    def filter_stream(tag, es)
      new_es = MultiEventStream.new

      es.each {|time, record|
        if record.has_key?(:docker) && record[:docker].has_key?(:name)
          metadata = @cache.getset(record[:docker][:name]){
            match_data = record[:docker][:name].match(@container_name_to_kubernetes_name_regexp_compiled)
            if match_data
              KubernetesMetadataFilter.get_metadata(
                match_data[:pod_name],
                match_data[:pod_container_name],
                match_data[:namespace]
              )
            end
          }

          record[:kubernetes] = metadata if metadata
        end

        new_es.add(time, record)
      }

      new_es
    end
  end

end