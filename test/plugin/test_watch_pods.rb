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

class DefaultPodWatchStrategyTest < WatchTest

     include KubernetesMetadata::WatchPods

     setup do
       @created = OpenStruct.new(
         type: 'CREATED',
         object: {
           'metadata' => {
                'name' => 'created',
                'namespace' => 'create',
                'uid' => 'created_uid',
                'labels' => {},
            },
            'spec' => {
                'nodeName' => 'aNodeName'
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
                'labels' => {},
            },
            'spec' => {
                'nodeName' => 'aNodeName'
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

    test 'pod watch notice ignores CREATED' do
      @client.stub :watch_pods, [@created] do
       start_pod_watch
       assert_equal(false, @cache.key?('created_uid'))
       assert_equal(1, @stats[:pod_cache_watch_ignored])
      end
    end

    test 'pod watch notice is ignored when info not cached and MODIFIED is received' do
      @client.stub :watch_pods, [@modified] do
       start_pod_watch
       assert_equal(false, @cache.key?('modified_uid'))
       assert_equal(1, @stats[:pod_cache_watch_misses])
      end
    end

    test 'pod watch notice is updated when MODIFIED is received' do
      @cache['modified_uid'] = {}
      @client.stub :watch_pods, [@modified] do
       start_pod_watch
       assert_equal(true, @cache.key?('modified_uid'))
       assert_equal(1, @stats[:pod_cache_watch_updates])
      end
    end

    test 'pod watch notice is ignored when delete is received' do
      @cache['deleted_uid'] = {}
      @client.stub :watch_pods, [@deleted] do
       start_pod_watch
       assert_equal(true, @cache.key?('deleted_uid'))
       assert_equal(1, @stats[:pod_cache_watch_delete_ignored])
      end
    end

end
