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
    K8_POD_CA_CERT = 'ca.crt'
    K8_POD_TOKEN = 'token'

    Fluent::Plugin.register_filter('kubernetes_metadata', self)

    config_param :kubernetes_url, :string, default: ''
    config_param :cache_size, :integer, default: 1000
    config_param :cache_ttl, :integer, default: 60 * 60
    config_param :watch, :bool, default: true
    config_param :apiVersion, :string, default: 'v1'
    config_param :client_cert, :string, default: ''
    config_param :client_key, :string, default: ''
    config_param :ca_file, :string, default: ''
    config_param :verify_ssl, :bool, default: true
    config_param :tag_to_kubernetes_name_regexp,
                 :string,
                 :default => 'var\.log\.containers\.(?<pod_name>[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<namespace>[^_]+)_(?<container_name>.+)-(?<docker_id>[a-z0-9]{64})\.log$'
    config_param :bearer_token_file, :string, default: ''
    config_param :merge_json_log, :bool, default: true
    config_param :include_namespace_id, :bool, default: false
    config_param :secret_dir, :string, default: '/var/run/secrets/kubernetes.io/serviceaccount'
    config_param :de_dot, :bool, default: true
    config_param :de_dot_separator, :string, default: '_'

    def get_metadata(namespace_name, pod_name, container_name)
      begin
        metadata = @client.get_pod(pod_name, namespace_name)
        return if !metadata
        labels = metadata['metadata']['labels'].to_h
        if @de_dot
          self.de_dot!(labels)
        end
        return {
            namespace_name: namespace_name,
            pod_id:         metadata['metadata']['uid'],
            pod_name:       pod_name,
            container_name: container_name,
            labels:         labels,
            host:           metadata['spec']['nodeName']
        }
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

      if @de_dot && (@de_dot_separator =~ /\./).present?
        raise Fluent::ConfigError, "Invalid de_dot_separator: cannot be or contain '.'"
      end

      if @cache_ttl < 0
        @cache_ttl = :none
      end
      @cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
      if @include_namespace_id
        @namespace_cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
      end
      @tag_to_kubernetes_name_regexp_compiled = Regexp.compile(@tag_to_kubernetes_name_regexp)

      # Use Kubernetes default service account if we're in a pod.
      if !@kubernetes_url.present?
        env_host = ENV['KUBERNETES_SERVICE_HOST']
        env_port = ENV['KUBERNETES_SERVICE_PORT']
        if !env_host.nil? and !env_port.nil?
          @kubernetes_url = "https://#{env_host}:#{env_port}/api"
        end
      end

      # Use SSL certificate and bearer token from Kubernetes service account.
      if Dir.exist?(@secret_dir)
        ca_cert = File.join(@secret_dir, K8_POD_CA_CERT)
        pod_token = File.join(@secret_dir, K8_POD_TOKEN)

        if !@ca_file.present? and File.exist?(ca_cert)
          @ca_file = ca_cert
        end

        if !@bearer_token_file.present? and File.exist?(pod_token)
          @bearer_token_file = pod_token
        end
      end

      if @kubernetes_url.present?

        ssl_options = {
            client_cert: @client_cert.present? ? OpenSSL::X509::Certificate.new(File.read(@client_cert)) : nil,
            client_key:  @client_key.present? ? OpenSSL::PKey::RSA.new(File.read(@client_key)) : nil,
            ca_file:     @ca_file,
            verify_ssl:  @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        }

        auth_options = {}

        if @bearer_token_file.present?
          bearer_token = File.read(@bearer_token_file)
          auth_options[:bearer_token] = bearer_token
        end

        @client = Kubeclient::Client.new @kubernetes_url, @apiVersion,
                                         ssl_options: ssl_options,
                                         auth_options: auth_options

        begin
          @client.api_valid?
        rescue KubeException => kube_error
          raise Fluent::ConfigError, "Invalid Kubernetes API endpoint: #{kube_error.message}"
        end

        if @watch
          thread = Thread.new(self) { |this| this.start_watch }
          thread.abort_on_exception = true
          if @include_namespace_id
            namespace_thread = Thread.new(self) { |this| this.start_namespace_watch }
            namespace_thread.abort_on_exception = true
          end
        end
      end
    end

    def filter_stream(tag, es)
      new_es = MultiEventStream.new

      match_data = tag.match(@tag_to_kubernetes_name_regexp_compiled)

      if match_data
        metadata = {
            docker: {
                container_id: match_data['docker_id']
            },
            kubernetes: {
                namespace_name: match_data['namespace'],
                pod_name: match_data['pod_name'],
                container_name: match_data['container_name']
            }
        }

        if @kubernetes_url.present?
          cache_key = "#{metadata[:kubernetes][:namespace_name]}_#{metadata[:kubernetes][:pod_name]}_#{metadata[:kubernetes][:container_name]}"

          this     = self
          metadata = @cache.getset(cache_key) {
            if metadata
              kubernetes_metadata = this.get_metadata(
                metadata[:kubernetes][:namespace_name],
                metadata[:kubernetes][:pod_name],
                metadata[:kubernetes][:container_name]
              )
              metadata[:kubernetes] = kubernetes_metadata if kubernetes_metadata
              metadata
            end
          }
          if @include_namespace_id
            namespace_name = metadata[:kubernetes][:namespace_name]
            namespace_id = @namespace_cache.getset(namespace_name) {
              namespace = @client.get_namespace(namespace_name)
              namespace['metadata']['uid'] if namespace
            }
            metadata[:kubernetes][:namespace_id] = namespace_id if namespace_id
          end
        end
      end

      es.each { |time, record|
        record = merge_json_log(record) if @merge_json_log

        record = record.merge(metadata) if metadata

        new_es.add(time, record)
      }

      new_es
    end

    def merge_json_log(record)
      if record.has_key?('log')
        log = record['log'].strip
        if log[0].eql?('{') && log[-1].eql?('}')
          begin
            record = JSON.parse(log).merge(record)
          rescue JSON::ParserError
          end
        end
      end
      record
    end

    def de_dot!(h)
      h.keys.each do |ref|
        if h[ref] && ref =~ /\./
          v = h.delete(ref)
          newref = ref.to_s.gsub('.', @de_dot_separator)
          h[newref.to_sym] = v
        end
      end
    end

    def start_watch
      resource_version = @client.get_pods.resourceVersion
      watcher          = @client.watch_pods(resource_version)
      watcher.each do |notice|
        case notice.type
          when 'MODIFIED'
            if notice.object.status.containerStatuses
              notice.object.status.containerStatuses.each { |container_status|
                if container_status['containerId']
                  containerId = container_status['containerId'].sub(/^docker:\/\//, '')
                  cached      = @cache[containerId]
                  if cached
                    # Only thing that can be modified is labels
                    labels = v.object.metadata.labels.to_h
                    if @de_dot
                      self.de_dot!(labels)
                    end
                    cached[:labels]     = labels
                    @cache[containerId] = cached
                  end
                end
              }
            end
          when 'DELETED'
            if notice.object.status.containerStatuses
              notice.object.status.containerStatuses.each { |container_status|
                if container_status['containerId']
                  @cache.delete(container_status['containerId'].sub(/^docker:\/\//, ''))
                end
              }
            end
          else
            # Don't pay attention to creations, since the created pod may not
            # end up on this node.
        end
      end
    end

    def start_namespace_watch
      resource_version = @client.get_namespaces.resourceVersion
      watcher          = @client.watch_namespaces(resource_version)
      watcher.each do |notice|
        puts notice
        case notice.type
          when 'DELETED'
            @namespace_cache.delete(notice.object['metadata']['uid'])
          else
            # We only care about each namespace's name and UID, neither of which
            # is modifiable, so we only have to care about deletions.
        end
      end
    end
  end
end
