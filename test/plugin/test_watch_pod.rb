#
# Fluentd Kubernetes Metadata Filter Plugin - Enrich Fluentd events with
# Kubernetes metadata
#
# Copyright 2015 Red Hat, Inc.
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
require_relative '../helper'
require 'ostruct'
require_relative 'watch_test'

class WatchPodTestTest < WatchTest

  include KubernetesMetadata::WatchPod

  setup do
    @added = OpenStruct.new(
      type: 'ADDED',
      object: {
        'metadata' => {
            'name' => 'added',
            'namespace' => 'added',
            'uid' => 'added_uid',
            'labels' => {}
        },
        'spec' => {
            'nodeName' => 'aNodeName',
                'containers' => [{
                'name' => 'foo',
                'image' => 'bar'
            }, {
                'name' => 'bar',
                'image' => 'foo'
            }]
        }
      }
    )
    @modified = OpenStruct.new(
      type: 'MODIFIED',
      object: {
        'metadata' => {
            'name' => 'foo',
            'namespace' => 'modified',
            'uid' => 'modified_uid',
            'labels' => {}
        },
        'spec' => {
            'nodeName' => 'aNodeName',
            'containers' => [{
                'name' => 'foo',
                'image' => 'bar'
            }, {
                'name' => 'bar',
                'image' => 'foo'
            }]
        },
        'status' => {
            'containerStatuses' => [
                {
                    'name' => 'fabric8-console-container',
                    'state' => {
                        'running' => {
                            'startedAt' => '2015-05-08T09:22:44Z'
                        }
                    },
                    'lastState' => {},
                    'ready' => true,
                    'restartCount' => 0,
                    'image' => 'fabric8/hawtio-kubernetes:latest',
                    'imageID' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
                    'containerID' => 'docker://49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
                }
            ]
        }
      }
    )
    @deleted = OpenStruct.new(
      type: 'DELETED',
      object: {
        'metadata' => {
          'name' => 'deleteme',
          'namespace' => 'deleted',
          'uid' => 'deleted_uid'
        }
      }
    )
    end

    test 'pod watch updates cache when MODIFIED is received' do
      @client.stub :watch_pods, [@modified] do
        start_pod_watch
        assert_false @pod_metadata.empty?
        assert_equal('modified_uid', @pod_metadata['pod_id'])
        assert_equal(1, @stats[:pod_cache_watch_updates])
      end
    end

    test 'pod watch updates cache when ADDED is received' do
      @client.stub :watch_pods, [@added] do
        start_pod_watch
        assert_false @pod_metadata.empty?
        assert_equal('added_uid', @pod_metadata['pod_id'])
        assert_equal(1, @stats[:pod_cache_watch_updates])
      end
    end

    test 'pod watch ignores DELETED' do
      @pod_metadata = { 'pod_id' => 'original_uid' }
      @client.stub :watch_pods, [@deleted] do
       start_pod_watch
       assert_equal('original_uid', @pod_metadata['pod_id'])
       assert_equal(1, @stats[:pod_cache_watch_ignored])
      end
    end
end
