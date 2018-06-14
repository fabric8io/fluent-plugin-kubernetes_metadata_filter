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
  module WatchNamespace

    include ::KubernetesMetadata::Common

    def start_namespace_watch
      begin
        watcher = @client.watch_namespaces({:name => @metadata_source.namespace_name})
      rescue Exception => e
        message = "start_namespace_watch: Exception encountered setting up namespace watch from Kubernetes API #{@apiVersion} endpoint #{@kubernetes_url}: #{e.message}"
        message += " (#{e.response})" if e.respond_to?(:response)
        raise Fluent::ConfigError, message
      end

      watcher.each do |notice|
        case notice.type
          when 'MODIFIED', 'ADDED'
            @namespace_metadata = parse_namespace_metadata(notice.object)
            @stats.bump(:namespace_cache_watch_updates)
          else
            # ignore and let age out for cases where 
            # deleted but still processing logs
            @stats.bump(:namespace_cache_watch_ignored)
        end
      end
    end

  end
end
