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

    def set_up_pod_thread
      # Any failures / exceptions in the initial setup should raise
      # Fluent:ConfigError, so that users can inspect potential errors in
      # the configuration.
      pod_watcher = start_pod_watch
      Thread.current[:pod_watch_retry_backoff_interval] = @watch_retry_interval
      Thread.current[:pod_watch_retry_count] = 0

      # Any failures / exceptions in the followup watcher notice
      # processing will be swallowed and retried. These failures /
      # exceptions could be caused by Kubernetes API being temporarily
      # down. We assume the configuration is correct at this point.
      while thread_current_running?
        begin
          pod_watcher ||= get_pods_and_start_watcher
          process_pod_watcher_notices(pod_watcher)
        rescue Exception => e
          @stats.bump(:pod_watch_failures)
          if Thread.current[:pod_watch_retry_count] < @watch_retry_max_times
            # Instead of raising exceptions and crashing Fluentd, swallow
            # the exception and reset the watcher.
            log.info(
              "Exception encountered parsing pod watch event. The " \
              "connection might have been closed. Sleeping for " \
              "#{Thread.current[:pod_watch_retry_backoff_interval]} " \
              "seconds and resetting the pod watcher.", e)
            sleep(Thread.current[:pod_watch_retry_backoff_interval])
            Thread.current[:pod_watch_retry_count] += 1
            Thread.current[:pod_watch_retry_backoff_interval] *= @watch_retry_exponential_backoff_base
            pod_watcher = nil
          else
            # Since retries failed for many times, log as errors instead
            # of info and raise exceptions and trigger Fluentd to restart.
            message =
              "Exception encountered parsing pod watch event. The " \
              "connection might have been closed. Retried " \
              "#{@watch_retry_max_times} times yet still failing. Restarting."
            log.error(message, e)
            raise Fluent::UnrecoverableError.new(message)
          end
        end
      end
    end

    def start_pod_watch
      get_pods_and_start_watcher
    rescue Exception => e
      message = "start_pod_watch: Exception encountered setting up pod watch " \
                "from Kubernetes API #{@apiVersion} endpoint " \
                "#{@kubernetes_url}: #{e.message}"
      message += " (#{e.response})" if e.respond_to?(:response)
      log.debug(message)

      raise Fluent::ConfigError, message
    end

    # List all pods, record the resourceVersion and return a watcher starting
    # from that resourceVersion.
    def get_pods_and_start_watcher
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
      watcher
    end

    # Process a watcher notice and potentially raise an exception.
    def process_pod_watcher_notices(watcher)
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
