# frozen_string_literal: true

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
require 'resolv'

module Fluent
  module Plugin
    class KubernetesMetadataFilter < Fluent::Plugin::Filter # rubocop:disable Metrics/ClassLength
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
      config_param :ignore_nil, :integer, default: true
      config_param :watch, :bool, default: true
      config_param :apiVersion, :string, default: 'v1'
      config_param :client_cert, :string, default: nil
      config_param :client_key, :string, default: nil
      config_param :ca_file, :string, default: nil
      config_param :verify_ssl, :bool, default: true
      config_param :open_timeout, :integer, default: 3
      config_param :read_timeout, :integer, default: 10

      REGEX_VAR_LOG_PODS = '(var\.log\.pods)\.(?<namespace>[^_]+)_(?<pod_name>[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<pod_uuid>[a-z0-9-]*)\.(?<container_name>.+)\..*\.log$' # rubocop:disable Layout/LineLength
      REGEX_VAR_LOG_CONTAINERS = '(var\.log\.containers)\.(?<pod_name>[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<namespace>[^_]+)_(?<container_name>.+)-(?<docker_id>[a-z0-9]{64})\.log$' # rubocop:disable Layout/LineLength

      # tag_to_kubernetes_name_regexp which must include named capture groups:
      #  namespace            - The namespace in which the pod is deployed
      #  pod_name             - The pod name
      #  container_name       - The name of the container
      #  pod_uuid (/var/log/pods) | docker_id (/var/log/containers) - Unique identifier used in caching of either
      #                                                               pod_uuid or the container hash
      config_param :tag_to_kubernetes_name_regexp, :string,
                   default: "(#{REGEX_VAR_LOG_PODS}|#{REGEX_VAR_LOG_CONTAINERS})"

      config_param :bearer_token_file, :string, default: nil
      config_param :secret_dir, :string, default: '/var/run/secrets/kubernetes.io/serviceaccount'

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
      config_param :skip_pod_labels, :bool, default: false
      config_param :skip_namespace_labels, :bool, default: false
      config_param :skip_container_metadata, :bool, default: false
      config_param :skip_master_url, :bool, default: false
      config_param :skip_namespace_metadata, :bool, default: false
      config_param :include_ownerrefs_metadata, :bool, default: false

      # A classname in the form of Test::APIAdapter which will try
      # to be resolved from a relative named file 'test_api_adapter'
      config_param :test_api_adapter, :string, default: nil

      # The time interval in seconds for retry backoffs when watch connections fail.
      config_param :watch_retry_interval, :integer, default: 1
      # The base number of exponential backoff for retries.
      config_param :watch_retry_exponential_backoff_base, :integer, default: 2
      # The maximum number of times to retry pod and namespace watches.
      config_param :watch_retry_max_times, :integer, default: 10

      def fetch_pod_metadata(namespace_name, pod_name) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        log.trace("fetching pod metadata: #{namespace_name}/#{pod_name}")
        options = {
          resource_version: '0' # Fetch from API server cache instead of etcd quorum read
        }
        pod_object = @client.get_pod(pod_name, namespace_name, options)
        log.trace("raw metadata for #{namespace_name}/#{pod_name}: #{pod_object}")
        metadata = parse_pod_metadata(pod_object)
        @stats.bump(:pod_cache_api_updates)
        log.trace("parsed metadata for #{namespace_name}/#{pod_name}: #{metadata}")
        @cache[metadata['pod_id']] = metadata
      rescue KubeException => e
        if e.error_code == 401
          # recreate client to refresh token
          log.info("Encountered '401 Unauthorized' exception, recreating client to refresh token")
          create_client
        elsif e.error_code == 404
          log.debug("Encountered '404 Not Found' exception, pod not found")
          @stats.bump(:pod_cache_api_nil_error)
        else
          log.error("Exception '#{e}' encountered fetching pod metadata from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}") # rubocop:disable Layout/LineLength
          @stats.bump(:pod_cache_api_nil_error)
        end
        {}
      rescue StandardError => e
        @stats.bump(:pod_cache_api_nil_error)
        log.error("Exception '#{e}' encountered fetching pod metadata from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}") # rubocop:disable Layout/LineLength
        {}
      end

      def dump_stats # rubocop:disable Metrics/AbcSize
        @curr_time = Time.now
        return if @curr_time.to_i - @prev_time.to_i < @stats_interval

        @prev_time = @curr_time
        @stats.set(:pod_cache_size, @cache.count)
        @stats.set(:namespace_cache_size, @namespace_cache.count) if @namespace_cache
        log.info(@stats)
        return unless log.level == Fluent::Log::LEVEL_TRACE

        log.trace("       id cache: #{@id_cache.to_a}")
        log.trace("      pod cache: #{@cache.to_a}")
        log.trace("namespace cache: #{@namespace_cache.to_a}")
      end

      def fetch_namespace_metadata(namespace_name) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        log.trace("fetching namespace metadata: #{namespace_name}")
        options = {
          resource_version: '0' # Fetch from API server cache instead of etcd quorum read
        }
        namespace_object = @client.get_namespace(namespace_name, nil, options)
        log.trace("raw metadata for #{namespace_name}: #{namespace_object}")
        metadata = parse_namespace_metadata(namespace_object)
        @stats.bump(:namespace_cache_api_updates)
        log.trace("parsed metadata for #{namespace_name}: #{metadata}")
        @namespace_cache[metadata['namespace_id']] = metadata
      rescue KubeException => e
        if e.error_code == 401
          # recreate client to refresh token
          log.info("Encountered '401 Unauthorized' exception, recreating client to refresh token")
          create_client
        else
          log.error("Exception '#{e}' encountered fetching namespace metadata from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}") # rubocop:disable Layout/LineLength
          @stats.bump(:namespace_cache_api_nil_error)
        end
        {}
      rescue StandardError => e
        @stats.bump(:namespace_cache_api_nil_error)
        log.error("Exception '#{e}' encountered fetching namespace metadata from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}") # rubocop:disable Layout/LineLength
        {}
      end

      def initialize
        super
        @prev_time = Time.now
        @ssl_options = {}
        @auth_options = {}
      end

      def configure(conf) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        super

        require 'kubeclient'
        require 'lru_redux'

        @stats = KubernetesMetadata::Stats.new
        if @stats_interval <= 0
          @stats = KubernetesMetadata::NoOpStats.new
          define_singleton_method(:dump_stats) {} # rubocop:disable Lint/EmptyBlock
        end

        if @cache_ttl < 0
          log.info 'Setting the cache TTL to :none because it was <= 0'
          @cache_ttl = :none
        end

        # Caches pod/namespace UID tuples for a given container UID.
        @id_cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl, @ignore_nil)

        # Use the container UID as the key to fetch a hash containing pod metadata
        @cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl, @ignore_nil)

        # Use the namespace UID as the key to fetch a hash containing namespace metadata
        @namespace_cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl, @ignore_nil)

        @tag_to_kubernetes_name_regexp_compiled = Regexp.compile(@tag_to_kubernetes_name_regexp)

        # Use Kubernetes default service account if we're in a pod.
        if @kubernetes_url.nil?
          log.debug('Kubernetes URL is not set - inspecting environ')
          env_host = ENV['KUBERNETES_SERVICE_HOST']
          env_port = ENV['KUBERNETES_SERVICE_PORT']

          if present?(env_host) && present?(env_port)
            if Resolv::IPv6::Regex.match?(env_host)
              # Brackets are needed around IPv6 addresses
              env_host = "[#{env_host}]"
            end
            @kubernetes_url = "https://#{env_host}:#{env_port}/api"
            log.debug("Kubernetes URL is now '#{@kubernetes_url}'")
          else
            log.debug('No Kubernetes URL could be found in config or environ')
          end
        end

        # Use SSL certificate and bearer token from Kubernetes service account.
        if Dir.exist?(@secret_dir)
          log.debug("Found directory with secrets: #{@secret_dir}")
          ca_cert = File.join(@secret_dir, K8_POD_CA_CERT)
          pod_token = File.join(@secret_dir, K8_POD_TOKEN)

          if !present?(@ca_file) && File.exist?(ca_cert)
            log.debug("Found CA certificate: #{ca_cert}")
            @ca_file = ca_cert
          end

          if !present?(@bearer_token_file) && File.exist?(pod_token)
            log.debug("Found pod token: #{pod_token}")
            @bearer_token_file = pod_token
          end
        end

        if present?(@kubernetes_url)
          @ssl_options = {
            client_cert: present?(@client_cert) ? OpenSSL::X509::Certificate.new(File.read(@client_cert)) : nil,
            client_key: present?(@client_key) ? OpenSSL::PKey::RSA.new(File.read(@client_key)) : nil,
            ca_file: @ca_file,
            verify_ssl: @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
          }

          if @ssl_partial_chain
            # taken from the ssl.rb OpenSSL::SSL::SSLContext code for DEFAULT_CERT_STORE
            require 'openssl'

            ssl_store = OpenSSL::X509::Store.new
            ssl_store.set_default_paths
            flagval = if defined? OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
                        OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
                      else
                        # this version of ruby does not define OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
                        0x80000
                      end
            ssl_store.flags = OpenSSL::X509::V_FLAG_CRL_CHECK_ALL | flagval
            @ssl_options[:cert_store] = ssl_store
          end

          @auth_options[:bearer_token_file] = @bearer_token_file if present?(@bearer_token_file)

          create_client

          if @test_api_adapter
            log.info "Extending client with test api adapter #{@test_api_adapter}"
            @test_api_adapter = @test_api_adapter.gsub('::', '_')
                                                 .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                                                 .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                                                 .tr('-', '_')
                                                 .downcase
            require_relative @test_api_adapter
            @client.extend(eval(@test_api_adapter)) # rubocop:disable Security/Eval
          end

          begin
            @client.api_valid?
          rescue KubeException => e
            raise Fluent::ConfigError, "Invalid Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}: #{e.message}"
          end

          if @watch
            if ENV['K8S_NODE_NAME'].nil? || ENV['K8S_NODE_NAME'].strip.empty?
              log.warn("!! The environment variable 'K8S_NODE_NAME' is not set to the node name which can affect the API server and watch efficiency !!") # rubocop:disable Layout/LineLength
            end

            pod_thread = Thread.new(self, &:set_up_pod_thread)
            pod_thread.abort_on_exception = true

            namespace_thread = Thread.new(self, &:set_up_namespace_thread)
            namespace_thread.abort_on_exception = true
          end
        end

        @annotations_regexps = []
        @annotation_match.each do |regexp|
          @annotations_regexps << Regexp.compile(regexp)
        rescue RegexpError => e
          log.error("Error: invalid regular expression in annotation_match: #{e}")
        end
      end

      def create_client # rubocop:disable Metrics/MethodLength
        log.debug('Creating K8S client')
        @client = nil
        @client = Kubeclient::Client.new(
          @kubernetes_url,
          @apiVersion,
          ssl_options: @ssl_options,
          auth_options: @auth_options,
          timeouts: {
            open: @open_timeout,
            read: @read_timeout
          },
          as: :parsed_symbolized
        )
      end

      def get_metadata_for_record(namespace_name, pod_name, container_name, cache_key, create_time, batch_miss_cache, # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
                                  docker_id)
        metadata = {
          'docker' => { 'container_id' => '' },
          'kubernetes' => {
            'container_name' => container_name,
            'namespace_name' => namespace_name,
            'pod_name' => pod_name
          }
        }
        metadata['docker']['container_id'] = docker_id unless docker_id.nil?
        container_cache_key = container_name
        if present?(@kubernetes_url)
          pod_metadata = get_pod_metadata(cache_key, namespace_name, pod_name, create_time, batch_miss_cache)
          if (pod_metadata.include? 'containers') && (pod_metadata['containers'].include? container_cache_key) && !@skip_container_metadata # rubocop:disable Layout/LineLength
            metadata['kubernetes']['container_image'] = pod_metadata['containers'][container_cache_key]['image']
            unless pod_metadata['containers'][container_cache_key]['image_id'].empty?
              metadata['kubernetes']['container_image_id'] =
                pod_metadata['containers'][container_cache_key]['image_id']
            end
            unless pod_metadata['containers'][container_cache_key]['containerID'].empty?
              metadata['docker']['container_id'] =
                pod_metadata['containers'][container_cache_key]['containerID']
            end
          end
          metadata['kubernetes'].merge!(pod_metadata) if pod_metadata
          metadata['kubernetes'].delete('containers')
        end
        metadata['kubernetes'].tap do |kube|
          kube.each_pair do |k, v|
            kube[k.dup] = v.dup
          end
        end
        if metadata['docker'] && (metadata['docker']['container_id'].nil? || metadata['docker']['container_id'].empty?)
          metadata.delete('docker')
        end
        metadata
      end

      def filter(tag, time, record) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        tag_match_data = tag.match(@tag_to_kubernetes_name_regexp_compiled)
        batch_miss_cache = {}
        if tag_match_data
          cache_key = if tag_match_data.names.include?('pod_uuid') && !tag_match_data['pod_uuid'].nil?
                        tag_match_data['pod_uuid']
                      else
                        tag_match_data['docker_id']
                      end
          docker_id = tag_match_data.names.include?('docker_id') ? tag_match_data['docker_id'] : nil
          metadata = get_metadata_for_record(
            tag_match_data['namespace'],
            tag_match_data['pod_name'],
            tag_match_data['container_name'],
            cache_key,
            time,
            batch_miss_cache,
            docker_id
          )
        end
        if @lookup_from_k8s_field && record.key?('kubernetes') && record.key?('docker') &&
           record['kubernetes'].respond_to?(:has_key?) && record['docker'].respond_to?(:has_key?) &&
           record['kubernetes'].key?('namespace_name') &&
           record['kubernetes'].key?('pod_name') &&
           record['kubernetes'].key?('container_name') &&
           record['docker'].key?('container_id')
          k_metadata = get_metadata_for_record(
            record['kubernetes']['namespace_name'],
            record['kubernetes']['pod_name'],
            record['kubernetes']['container_name'],
            record['docker']['container_id'],
            time,
            batch_miss_cache,
            record['docker']['container_id']
          )
          metadata = k_metadata if k_metadata
        end
        dump_stats
        metadata ? record.merge(metadata) : record
      end

      # copied from activesupport
      def present?(object)
        object.respond_to?(:empty?) ? !object.empty? : !!object
      end
    end
  end
end
