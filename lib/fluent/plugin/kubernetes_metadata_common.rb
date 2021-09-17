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
          if ::Fluent::StringUtil.match_regexp(regexp, key.to_s)
            result[key] = value
          end
        end
      end
      result
    end

    def parse_namespace_metadata(namespace_object)
      labels = ''
      labels = syms_to_strs(namespace_object[:metadata][:labels].to_h) unless @skip_labels

      annotations = match_annotations(syms_to_strs(namespace_object[:metadata][:annotations].to_h))
      if @de_dot
        de_dot!(labels) unless @skip_labels
        de_dot!(annotations)
      end
      if @de_slash
        de_slash!(labels) unless @skip_labels
        de_slash!(annotations)
      end
      kubernetes_metadata = {
        'namespace_id' => namespace_object[:metadata][:uid],
        'creation_timestamp' => namespace_object[:metadata][:creationTimestamp]
      }
      kubernetes_metadata['namespace_labels'] = labels unless labels.empty?
      kubernetes_metadata['namespace_annotations'] = annotations unless annotations.empty?
      kubernetes_metadata
    end

    def parse_pod_metadata(pod_object)
      labels = ''
      labels = syms_to_strs(pod_object[:metadata][:labels].to_h) unless @skip_labels

      annotations = match_annotations(syms_to_strs(pod_object[:metadata][:annotations].to_h))
      if @de_dot
        de_dot!(labels) unless @skip_labels
        de_dot!(annotations)
      end
      if @de_slash
        de_slash!(labels) unless @skip_labels
        de_slash!(annotations)
      end

      # collect container information
      container_meta = {}
      begin
        pod_object[:status][:containerStatuses].each do |container_status|
          # get plain container id (eg. docker://hash -> hash)
          container_id = container_status[:containerID].sub(%r{^[-_a-zA-Z0-9]+://}, '')
          container_meta[container_id] = if @skip_container_metadata
                                           {
                                             'name' => container_status[:name]
                                           }
                                         else
                                           {
                                             'name' => container_status[:name],
                                             'image' => container_status[:image],
                                             'image_id' => container_status[:imageID]
                                           }
                                         end
        end
      rescue StandardError=>e
        log.warn("parsing container meta information failed for: #{pod_object[:metadata][:namespace]}/#{pod_object[:metadata][:name]}: #{e}")
      end

      kubernetes_metadata = {
        'namespace_name' => pod_object[:metadata][:namespace],
        'pod_id' => pod_object[:metadata][:uid],
        'pod_name' => pod_object[:metadata][:name],
        'pod_ip' => pod_object[:status][:podIP],
        'containers' => syms_to_strs(container_meta),
        'host' => pod_object[:spec][:nodeName]
      }
      kubernetes_metadata['annotations'] = annotations unless annotations.empty?
      kubernetes_metadata['labels'] = labels unless labels.empty?
      kubernetes_metadata['master_url'] = @kubernetes_url unless @skip_master_url
      kubernetes_metadata
    end

    def syms_to_strs(hsh)
      newhsh = {}
      hsh.each_pair do |kk, vv|
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
  end
end
