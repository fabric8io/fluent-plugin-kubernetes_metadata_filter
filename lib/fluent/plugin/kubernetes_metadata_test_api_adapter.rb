# frozen_string_literal: true

#
# Fluentd Kubernetes Metadata Filter Plugin - Enrich Fluentd events with
# Kubernetes metadata
#
# Copyright 2021 Red Hat, Inc.
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

require 'kubeclient'

module KubernetesMetadata
  module TestApiAdapter
    def api_valid?
      true
    end

    def get_namespace(namespace_name, _unused, _options)
      {
        metadata: {
          name: namespace_name,
          uid: "#{namespace_name}uuid",
          labels: {
            foo_ns: 'bar_ns'
          }
        }
      }
    end

    def get_pod(pod_name, namespace_name, _options) # rubocop:disable Metrics/MethodLength
      {
        metadata: {
          name: pod_name,
          namespace: namespace_name,
          uid: "#{namespace_name}#{namespace_name}uuid",
          labels: {
            foo: 'bar'
          }
        },
        spec: {
          nodeName: 'aNodeName',
          containers: [
            {
              name: 'foo',
              image: 'bar'
            },
            {
              name: 'bar',
              image: 'foo'
            }
          ]
        },
        status: {
          podIP: '172.17.0.8'
        }
      }
    end
  end
end
