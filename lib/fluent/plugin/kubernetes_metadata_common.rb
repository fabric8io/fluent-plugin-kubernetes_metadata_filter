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
  module Common
    class GoneError < StandardError
      def initialize(msg = '410 Gone')
        super
      end
    end

    def match_annotations(annotations)
      result = {}
      @annotations_regexps.each do |regexp|
        annotations.each do |key, value|
          result[key] = value if ::Fluent::StringUtil.match_regexp(regexp, key.to_s)
        end
      end
      result
    end

    def parse_namespace_metadata(namespace_object) # rubocop:disable Metrics/AbcSize
      labels = ''
      labels = syms_to_strs(namespace_object[:metadata][:labels].to_h) unless @skip_labels || @skip_namespace_labels
      annotations = match_annotations(syms_to_strs(namespace_object[:metadata][:annotations].to_h))

      kubernetes_metadata = {
        'namespace_id' => namespace_object[:metadata][:uid],
        'creation_timestamp' => namespace_object[:metadata][:creationTimestamp]
      }
      kubernetes_metadata['namespace_labels'] = labels unless labels.empty?
      kubernetes_metadata['namespace_annotations'] = annotations unless annotations.empty?
      kubernetes_metadata
    end

    def parse_pod_metadata(pod_object) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      labels = ''
      labels = syms_to_strs(pod_object[:metadata][:labels].to_h) unless @skip_labels || @skip_pod_labels
      annotations = match_annotations(syms_to_strs(pod_object[:metadata][:annotations].to_h))

      # collect container information
      container_meta = {}
      begin
        if pod_object[:status] && pod_object[:status][:containerStatuses]
          pod_object[:status][:containerStatuses].each do |container_status|
            container_id = (container_status[:containerID] || '').sub(%r{^[-_a-zA-Z0-9]+://}, '')
            key = container_status[:name]
            container_meta[key] = if @skip_container_metadata
                                    {
                                      'name' => container_status[:name]
                                    }
                                  else
                                    {
                                      'name' => container_status[:name],
                                      'image' => container_status[:image],
                                      'image_id' => container_status[:imageID],
                                      :containerID => container_id
                                    }
                                  end
          end
        end
      rescue StandardError => e
        log.warn("parsing container meta information failed for: #{pod_object[:metadata][:namespace]}/#{pod_object[:metadata][:name]}: #{e}") # rubocop:disable Layout/LineLength
      end

      ownerrefs_meta = []
      if @include_ownerrefs_metadata && pod_object[:metadata][:ownerReferences]
        begin
          pod_object[:metadata][:ownerReferences].each do |owner_reference|
            ownerrefs_meta.append({ 'kind' => owner_reference[:kind], 'name' => owner_reference[:name] })
          end
        rescue StandardError => e
          log.warn(
            "parsing ownerrefs meta information failed for: #{pod_object[:metadata][:namespace]}/#{pod_object[:metadata][:name]}: #{e}" # rubocop:disable Layout/LineLength
          )
        end
      end

      kubernetes_metadata = {
        'namespace_name' => pod_object[:metadata][:namespace],
        'pod_id' => pod_object[:metadata][:uid],
        'pod_name' => pod_object[:metadata][:name],
        'pod_ip' => pod_object[:status][:podIP],
        'containers' => syms_to_strs(container_meta),
        'host' => pod_object[:spec][:nodeName],
        'ownerrefs' => (ownerrefs_meta if @include_ownerrefs_metadata)
      }.compact
      kubernetes_metadata['labels'] = labels unless labels.empty?
      kubernetes_metadata['annotations'] = annotations unless annotations.empty?
      kubernetes_metadata['master_url'] = @kubernetes_url unless @skip_master_url
      kubernetes_metadata
    end

    def syms_to_strs(hsh)
      newhsh = {}
      hsh.each_pair do |kk, vv|
        vv = syms_to_strs(vv) if vv.is_a?(Hash)
        if kk.is_a?(Symbol)
          newhsh[kk.to_s] = vv
        else
          newhsh[kk] = vv
        end
      end
      newhsh
    end
  end
end
