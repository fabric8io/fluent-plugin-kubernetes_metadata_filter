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
  module CacheStrategy

    def get_pod_metadata(key, namespace_name, pod_name, record_create_time, batch_miss_cache)
      metadata = {}
      ids = @id_cache[key]
      if !ids.nil?
        # FAST PATH
        # Cache hit, fetch metadata from the cache
        metadata = @cache.fetch(ids[:pod_id]) do
          @stats.bump(:pod_cache_miss)
          m = fetch_pod_metadata(namespace_name, pod_name)
          (m.nil? || m.empty?) ? {'pod_id'=>ids[:pod_id]} : m
        end
        metadata.merge!(@namespace_cache.fetch(ids[:namespace_id]) do
          @stats.bump(:namespace_cache_miss)
          m = fetch_namespace_metadata(namespace_name)
          (m.nil? || m.empty?) ?  {'namespace_id'=>ids[:namespace_id]} : m
        end)
      else
        # SLOW PATH
        @stats.bump(:id_cache_miss)
        return batch_miss_cache["#{namespace_name}_#{pod_name}"] if batch_miss_cache.key?("#{namespace_name}_#{pod_name}")
        pod_metadata = fetch_pod_metadata(namespace_name, pod_name)
        namespace_metadata = fetch_namespace_metadata(namespace_name)
        ids = { :pod_id=> pod_metadata['pod_id'], :namespace_id => namespace_metadata['namespace_id'] }
        if !ids[:pod_id].nil? && !ids[:namespace_id].nil?
          # pod found and namespace found
          metadata = pod_metadata
          metadata.merge!(namespace_metadata)
        else
          if ids[:pod_id].nil? && !ids[:namespace_id].nil?
            # pod not found, but namespace found
            @stats.bump(:id_cache_pod_not_found_namespace)
            ns_time = Time.parse(namespace_metadata['creation_timestamp'])
            if ns_time <= record_create_time
              # namespace is older then record for pod
              ids[:pod_id] = key
              metadata = @cache.fetch(ids[:pod_id]) do
                m = { 'pod_id' => ids[:pod_id] }
              end
            end
            metadata.merge!(namespace_metadata)
          else
            if !ids[:pod_id].nil? && ids[:namespace_id].nil?
              # pod found, but namespace NOT found
              # this should NEVER be possible since pod meta can
              # only be retrieved with a namespace
              @stats.bump(:id_cache_namespace_not_found_pod)
            else
              # nothing found
              @stats.bump(:id_cache_orphaned_record)
            end
            if @allow_orphans
              log.trace("orphaning message for: #{namespace_name}/#{pod_name} ") if log.trace?
              metadata = {
                'orphaned_namespace' => namespace_name,
                'namespace_name' => @orphaned_namespace_name,
                'namespace_id' => @orphaned_namespace_id
              }
            else
              metadata = {}
            end
            batch_miss_cache["#{namespace_name}_#{pod_name}"] = metadata
          end
        end
        @id_cache[key] = ids unless batch_miss_cache.key?("#{namespace_name}_#{pod_name}")
      end
      # remove namespace info that is only used for comparison
      metadata.delete('creation_timestamp')
      metadata.delete_if{|k,v| v.nil?}
    end

  end
end
