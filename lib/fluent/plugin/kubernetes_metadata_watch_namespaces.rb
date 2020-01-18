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
  module WatchNamespaces

    include ::KubernetesMetadata::Common

    def start_namespace_watch
      get_namespaces_and_start_watcher
    rescue Exception => e
      message = "start_namespace_watch: Exception encountered setting up " \
                "namespace watch from Kubernetes API #{@apiVersion} endpoint " \
                "#{@kubernetes_url}: #{e.message}"
      message += " (#{e.response})" if e.respond_to?(:response)
      log.debug(message)

      raise Fluent::ConfigError, message
    end

    # List all namespaces, record the resourceVersion and return a watcher
    # starting from that resourceVersion.
    def get_namespaces_and_start_watcher
      options = {
        resource_version: '0'  # Fetch from API server.
      }
      namespaces = @client.get_namespaces(options)
      namespaces.each do |namespace|
        cache_key = namespace.metadata['uid']
        @namespace_cache[cache_key] = parse_namespace_metadata(namespace)
        @stats.bump(:namespace_cache_host_updates)
      end
      options[:resource_version] = namespaces.resourceVersion
      watcher = @client.watch_namespaces(options)
      Thread.current[:namespace_watcher_alive] = true
      watcher
    end

    # Reset the namespace watcher if it's not alive.
    def reset_namespace_watcher_if_needed(watcher)
      if Thread.current[:namespace_watcher_alive]
        watcher
      else
        get_namespaces_and_start_watcher
      end
    end

    # Given a watcher, process the notices and handle retries by resetting the
    # watcher if needed.
    def process_namespace_watcher_notices_with_retries(watcher)
      watcher.each do |notice|
        case notice.type
          when 'MODIFIED'
            cache_key = notice.object['metadata']['uid']
            cached    = @namespace_cache[cache_key]
            if cached
              @namespace_cache[cache_key] = parse_namespace_metadata(notice.object)
              @stats.bump(:namespace_cache_watch_updates)
            else
              @stats.bump(:namespace_cache_watch_misses)
            end
          when 'DELETED'
            # ignore and let age out for cases where
            # deleted but still processing logs
            @stats.bump(:namespace_cache_watch_deletes_ignored)
          else
            # Don't pay attention to creations, since the created namespace may not
            # be used by any namespace on this node.
            @stats.bump(:namespace_cache_watch_ignored)
        end
      end
    rescue Exception => e
      # Instead of raising exceptions and crashing Fluentd, swallow the
      # exception and reset the watcher.
      log.info "Exception encountered parsing namespace watch event. " \
               "The connection might have been closed. " \
               "Resetting the namespace watcher.", e
      Thread.current[:namespace_watcher_alive] = false
      sleep(@watch_retry_interval)
    end
  end
end
