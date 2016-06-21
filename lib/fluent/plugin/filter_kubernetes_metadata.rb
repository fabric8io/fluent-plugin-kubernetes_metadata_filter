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
    config_param :include_namespace_id, :bool, default: false
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
    config_param :container_name_to_kubernetes_regexp,
                 :string,
                 :default => '^k8s_(?<container_name>[^\.]+)\.[^_]+_(?<pod_name>[^_]+)_(?<namespace>[^_]+)_[^_]+_[a-f0-9]{8}$'

    ANNOTATIONS_MAX_NUM = 10
    (1..ANNOTATIONS_MAX_NUM).each {|i| config_param :"annotation_match#{i}", :string, default: nil }

    def syms_to_strs(hsh)
      newhsh = {}
      hsh.each_pair do |kk,vv|
        if vv.is_a?(Hash)
          vv = syms_to_strs(vv)
        end
        if kk.is_a?(Symbol)
          newhsh[kk.to_s] = vv
        else
          newhsh[kk] = vv
        end
      end
      newhsh
    end

    def get_metadata(namespace_name, pod_name, container_name)
      begin
        metadata = @client.get_pod(pod_name, namespace_name)
        return if !metadata
        labels = syms_to_strs(metadata['metadata']['labels'].to_h)
        annotations = match_annotations(syms_to_strs(metadata['metadata']['annotations'].to_h))
        if @de_dot
          self.de_dot!(labels)
        end
        kubernetes_metadata = {
            'namespace_name' => namespace_name,
            'pod_id'         => metadata['metadata']['uid'],
            'pod_name'       => pod_name,
            'container_name' => container_name,
            'labels'         => labels,
            'host'           => metadata['spec']['nodeName']
        }
        kubernetes_metadata['annotations'] = annotations unless annotations.empty?
        return kubernetes_metadata
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
          thread = Thread.new(self) { |this| this.start_watch }
          thread.abort_on_exception = true
          if @include_namespace_id
            namespace_thread = Thread.new(self) { |this| this.start_namespace_watch }
            namespace_thread.abort_on_exception = true
          end
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
      (1..ANNOTATIONS_MAX_NUM).each do |i|
        next unless conf.key? "annotation_match#{i}"
        regexp = conf["annotation_match#{i}"]
        @annotations_regexps << Regexp.compile(regexp)
      end

    end

    def filter_stream_from_files(tag, es)
      new_es = MultiEventStream.new

      match_data = tag.match(@tag_to_kubernetes_name_regexp_compiled)

      if match_data
        metadata = {
          'docker' => {
            'container_id' => match_data['docker_id']
          },
          'kubernetes' => {
            'namespace_name' => match_data['namespace'],
            'pod_name'       => match_data['pod_name'],
            'container_name' => match_data['container_name']
          }
        }

        if @kubernetes_url.present?
          cache_key = "#{metadata['kubernetes']['namespace_name']}_#{metadata['kubernetes']['pod_name']}_#{metadata['kubernetes']['container_name']}"

          this     = self
          metadata = @cache.getset(cache_key) {
            if metadata
              kubernetes_metadata = this.get_metadata(
                metadata['kubernetes']['namespace_name'],
                metadata['kubernetes']['pod_name'],
                metadata['kubernetes']['container_name']
              )
              metadata['kubernetes'] = kubernetes_metadata if kubernetes_metadata
              metadata
            end
          }
          if @include_namespace_id
            namespace_name = metadata['kubernetes']['namespace_name']
            namespace_id = @namespace_cache.getset(namespace_name) {
              namespace = @client.get_namespace(namespace_name)
              namespace['metadata']['uid'] if namespace
            }
            metadata['kubernetes']['namespace_id'] = namespace_id if namespace_id
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

    def filter_stream_from_journal(tag, es)
      new_es = MultiEventStream.new

      es.each { |time, record|
        record = merge_json_log(record) if @merge_json_log

        metadata = nil
        if record.has_key?('CONTAINER_NAME') && record.has_key?('CONTAINER_ID_FULL')
          metadata = record['CONTAINER_NAME'].match(@container_name_to_kubernetes_regexp_compiled) do |match_data|
            metadata = {
              'docker' => {
                'container_id' => record['CONTAINER_ID_FULL']
              },
              'kubernetes' => {
                'namespace_name' => match_data['namespace'],
                'pod_name'       => match_data['pod_name'],
                'container_name' => match_data['container_name']
              }
            }
            if @kubernetes_url.present?
              cache_key = "#{metadata['kubernetes']['namespace_name']}_#{metadata['kubernetes']['pod_name']}_#{metadata['kubernetes']['container_name']}"

              this     = self
              metadata = @cache.getset(cache_key) {
                if metadata
                  kubernetes_metadata = this.get_metadata(
                    metadata['kubernetes']['namespace_name'],
                    metadata['kubernetes']['pod_name'],
                    metadata['kubernetes']['container_name']
                  )
                  metadata['kubernetes'] = kubernetes_metadata if kubernetes_metadata
                  metadata
                end
              }
              if @include_namespace_id
                namespace_name = metadata['kubernetes']['namespace_name']
                namespace_id = @namespace_cache.getset(namespace_name) {
                  namespace = @client.get_namespace(namespace_name)
                  namespace['metadata']['uid'] if namespace
                }
                metadata['kubernetes']['namespace_id'] = namespace_id if namespace_id
              end
            end
            metadata
          end
          unless metadata
            log.debug "Error: could not match CONTAINER_NAME from record #{record}"
          end
        elsif record.has_key?('CONTAINER_NAME') && record['CONTAINER_NAME'].start_with?('k8s_')
          log.debug "Error: no container name and id in record #{record}"
        end

        if metadata
          record = record.merge(metadata)
        end

        new_es.add(time, record)
      }

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
          h[newref] = v
        end
      end
    end

    def match_annotations(annotations)
      result = {}
      annotations.each do |key, value|
        @annotations_regexps.each do |regexp|
          if ::Fluent::StringUtil.match_regexp(regexp, key.to_s)
            result[key] = value
          end
        end
      end
      result
    end

    def start_watch
      begin
        resource_version = @client.get_pods.resourceVersion
        watcher          = @client.watch_pods(resource_version)
      rescue Exception => e
        raise Fluent::ConfigError, "Exception encountered fetching metadata from Kubernetes API endpoint: #{e.message}"
      end

      watcher.each do |notice|
        case notice.type
          when 'MODIFIED'
            if notice.object.status.containerStatuses
              pod_cache_key = "#{notice.object['metadata']['namespace']}_#{notice.object['metadata']['name']}"
              notice.object.status.containerStatuses.each { |container_status|
                cache_key = "#{pod_cache_key}_#{container_status['name']}"
                cached    = @cache[cache_key]
                if cached
                  # Only thing that can be modified is labels and (possibly) annotations
                  labels = syms_to_strs(notice.object.metadata.labels.to_h)
                  annotations = match_annotations(syms_to_strs(notice.object.metadata.annotations.to_h))
                  if @de_dot
                    self.de_dot!(labels)
                  end
                  cached['kubernetes']['labels'] = labels
                  cached['kubernetes']['annotations'] = annotations unless annotations.empty?
                  @cache[cache_key] = cached
                end
              }
            end
          when 'DELETED'
            if notice.object.status.containerStatuses
              pod_cache_key = "#{notice.object['metadata']['namespace']}_#{notice.object['metadata']['name']}"
              notice.object.status.containerStatuses.each { |container_status|
                cache_key = "#{pod_cache_key}_#{container_status['name']}"
                @cache.delete(cache_key)
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
            @namespace_cache.delete(notice.object['metadata']['name'])
          else
            # We only care about each namespace's name and UID, neither of which
            # is modifiable, so we only have to care about deletions.
        end
      end
    end
  end
end
