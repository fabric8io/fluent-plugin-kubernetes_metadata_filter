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
require_relative 'kubernetes_metadata_common'

module KubernetesMetadata
  module WatchPods

    include ::KubernetesMetadata::Common

    def start_pod_watch
      begin
        options = {
          resource_version: '0'  # Fetch from API server.
        }
        if ENV['K8S_NODE_NAME']
          options[:field_selector] = 'spec.nodeName=' + ENV['K8S_NODE_NAME']
        end
        pods = @client.get_pods(options)
        pods.each do |pod|
          cache_key = pod.metadata['uid']
          @cache[cache_key] = parse_pod_metadata(pod)
          @stats.bump(:pod_cache_host_updates)
        end
        options[:resource_version] = pods.resourceVersion
        watcher = @client.watch_pods(options)
      rescue Exception => e
        message = "start_pod_watch: Exception encountered setting up pod watch from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}: #{e.message}"
        message += " (#{e.response})" if e.respond_to?(:response)
        log.debug(message)

        raise Fluent::ConfigError, message
      end

      watcher.each do |notice|
        case notice.type
          when 'MODIFIED'
            cache_key = notice.object['metadata']['uid']
            cached    = @cache[cache_key]
            if cached
              @cache[cache_key] = parse_pod_metadata(notice.object)
              @stats.bump(:pod_cache_watch_updates)
            elsif ENV['K8S_NODE_NAME'] == notice.object['spec']['nodeName'] then
              @cache[cache_key] = parse_pod_metadata(notice.object)
              @stats.bump(:pod_cache_host_updates)
            else
              @stats.bump(:pod_cache_watch_misses)
            end
          when 'DELETED'
            # ignore and let age out for cases where pods
            # deleted but still processing logs
            @stats.bump(:pod_cache_watch_delete_ignored)
          else
            # Don't pay attention to creations, since the created pod may not
            # end up on this node.
            @stats.bump(:pod_cache_watch_ignored)
        end
      end
    end
  end
end
