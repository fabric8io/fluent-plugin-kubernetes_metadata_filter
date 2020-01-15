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

class WatchNamespacesTestTest < WatchTest

     include KubernetesMetadata::WatchNamespaces

     setup do
       @initial = Kubeclient::Common::EntityList.new(
         'NamespaceList',
         '123',
         [
           Kubeclient::Resource.new({
                                      'metadata' => {
                                        'name' => 'initial',
                                        'uid' => 'initial_uid'
                                      }
                                    }),
           Kubeclient::Resource.new({
                                      'metadata' => {
                                        'name' => 'modified',
                                        'uid' => 'modified_uid'
                                      }
                                    })
         ])

       @created = OpenStruct.new(
         type: 'CREATED',
         object: {
           'metadata' => {
                'name' => 'created',
                'uid' => 'created_uid'
            }
         }
       )
       @modified = OpenStruct.new(
         type: 'MODIFIED',
         object: {
           'metadata' => {
                'name' => 'foo',
                'uid' => 'modified_uid'
            }
         }
       )
       @deleted = OpenStruct.new(
         type: 'DELETED',
         object: {
           'metadata' => {
                'name' => 'deleteme',
                'uid' => 'deleted_uid'
            }
         }
       )
     end

    test 'namespace list caches namespaces' do
      @client.stub :get_namespaces, @initial do
        start_namespace_watch
        assert_equal(true, @namespace_cache.key?('initial_uid'))
        assert_equal(true, @namespace_cache.key?('modified_uid'))
        assert_equal(2, @stats[:namespace_cache_host_updates])
      end
    end

    test 'namespace list caches namespaces and watch updates' do
      orig_env_val = ENV['K8S_NODE_NAME']
      ENV['K8S_NODE_NAME'] = 'aNodeName'
      @client.stub :get_namespaces, @initial do
        @client.stub :watch_namespaces, [@modified] do
          start_namespace_watch
          assert_equal(2, @stats[:namespace_cache_host_updates])
          assert_equal(1, @stats[:namespace_cache_watch_updates])
        end
      end
      ENV['K8S_NODE_NAME'] = orig_env_val
    end

    test 'namespace watch ignores CREATED' do
      @client.stub :watch_namespaces, [@created] do
       start_namespace_watch
       assert_equal(false, @namespace_cache.key?('created_uid'))
       assert_equal(1, @stats[:namespace_cache_watch_ignored])
      end
    end

    test 'namespace watch ignores MODIFIED when info not in cache' do
      @client.stub :watch_namespaces, [@modified] do
       start_namespace_watch
       assert_equal(false, @namespace_cache.key?('modified_uid'))
       assert_equal(1, @stats[:namespace_cache_watch_misses])
      end
    end

    test 'namespace watch updates cache when MODIFIED is received and info is cached' do
      @namespace_cache['modified_uid'] = {}
      @client.stub :watch_namespaces, [@modified] do
       start_namespace_watch
       assert_equal(true, @namespace_cache.key?('modified_uid'))
       assert_equal(1, @stats[:namespace_cache_watch_updates])
      end
    end

    test 'namespace watch ignores DELETED' do
      @namespace_cache['deleted_uid'] = {}
      @client.stub :watch_namespaces, [@deleted] do
       start_namespace_watch
       assert_equal(true, @namespace_cache.key?('deleted_uid'))
       assert_equal(1, @stats[:namespace_cache_watch_deletes_ignored])
      end
    end

end
