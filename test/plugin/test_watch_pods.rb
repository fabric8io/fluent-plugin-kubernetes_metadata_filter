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
       @initial = Kubeclient::Common::EntityList.new(
         'PodList',
         '123',
         [
           Kubeclient::Resource.new({
                                      'metadata' => {
                                        'name' => 'initial',
                                        'namespace' => 'initial_ns',
                                        'uid' => 'initial_uid',
                                        'labels' => {},
                                      },
                                      'spec' => {
                                        'nodeName' => 'aNodeName',
                                        'containers' => [{
                                                           'name' => 'foo',
                                                           'image' => 'bar',
                                                         }, {
                                                           'name' => 'bar',
                                                           'image' => 'foo',
                                                         }]
                                      }
                                    }),
           Kubeclient::Resource.new({
                                      'metadata' => {
                                        'name' => 'modified',
                                        'namespace' => 'create',
                                        'uid' => 'modified_uid',
                                        'labels' => {},
                                      },
                                      'spec' => {
                                        'nodeName' => 'aNodeName',
                                        'containers' => [{
                                                           'name' => 'foo',
                                                           'image' => 'bar',
                                                         }, {
                                                           'name' => 'bar',
                                                           'image' => 'foo',
                                                         }]
                                      }
                                    }),
         ])
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
                'nodeName' => 'aNodeName',
                'containers' => [{
                     'name' => 'foo',
                     'image' => 'bar',
                 }, {
                     'name' => 'bar',
                     'image' => 'foo',
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
                'labels' => {},
            },
            'spec' => {
                'nodeName' => 'aNodeName',
                'containers' => [{
                    'name' => 'foo',
                    'image' => 'bar',
                 }, {
                    'name' => 'bar',
                    'image' => 'foo',
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

    test 'pod list caches pods' do
      orig_env_val = ENV['K8S_NODE_NAME']
      ENV['K8S_NODE_NAME'] = 'aNodeName'
      @client.stub :get_pods, @initial do
        process_pod_watcher_notices(start_pod_watch)
        assert_equal(true, @cache.key?('initial_uid'))
        assert_equal(true, @cache.key?('modified_uid'))
        assert_equal(2, @stats[:pod_cache_host_updates])
      end
      ENV['K8S_NODE_NAME'] = orig_env_val
    end

    test 'pod list caches pods and watch updates' do
      orig_env_val = ENV['K8S_NODE_NAME']
      ENV['K8S_NODE_NAME'] = 'aNodeName'
      @client.stub :get_pods, @initial do
        @client.stub :watch_pods, [@modified] do
          process_pod_watcher_notices(start_pod_watch)
          assert_equal(2, @stats[:pod_cache_host_updates])
          assert_equal(1, @stats[:pod_cache_watch_updates])
        end
      end
      ENV['K8S_NODE_NAME'] = orig_env_val
    end

    test 'pod watch notice ignores CREATED' do
      @client.stub :get_pods, @initial do
        @client.stub :watch_pods, [@created] do
          process_pod_watcher_notices(start_pod_watch)
          assert_equal(false, @cache.key?('created_uid'))
          assert_equal(1, @stats[:pod_cache_watch_ignored])
        end
      end
    end

    test 'pod watch notice is ignored when info not cached and MODIFIED is received' do
      @client.stub :watch_pods, [@modified] do
       process_pod_watcher_notices(start_pod_watch)
       assert_equal(false, @cache.key?('modified_uid'))
       assert_equal(1, @stats[:pod_cache_watch_misses])
      end
    end

    test 'pod MODIFIED cached when hostname matches' do
      orig_env_val = ENV['K8S_NODE_NAME']
      ENV['K8S_NODE_NAME'] = 'aNodeName'
      @client.stub :watch_pods, [@modified] do
       process_pod_watcher_notices(start_pod_watch)
       assert_equal(true, @cache.key?('modified_uid'))
       assert_equal(1, @stats[:pod_cache_host_updates])
      end
      ENV['K8S_NODE_NAME'] = orig_env_val
    end

    test 'pod watch notice is updated when MODIFIED is received' do
      @cache['modified_uid'] = {}
      @client.stub :watch_pods, [@modified] do
       process_pod_watcher_notices(start_pod_watch)
       assert_equal(true, @cache.key?('modified_uid'))
       assert_equal(1, @stats[:pod_cache_watch_updates])
      end
    end

    test 'pod watch notice is ignored when delete is received' do
      @cache['deleted_uid'] = {}
      @client.stub :watch_pods, [@deleted] do
       process_pod_watcher_notices(start_pod_watch)
       assert_equal(true, @cache.key?('deleted_uid'))
       assert_equal(1, @stats[:pod_cache_watch_delete_ignored])
      end
    end

    test 'pod watch retries when exceptions are encountered' do
      @client.stub :get_pods, @initial do
        @client.stub :watch_pods, [[@created, @exception_raised]] do
          assert_raise Fluent::UnrecoverableError do
            set_up_pod_thread
          end
          assert_equal(3, @stats[:pod_watch_failures])
          assert_equal(2, Thread.current[:pod_watch_retry_count])
          assert_equal(4, Thread.current[:pod_watch_retry_backoff_interval])
        end
      end
    end
end
