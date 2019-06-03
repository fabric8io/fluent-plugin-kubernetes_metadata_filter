#
# Fluentd Kubernetes Metadata Filter Plugin - Enrich Fluentd events with
# Kubernetes metadata
#
# Copyright 2017 Red Hat, Inc.
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

require_relative 'kubernetes_metadata_cache_strategy'
require_relative 'kubernetes_metadata_common'
require_relative 'kubernetes_metadata_stats'
require_relative 'kubernetes_metadata_watch_namespaces'
require_relative 'kubernetes_metadata_watch_pods'

require 'fluent/plugin/filter'

module Fluent::Plugin
  class KubernetesMetadataFilter < Fluent::Plugin::Filter
    K8_POD_CA_CERT = 'ca.crt'
    K8_POD_TOKEN = 'token'

    include KubernetesMetadata::CacheStrategy
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
    config_param :secret_dir, :string, default: '/var/run/secrets/kubernetes.io/serviceaccount'
    config_param :de_dot, :bool, default: true
    config_param :de_dot_separator, :string, default: '_'
    # if reading from the journal, the record will contain the following fields in the following
    # format:
    # CONTAINER_NAME=k8s_$containername.$containerhash_$podname_$namespacename_$poduuid_$rand32bitashex
    # CONTAINER_FULL_ID=dockeridassha256hexvalue
    config_param :use_journal, :bool, default: nil
    # Field 2 is the container_hash, field 5 is the pod_id, and field 6 is the pod_randhex
    # I would have included them as named groups, but you can't have named groups that are
    # non-capturing :P
    # parse format is defined here: https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/dockertools/docker.go#L317
    config_param :container_name_to_kubernetes_regexp,
                 :string,
                 :default => '^(?<name_prefix>[^_]+)_(?<container_name>[^\._]+)(\.(?<container_hash>[^_]+))?_(?<pod_name>[^_]+)_(?<namespace>[^_]+)_[^_]+_[^_]+$'

    config_param :annotation_match, :array, default: []
    config_param :stats_interval, :integer, default: 30
    config_param :allow_orphans, :bool, default: true
    config_param :orphaned_namespace_name, :string, default: '.orphaned'
    config_param :orphaned_namespace_id, :string, default: 'orphaned'
    config_param :lookup_from_k8s_field, :bool, default: true
    # if `ca_file` is for an intermediate CA, or otherwise we do not have the root CA and want
    # to trust the intermediate CA certs we do have, set this to `true` - this corresponds to
    # the openssl s_client -partial_chain flag and X509_V_FLAG_PARTIAL_CHAIN
    config_param :ssl_partial_chain, :bool, default: false
    config_param :skip_labels, :bool, default: false
    config_param :skip_container_metadata, :bool, default: false
    config_param :skip_master_url, :bool, default: false
    config_param :skip_namespace_metadata, :bool, default: false

    def fetch_pod_metadata(namespace_name, pod_name)
      log.trace("fetching pod metadata: #{namespace_name}/#{pod_name}") if log.trace?
      begin
        metadata = @client.get_pod(pod_name, namespace_name)
        unless metadata
          log.trace("no metadata returned for: #{namespace_name}/#{pod_name}") if log.trace?
          @stats.bump(:pod_cache_api_nil_not_found)
        else
          begin
            log.trace("raw metadata for #{namespace_name}/#{pod_name}: #{metadata}") if log.trace?
            metadata = parse_pod_metadata(metadata)
            @stats.bump(:pod_cache_api_updates)
            log.trace("parsed metadata for #{namespace_name}/#{pod_name}: #{metadata}") if log.trace?
            @cache[metadata['pod_id']] = metadata
            return metadata
          rescue Exception=>e
            log.debug(e)
            @stats.bump(:pod_cache_api_nil_bad_resp_payload)
            log.trace("returning empty metadata for #{namespace_name}/#{pod_name} due to error '#{e}'") if log.trace?
          end
        end
      rescue Exception=>e
        @stats.bump(:pod_cache_api_nil_error)
        log.debug "Exception '#{e}' encountered fetching pod metadata from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}"
      end
      {}
    end

    def dump_stats
      @curr_time = Time.now
      return if @curr_time.to_i - @prev_time.to_i < @stats_interval
      @prev_time = @curr_time
      @stats.set(:pod_cache_size, @cache.count)
      @stats.set(:namespace_cache_size, @namespace_cache.count) if @namespace_cache
      log.info(@stats)
      if log.level == Fluent::Log::LEVEL_TRACE
        log.trace("       id cache: #{@id_cache.to_a}")
        log.trace("      pod cache: #{@cache.to_a}")
        log.trace("namespace cache: #{@namespace_cache.to_a}")
      end
    end

    def fetch_namespace_metadata(namespace_name)
      log.trace("fetching namespace metadata: #{namespace_name}") if log.trace?
      begin
        metadata = @client.get_namespace(namespace_name)
        unless metadata
            log.trace("no metadata returned for: #{namespace_name}") if log.trace?
            @stats.bump(:namespace_cache_api_nil_not_found)
        else
          begin
            log.trace("raw metadata for #{namespace_name}: #{metadata}") if log.trace?
            metadata = parse_namespace_metadata(metadata)
            @stats.bump(:namespace_cache_api_updates)
            log.trace("parsed metadata for #{namespace_name}: #{metadata}") if log.trace?
             @namespace_cache[metadata['namespace_id']] = metadata
            return metadata
          rescue Exception => e
            log.debug(e)
            @stats.bump(:namespace_cache_api_nil_bad_resp_payload)
            log.trace("returning empty metadata for #{namespace_name} due to error '#{e}'") if log.trace?
          end
        end
      rescue Exception => kube_error
        @stats.bump(:namespace_cache_api_nil_error)
        log.debug "Exception '#{kube_error}' encountered fetching namespace metadata from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}"
      end
      {}
    end

    def initialize
      super
      @prev_time = Time.now
    end

    def configure(conf)
      super

      def log.trace?
        level == Fluent::Log::LEVEL_TRACE
      end

      require 'kubeclient'
      require 'active_support/core_ext/object/blank'
      require 'lru_redux'
      @stats = KubernetesMetadata::Stats.new

      if @de_dot && (@de_dot_separator =~ /\./).present?
        raise Fluent::ConfigError, "Invalid de_dot_separator: cannot be or contain '.'"
      end

      if @cache_ttl < 0
        log.info "Setting the cache TTL to :none because it was <= 0"
        @cache_ttl = :none
      end

      # Caches pod/namespace UID tuples for a given container UID.
      @id_cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)

      # Use the container UID as the key to fetch a hash containing pod metadata
      @cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)

      # Use the namespace UID as the key to fetch a hash containing namespace metadata
      @namespace_cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)

      @tag_to_kubernetes_name_regexp_compiled = Regexp.compile(@tag_to_kubernetes_name_regexp)
      @container_name_to_kubernetes_regexp_compiled = Regexp.compile(@container_name_to_kubernetes_regexp)

      # Use Kubernetes default service account if we're in a pod.
      if @kubernetes_url.nil?
        log.debug "Kubernetes URL is not set - inspecting environ"

        env_host = ENV['KUBERNETES_SERVICE_HOST']
        env_port = ENV['KUBERNETES_SERVICE_PORT']
        if env_host.present? && env_port.present?
          @kubernetes_url = "https://#{env_host}:#{env_port}/api"
          log.debug "Kubernetes URL is now '#{@kubernetes_url}'"
        end
      end

      # Use SSL certificate and bearer token from Kubernetes service account.
      if Dir.exist?(@secret_dir)
        log.debug "Found directory with secrets: #{@secret_dir}"
        ca_cert = File.join(@secret_dir, K8_POD_CA_CERT)
        pod_token = File.join(@secret_dir, K8_POD_TOKEN)

        if !@ca_file.present? and File.exist?(ca_cert)
          log.debug "Found CA certificate: #{ca_cert}"
          @ca_file = ca_cert
        end

        if !@bearer_token_file.present? and File.exist?(pod_token)
          log.debug "Found pod token: #{pod_token}"
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

        if @ssl_partial_chain
          # taken from the ssl.rb OpenSSL::SSL::SSLContext code for DEFAULT_CERT_STORE
          require 'openssl'
          ssl_store = OpenSSL::X509::Store.new
          ssl_store.set_default_paths
          if defined? OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
            flagval = OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
          else
            # this version of ruby does not define OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
            flagval = 0x80000
          end
          ssl_store.flags = OpenSSL::X509::V_FLAG_CRL_CHECK_ALL | flagval
          ssl_options[:cert_store] = ssl_store
        end

        auth_options = {}

        if @bearer_token_file.present?
          bearer_token = File.read(@bearer_token_file)
          auth_options[:bearer_token] = bearer_token
        end

        log.debug "Creating K8S client"
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
      @time_fields = []
      @time_fields.push('_SOURCE_REALTIME_TIMESTAMP', '__REALTIME_TIMESTAMP') if @use_journal || @use_journal.nil?
      @time_fields.push('time') unless @use_journal
      @time_fields.push('@timestamp') if @lookup_from_k8s_field

      @annotations_regexps = []
      @annotation_match.each do |regexp|
        begin
          @annotations_regexps << Regexp.compile(regexp)
        rescue RegexpError => e
          log.error "Error: invalid regular expression in annotation_match: #{e}"
        end
      end

    end

    def get_metadata_for_record(namespace_name, pod_name, container_name, container_id, create_time, batch_miss_cache)
      metadata = {
        'docker' => {'container_id' => container_id},
        'kubernetes' => {
          'container_name'  => container_name,
          'namespace_name'  => namespace_name,
          'pod_name'        => pod_name
        }
      }
      if @kubernetes_url.present?
        pod_metadata = get_pod_metadata(container_id, namespace_name, pod_name, create_time, batch_miss_cache)

        if (pod_metadata.include? 'containers') && (pod_metadata['containers'].include? container_id) && !@skip_container_metadata
          metadata['kubernetes']['container_image'] = pod_metadata['containers'][container_id]['image']
          metadata['kubernetes']['container_image_id'] = pod_metadata['containers'][container_id]['image_id']
        end

        metadata['kubernetes'].merge!(pod_metadata) if pod_metadata
        metadata['kubernetes'].delete('containers')
      end
      metadata
    end

    def create_time_from_record(record, internal_time)
      time_key = @time_fields.detect{ |ii| record.has_key?(ii) }
      time = record[time_key]
      if time.nil? || time.chop.empty?
        # `internal_time` is a Fluent::EventTime, it can't compare with Time.
        return Time.at(internal_time.to_f)
      end
      if ['_SOURCE_REALTIME_TIMESTAMP', '__REALTIME_TIMESTAMP'].include?(time_key)
        timei= time.to_i
        return Time.at(timei / 1000000, timei % 1000000)
      end
      return Time.parse(time)
    end

    def filter_stream(tag, es)
      return es if (es.respond_to?(:empty?) && es.empty?) || !es.is_a?(Fluent::EventStream)
      new_es = Fluent::MultiEventStream.new
      tag_match_data = tag.match(@tag_to_kubernetes_name_regexp_compiled) unless @use_journal
      tag_metadata = nil
      batch_miss_cache = {}
      es.each do |time, record|
        if tag_match_data && tag_metadata.nil?
          tag_metadata = get_metadata_for_record(tag_match_data['namespace'], tag_match_data['pod_name'], tag_match_data['container_name'],
            tag_match_data['docker_id'], create_time_from_record(record, time), batch_miss_cache)
        end
        metadata = Marshal.load(Marshal.dump(tag_metadata)) if tag_metadata
        if (@use_journal || @use_journal.nil?) &&
          (j_metadata = get_metadata_for_journal_record(record, time, batch_miss_cache))
          metadata = j_metadata
        end
        if @lookup_from_k8s_field && record.has_key?('kubernetes') && record.has_key?('docker') &&
          record['kubernetes'].respond_to?(:has_key?) && record['docker'].respond_to?(:has_key?) &&
          record['kubernetes'].has_key?('namespace_name') &&
          record['kubernetes'].has_key?('pod_name') &&
          record['kubernetes'].has_key?('container_name') &&
          record['docker'].has_key?('container_id') &&
          (k_metadata = get_metadata_for_record(record['kubernetes']['namespace_name'], record['kubernetes']['pod_name'],
            record['kubernetes']['container_name'], record['docker']['container_id'],
            create_time_from_record(record, time), batch_miss_cache))
            metadata = k_metadata
        end

        record = record.merge(metadata) if metadata
        new_es.add(time, record)
      end
      dump_stats
      new_es
    end

    def get_metadata_for_journal_record(record, time, batch_miss_cache)
      metadata = nil
      if record.has_key?('CONTAINER_NAME') && record.has_key?('CONTAINER_ID_FULL')
        metadata = record['CONTAINER_NAME'].match(@container_name_to_kubernetes_regexp_compiled) do |match_data|
          get_metadata_for_record(match_data['namespace'], match_data['pod_name'], match_data['container_name'],
            record['CONTAINER_ID_FULL'], create_time_from_record(record, time), batch_miss_cache)
        end
        unless metadata
          log.debug "Error: could not match CONTAINER_NAME from record #{record}"
          @stats.bump(:container_name_match_failed)
        end
      elsif record.has_key?('CONTAINER_NAME') && record['CONTAINER_NAME'].start_with?('k8s_')
        log.debug "Error: no container name and id in record #{record}"
        @stats.bump(:container_name_id_missing)
      end
      metadata
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
