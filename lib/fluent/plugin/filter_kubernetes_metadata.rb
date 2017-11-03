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

require_relative 'kubernetes_metadata_stats'
require_relative 'kubernetes_metadata_watch_namespaces'
require_relative 'kubernetes_metadata_watch_pods'

module Fluent
  class KubernetesMetadataFilter < Fluent::Filter
    K8_POD_CA_CERT = 'ca.crt'
    K8_POD_TOKEN = 'token'

    include KubernetesMetadata::Common
    include KubernetesMetadata::WatchNamespaces
    include KubernetesMetadata::WatchPods

    Fluent::Plugin.register_filter('kubernetes_metadata', self)

    config_param :kubernetes_url, :string, default: nil
    config_param :cache_size, :integer, default: 1000
    config_param :cache_ttl, :integer, default: 60 * 60
    config_param :watch, :bool, default: true
    config_param :apiVersion, :string, default: 'v1'
    config_param :client_cert, :string, default: nil
    config_param :client_key, :string, default: nil
    config_param :ca_file, :string, default: nil
    config_param :verify_ssl, :bool, default: true
    config_param :tag_to_kubernetes_name_regexp,
                 :string,
                 :default => 'var\.log\.containers\.(?<pod_name>[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<namespace>[^_]+)_(?<container_name>.+)-(?<docker_id>[a-z0-9]{64})\.log$'
    config_param :bearer_token_file, :string, default: nil
    config_param :merge_json_log, :bool, default: true
    config_param :preserve_json_log, :bool, default: true
    config_param :secret_dir, :string, default: '/var/run/secrets/kubernetes.io/serviceaccount'
    config_param :de_dot, :bool, default: true
    config_param :de_dot_separator, :string, default: '_'
    # if reading from the journal, the record will contain the following fields in the following
    # format:
    # CONTAINER_NAME=k8s_$containername.$containerhash_$podname_$namespacename_$poduuid_$rand32bitashex
    # CONTAINER_FULL_ID=dockeridassha256hexvalue
    config_param :use_journal, :bool, default: false
    # Field 2 is the container_hash, field 5 is the pod_id, and field 6 is the pod_randhex
    # I would have included them as named groups, but you can't have named groups that are
    # non-capturing :P
    # parse format is defined here: https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/dockertools/docker.go#L317
    config_param :container_name_to_kubernetes_regexp,
                 :string,
                 :default => '^(?<name_prefix>[^_]+)_(?<container_name>[^\._]+)(\.(?<container_hash>[^_]+))?_(?<pod_name>[^_]+)_(?<namespace>[^_]+)_[^_]+_[^_]+$'

    config_param :annotation_match, :array, default: []
    config_param :stats_interval, :integer, default: 30


    def fetch_pod_metadata(namespace_name, pod_name)
      begin
        metadata = @client.get_pod(pod_name, namespace_name)
        unless metadata
          @stats.bump(:pod_cache_api_nil_not_found)
        else
          begin
            metadata = parse_pod_metadata(metadata)
            @stats.bump(:pod_cache_api_updates)
            return metadata
          rescue Exception=>e
            log.debug(e)
            @stats.bump(:pod_cache_api_nil_bad_resp_payload)
            {}
          end
        end
      rescue KubeException=>e
        @stats.bump(:pod_cache_api_nil_error)
        log.debug "Exception encountered fetching pod metadata from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}: #{e.message}"
        {}
      end
    end

    def dump_stats
      @curr_time = Time.now
      return if @curr_time.to_i - @prev_time.to_i < @stats_interval
      @prev_time = @curr_time
      @stats.set(:pod_cache_size, @cache.count)
      @stats.set(:namespace_cache_size, @namespace_cache.count)
      log.info(@stats)
    end

    def fetch_namespace_metadata(namespace_name)
      begin
        metadata = @client.get_namespace(namespace_name)
        unless metadata
            @stats.bump(:namespace_cache_api_nil_not_found)
        else
          begin
            metadata = parse_namespace_metadata(metadata)
            @stats.bump(:namespace_cache_api_updates)
            return metadata
          rescue Exception => e
            log.debug(e)
            @stats.bump(:namespace_cache_api_nil_bad_resp_payload)
            {}
          end
        end
      rescue KubeException => kube_error
        @stats.bump(:namespace_cache_api_nil_error)
        log.debug "Exception encountered fetching namespace metadata from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}: #{kube_error.message}"
        {}
      end
    end

    def initialize
      super
      @stats = KubernetesMetadata::Stats.new
      @prev_time = Time.now

    end

    def configure(conf)
      super

      require 'kubeclient'
      require 'active_support/core_ext/object/blank'
      require 'lru_redux'

      @cache_mutex = Mutex.new
      if @cache_ttl <= 0
        log.info "Setting the cache TTL to :none because it was <= 0"
        @cache_ttl = :none
      end

      if @de_dot && (@de_dot_separator =~ /\./).present?
        raise Fluent::ConfigError, "Invalid de_dot_separator: cannot be or contain '.'"
      end

      if @cache_ttl < 0
        @cache_ttl = :none
      end
      @id_cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
      @cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
      @namespace_cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
      @tag_to_kubernetes_name_regexp_compiled = Regexp.compile(@tag_to_kubernetes_name_regexp)
      @container_name_to_kubernetes_regexp_compiled = Regexp.compile(@container_name_to_kubernetes_regexp)

      # Use Kubernetes default service account if we're in a pod.
      if @kubernetes_url.nil?
        env_host = ENV['KUBERNETES_SERVICE_HOST']
        env_port = ENV['KUBERNETES_SERVICE_PORT']
        if env_host.present? && env_port.present?
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
          raise Fluent::ConfigError, "Invalid Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}: #{kube_error.message}"
        end

        if @watch
          thread = Thread.new(self) { |this| this.start_pod_watch }
          thread.abort_on_exception = true
          namespace_thread = Thread.new(self) { |this| this.start_namespace_watch }
          namespace_thread.abort_on_exception = true
        end
      end
      if @use_journal
        @merge_json_log_key = 'MESSAGE'
        self.class.class_eval { alias_method :filter_stream, :filter_stream_from_journal }
      else
        @merge_json_log_key = 'log'
        self.class.class_eval { alias_method :filter_stream, :filter_stream_from_files }
      end

      @annotations_regexps = []
      @annotation_match.each do |regexp|
        begin
          @annotations_regexps << Regexp.compile(regexp)
        rescue RegexpError => e
          log.error "Error: invalid regular expression in annotation_match: #{e}"
        end
      end

    end

    def get_metadata_for_record(match_data, cache_key)
      namespace_name = match_data['namespace']
      pod_name = match_data['pod_name']
      metadata = {
        'container_name' => match_data['container_name'],
        'namespace_name' => namespace_name,
        'pod_name'       => pod_name
      }
      if @kubernetes_url.present?
        pod_metadata = get_pod_metadata(cache_key, namespace_name, pod_name)
        metadata.merge!(pod_metadata) if pod_metadata
      end
      metadata
    end

    def get_pod_metadata(key, namespace_name, pod_name)
        ids = @id_cache.getset(key) do
          @stats.bump(:pod_cache_miss)
          pod_metadata = fetch_pod_metadata(namespace_name, pod_name)
          namespace_metadata = fetch_namespace_metadata(namespace_name)
          ids = {:pod_id=> pod_metadata['pod_id'], :namespace_id => namespace_metadata['namespace_id'] }
          if ids[:pod_id].nil?
             @stats.bump(:pod_cache_orphaned_record)
             ids = :orphaned
          else
            @cache_mutex.synchronize do
              @id_cache[key] = ids
              @cache[ids[:pod_id]] = pod_metadata
              @namespace_cache[ids[:namespace_id]] = namespace_metadata
            end
          end
          ids
        end
        return {
          'orphaned_namespace' => namespace_name,
          'namespace_name' => '.orphaned',
          'namespace_id' => 'orphaned'
        } if ids == :orphaned
        metadata =  @cache[ids[:pod_id]] || {}
        metadata.merge!(@namespace_cache[ids[:namespace_id]] || {}) if ids[:namespace_id]
        metadata
    end

    def filter_stream(tag, es)
      es
    end

    def filter_stream_from_files(tag, es)
      new_es = MultiEventStream.new

      match_data = tag.match(@tag_to_kubernetes_name_regexp_compiled)

      if match_data
        container_id = match_data['docker_id']
        metadata = {
          'docker' => {
            'container_id' => container_id
          },
          'kubernetes' => get_metadata_for_record(match_data, container_id)
        }
      end

      es.each { |time, record|
        record = merge_json_log(record) if @merge_json_log

        record = record.merge(Marshal.load(Marshal.dump(metadata))) if metadata

        new_es.add(time, record)
      }
      dump_stats
      new_es
    end

    def filter_stream_from_journal(tag, es)
      new_es = MultiEventStream.new

      es.each { |time, record|
        record = merge_json_log(record) if @merge_json_log

        metadata = nil
        if record.has_key?('CONTAINER_NAME') && record.has_key?('CONTAINER_ID_FULL')
          metadata = record['CONTAINER_NAME'].match(@container_name_to_kubernetes_regexp_compiled) do |match_data|
           container_id = record['CONTAINER_ID_FULL']
            metadata = {
              'docker' => {
                'container_id' => container_id
              },
              'kubernetes' => get_metadata_for_record(match_data, container_id)
            }

            metadata
          end
          unless metadata
            log.debug "Error: could not match CONTAINER_NAME from record #{record}"
            @stats.dump(:container_name_match_failed)
          end
        elsif record.has_key?('CONTAINER_NAME') && record['CONTAINER_NAME'].start_with?('k8s_')
          log.debug "Error: no container name and id in record #{record}"
          @stats.dump(:container_name_id_missing)
        end

        if metadata
          record = record.merge(metadata)
        end

        new_es.add(time, record)
      }

      dump_stats
      new_es
    end

    def merge_json_log(record)
      if record.has_key?(@merge_json_log_key)
        log = record[@merge_json_log_key].strip
        if log[0].eql?('{') && log[-1].eql?('}')
          begin
            record = JSON.parse(log).merge(record)
            unless @preserve_json_log
              record.delete(@merge_json_log_key)
            end
          rescue JSON::ParserError=>e
            @stats.bump(:merge_json_parse_errors)
            log.debug(e)
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
          h[newref] = v
        end
      end
    end

  end
end
