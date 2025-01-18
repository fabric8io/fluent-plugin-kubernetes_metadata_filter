# frozen_string_literal: true

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
require_relative 'test_watch'

class TestWatchPods < TestWatch
  include KubernetesMetadata::WatchPods

  before do
    @initial = {
      kind: 'PodList',
      metadata: { resourceVersion: '123' },
      items: [
        {
          metadata: {
            name: 'initial',
            namespace: 'initial_ns',
            uid: 'initial_uid',
            labels: {}
          },
          spec: {
            nodeName: 'aNodeName',
            containers: [
              {
                name: 'foo',
                image: 'bar'
              }, {
                name: 'bar',
                image: 'foo'
              }
            ]
          },
          status: {
            podIP: '172.17.0.8'
          }
        },
        {
          metadata: {
            name: 'modified',
            namespace: 'create',
            uid: 'modified_uid',
            labels: {}
          },
          spec: {
            nodeName: 'aNodeName',
            containers: [
              {
                name: 'foo',
                image: 'bar'
              }, {
                name: 'bar',
                image: 'foo'
              }
            ]
          },
          status: {
            podIP: '172.17.0.8'
          }
        }
      ]
    }
    @created = {
      type: 'CREATED',
      object: {
        metadata: {
          name: 'created',
          namespace: 'create',
          uid: 'created_uid',
          resourceVersion: '122',
          labels: {}
        },
        spec: {
          nodeName: 'aNodeName',
          containers: [
            {
              name: 'foo',
              image: 'bar'
            }, {
              name: 'bar',
              image: 'foo'
            }
          ]
        },
        status: {
          podIP: '172.17.0.8'
        }
      }
    }
    @modified = {
      type: 'MODIFIED',
      object: {
        metadata: {
          name: 'foo',
          namespace: 'modified',
          uid: 'modified_uid',
          resourceVersion: '123',
          labels: {}
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
          podIP: '172.17.0.8',
          containerStatuses: [
            {
              name: 'fabric8-console-container',
              state: {
                running: {
                  startedAt: '2015-05-08T09:22:44Z'
                }
              },
              lastState: {},
              ready: true,
              restartCount: 0,
              image: 'fabric8/hawtio-kubernetes:latest',
              imageID: 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
              containerID: 'docker://49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
            }
          ]
        }
      }
    }
    @deleted = {
      type: 'DELETED',
      object: {
        metadata: {
          name: 'deleteme',
          namespace: 'deleted',
          uid: 'deleted_uid',
          resourceVersion: '124'
        }
      }
    }
    @error = {
      type: 'ERROR',
      object: {
        message: 'some error message'
      }
    }
    @gone = {
      type: 'ERROR',
      object: {
        code: 410,
        kind: 'Status',
        message: 'too old resource version: 123 (391079)',
        metadata: {
          name: 'gone',
          namespace: 'gone',
          uid: 'gone_uid'
        },
        reason: 'Gone'
      }
    }
  end

  it 'pod list caches pods' do
    orig_env_val = ENV['K8S_NODE_NAME']
    ENV['K8S_NODE_NAME'] = 'aNodeName'
    @client.stub(:get_pods, @initial) do
      process_pod_watcher_notices(start_pod_watch)

      assert(@cache.key?('initial_uid'))
      assert(@cache.key?('modified_uid'))
      assert_equal(2, @stats[:pod_cache_host_updates])
    end
    ENV['K8S_NODE_NAME'] = orig_env_val
  end

  it 'pod list caches pods and watch updates' do
    orig_env_val = ENV['K8S_NODE_NAME']
    ENV['K8S_NODE_NAME'] = 'aNodeName'
    @client.stub(:get_pods, @initial) do
      @client.stub(:watch_pods, [@modified]) do
        process_pod_watcher_notices(start_pod_watch)

        assert_equal(2, @stats[:pod_cache_host_updates])
        assert_equal(1, @stats[:pod_cache_watch_updates])
      end
    end
    ENV['K8S_NODE_NAME'] = orig_env_val

    assert_equal('123', @last_seen_resource_version) # from @modified
  end

  it 'pod watch notice ignores CREATED' do
    @client.stub(:get_pods, @initial) do
      @client.stub(:watch_pods, [@created]) do
        process_pod_watcher_notices(start_pod_watch)

        refute(@cache.key?('created_uid'))
        assert_equal(1, @stats[:pod_cache_watch_ignored])
      end
    end
  end

  it 'pod watch notice is ignored when info not cached and MODIFIED is received' do
    @client.stub(:watch_pods, [@modified]) do
      process_pod_watcher_notices(start_pod_watch)

      refute(@cache.key?('modified_uid'))
      assert_equal(1, @stats[:pod_cache_watch_misses])
    end
  end

  it 'pod MODIFIED cached when hostname matches' do
    orig_env_val = ENV['K8S_NODE_NAME']
    ENV['K8S_NODE_NAME'] = 'aNodeName'
    @client.stub(:watch_pods, [@modified]) do
      process_pod_watcher_notices(start_pod_watch)

      assert(@cache.key?('modified_uid'))
      assert_equal(1, @stats[:pod_cache_host_updates])
    end
    ENV['K8S_NODE_NAME'] = orig_env_val
  end

  it 'pod watch notice is updated when MODIFIED is received' do
    @cache['modified_uid'] = {}
    @client.stub(:watch_pods, [@modified]) do
      process_pod_watcher_notices(start_pod_watch)

      assert(@cache.key?('modified_uid'))
      assert_equal(1, @stats[:pod_cache_watch_updates])
    end
  end

  it 'pod watch notice is ignored when delete is received' do
    @cache['deleted_uid'] = {}
    @client.stub(:watch_pods, [@deleted]) do
      process_pod_watcher_notices(start_pod_watch)

      assert(@cache.key?('deleted_uid'))
      assert_equal(1, @stats[:pod_cache_watch_delete_ignored])
    end
  end

  it 'pod watch raises Fluent::UnrecoverableError when cannot re-establish connection to k8s API server' do
    # Stub start_pod_watch to simulate initial successful connection to API server
    stub(:start_pod_watch, nil) do
      # Stub watch_pods to simulate not being able to set up watch connection to API server
      @client.stub(:watch_pods, -> { raise StandardError }) do
        @client.stub(:get_pods, @initial) do
          assert_raises(Fluent::UnrecoverableError) do
            set_up_pod_thread
          end
          assert_equal(3, @stats[:pod_watch_failures])
          assert_equal(2, Thread.current[:pod_watch_retry_count])
          assert_equal(4, Thread.current[:pod_watch_retry_backoff_interval])
          assert_nil(@stats[:pod_watch_error_type_notices])
        end
      end
    end
  end

  it 'pod watch resets watch retry count when exceptions are encountered and connection to k8s API server is re-established' do # rubocop:disable Layout/LineLength
    @client.stub(:get_pods, @initial) do
      @client.stub(:watch_pods, [[@created, @exception_raised]]) do
        # Force the infinite watch loop to exit after 3 seconds. Verifies that
        # no unrecoverable error was thrown during this period of time.
        assert_raises(Timeout::Error) do
          Timeout.timeout(3) do
            set_up_pod_thread
          end
        end
        assert_operator(@stats[:pod_watch_failures], :>=, 3)
        assert_operator(Thread.current[:pod_watch_retry_count], :<=, 1)
        assert_operator(Thread.current[:pod_watch_retry_backoff_interval], :<=, 1)
      end
    end
  end

  it 'pod watch resets watch retry count when error is received and connection to k8s API server is re-established' do
    @client.stub(:get_pods, @initial) do
      @client.stub(:watch_pods, [@error]) do
        # Force the infinite watch loop to exit after 3 seconds. Verifies that
        # no unrecoverable error was thrown during this period of time.
        assert_raises(Timeout::Error) do
          Timeout.timeout(3) do
            set_up_pod_thread
          end
        end
        assert_operator(@stats[:pod_watch_failures], :>=, 3)
        assert_operator(Thread.current[:pod_watch_retry_count], :<=, 1)
        assert_operator(Thread.current[:pod_watch_retry_backoff_interval], :<=, 1)
        assert_operator(@stats[:pod_watch_error_type_notices], :>=, 3)
      end
    end
  end

  it 'pod watch continues after retries succeed' do
    @client.stub(:get_pods, @initial) do
      @client.stub(:watch_pods, [@modified, @error, @modified]) do
        # Force the infinite watch loop to exit after 3 seconds. Verifies that
        # no unrecoverable error was thrown during this period of time.
        assert_raises(Timeout::Error) do
          Timeout.timeout(3) do
            set_up_pod_thread
          end
        end
        assert_operator(@stats[:pod_watch_failures], :>=, 3)
        assert_operator(Thread.current[:pod_watch_retry_count], :<=, 1)
        assert_operator(Thread.current[:pod_watch_retry_backoff_interval], :<=, 1)
        assert_operator(@stats[:pod_watch_error_type_notices], :>=, 3)
      end
    end
  end

  it 'pod watch raises a GoneError when a 410 Gone error is received' do
    @cache['gone_uid'] = {}
    @client.stub(:watch_pods, [@gone]) do
      @last_seen_resource_version = '100'
      assert_raises(KubernetesMetadata::Common::GoneError) do
        process_pod_watcher_notices(start_pod_watch)
      end
      assert_equal(1, @stats[:pod_watch_gone_notices])
      assert_nil(@last_seen_resource_version) # forced restart
    end
  end

  it 'pod watch retries when 410 Gone errors are encountered' do
    @client.stub(:get_pods, @initial) do
      @client.stub(:watch_pods, [@created, @gone, @modified]) do
        # Force the infinite watch loop to exit after 3 seconds because the code sleeps 3 times.
        # Verifies that no unrecoverable error was thrown during this period of time.
        assert_raises(Timeout::Error) do
          Timeout.timeout(3) do
            set_up_pod_thread
          end
        end
        assert_operator(@stats[:pod_watch_gone_errors], :>=, 3)
        assert_operator(@stats[:pod_watch_gone_notices], :>=, 3)
      end
    end
  end
end
