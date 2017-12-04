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
      labels = syms_to_strs(namespace_object['metadata']['labels'].to_h)
      annotations = match_annotations(syms_to_strs(namespace_object['metadata']['annotations'].to_h))
      if @de_dot
        self.de_dot!(labels)
        self.de_dot!(annotations)
      end
      kubernetes_metadata = {
        'namespace_id' => namespace_object['metadata']['uid'],
        'creation_timestamp' => namespace_object['metadata']['creationTimestamp']
      }
      kubernetes_metadata['namespace_labels'] = labels unless labels.empty?
      kubernetes_metadata['namespace_annotations'] = annotations unless annotations.empty?
      return kubernetes_metadata
    end

    def parse_pod_metadata(pod_object)
      labels = syms_to_strs(pod_object['metadata']['labels'].to_h)
      annotations = match_annotations(syms_to_strs(pod_object['metadata']['annotations'].to_h))
      if @de_dot
        self.de_dot!(labels)
        self.de_dot!(annotations)
      end
      kubernetes_metadata = {
          'namespace_name' => pod_object['metadata']['namespace'],
          'pod_id'         => pod_object['metadata']['uid'],
          'pod_name'       => pod_object['metadata']['name'],
          'labels'         => labels,
          'host'           => pod_object['spec']['nodeName'],
          'master_url'     => @kubernetes_url
      }
      kubernetes_metadata['annotations'] = annotations unless annotations.empty?
      return kubernetes_metadata
    end

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

  end
end
