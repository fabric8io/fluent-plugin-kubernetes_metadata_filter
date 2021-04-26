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
module KubernetesMetadata
  module SimpleCacheStrategy

    def is_pod_cached?(pod)
      return false if pod.nil?
      @cache.has_key?("#{pod[:metadata][:namespace]}_#{pod[:metadata][:name]}")
    end
    
    def is_namespace_cached?(namespace)
      return false if namespace.nil?
      @namespace_cache.has_key?("#{namespace[:metadata][:namespace]}")
    end

    def cache_pod_metadata(pod)
      cache_key = "#{pod[:metadata][:namespace]}_#{pod[:metadata][:name]}"
      @cache[cache_key] = parse_pod_metadata(pod)
    end

    def cache_namespace_metadata(namespace)
        cache_key = namespace[:metadata][:uid]
        @namespace_cache[cache_key] = parse_namespace_metadata(namespace)
    end

    def get_pod_metadata(key, namespace_name, pod_name, record_create_time, batch_miss_cache)
      metadata = {}
      cache_key = "#{namespace_name}_#{pod_name}"

      # Do not continually hit apiserver when batch processing if we already know
      # it will return nothing
      if batch_miss_cache.key?(cache_key)
        return  batch_miss_cache[cache_key]
      end

      metadata = @cache.fetch(cache_key) do
        @stats.bump(:pod_cache_miss)
        m = fetch_pod_metadata(namespace_name, pod_name)
        ns_meta = @namespace_cache.fetch(namespace_name) do
            @stats.bump(:namespace_cache_miss)
            fetch_namespace_metadata(namespace_name)
        end unless @skip_namespace_metadata
        metadata = m.merge(ns_meta||{})
        batch_miss_cache[cache_key] = metadata if m.empty?
        metadata
      end
      metadata.delete_if { |_k, v| v.nil? }
    end

  end
end
