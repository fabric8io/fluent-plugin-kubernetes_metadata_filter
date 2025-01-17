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

class TestWatchNamespaces < TestWatch
  include KubernetesMetadata::WatchNamespaces

  setup do
    @initial = {
      kind: 'NamespaceList',
      metadata: { resourceVersion: '123' },
      items: [
        {
          metadata: {
            name: 'initial',
            uid: 'initial_uid'
          }
        },
        {
          metadata: {
            name: 'modified',
            uid: 'modified_uid'
          }
        }
      ]
    }

    @created = {
      type: 'CREATED',
      object: {
        metadata: {
          name: 'created',
          uid: 'created_uid'
        }
      }
    }
    @modified = {
      type: 'MODIFIED',
      object: {
        metadata: {
          name: 'foo',
          uid: 'modified_uid'
        }
      }
    }
    @deleted = {
      type: 'DELETED',
      object: {
        metadata: {
          name: 'deleteme',
          uid: 'deleted_uid'
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

  test 'namespace list caches namespaces' do
    @client.stub(:get_namespaces, @initial) do
      process_namespace_watcher_notices(start_namespace_watch)

      assert(@namespace_cache.key?('initial_uid'))
      assert(@namespace_cache.key?('modified_uid'))
      assert_equal(2, @stats[:namespace_cache_host_updates])
    end
  end

  test 'namespace list caches namespaces and watch updates' do
    orig_env_val = ENV['K8S_NODE_NAME']
    ENV['K8S_NODE_NAME'] = 'aNodeName'
    @client.stub(:get_namespaces, @initial) do
      @client.stub(:watch_namespaces, [@modified]) do
        process_namespace_watcher_notices(start_namespace_watch)

        assert_equal(2, @stats[:namespace_cache_host_updates])
        assert_equal(1, @stats[:namespace_cache_watch_updates])
      end
    end
    ENV['K8S_NODE_NAME'] = orig_env_val
  end

  test 'namespace watch ignores CREATED' do
    @client.stub(:watch_namespaces, [@created]) do
      process_namespace_watcher_notices(start_namespace_watch)

      refute(@namespace_cache.key?('created_uid'))
      assert_equal(1, @stats[:namespace_cache_watch_ignored])
    end
  end

  test 'namespace watch ignores MODIFIED when info not in cache' do
    @client.stub(:watch_namespaces, [@modified]) do
      process_namespace_watcher_notices(start_namespace_watch)

      refute(@namespace_cache.key?('modified_uid'))
      assert_equal(1, @stats[:namespace_cache_watch_misses])
    end
  end

  test 'namespace watch updates cache when MODIFIED is received and info is cached' do
    @namespace_cache['modified_uid'] = {}
    @client.stub(:watch_namespaces, [@modified]) do
      process_namespace_watcher_notices(start_namespace_watch)

      assert(@namespace_cache.key?('modified_uid'))
      assert_equal(1, @stats[:namespace_cache_watch_updates])
    end
  end

  test 'namespace watch ignores DELETED' do
    @namespace_cache['deleted_uid'] = {}
    @client.stub(:watch_namespaces, [@deleted]) do
      process_namespace_watcher_notices(start_namespace_watch)

      assert(@namespace_cache.key?('deleted_uid'))
      assert_equal(1, @stats[:namespace_cache_watch_deletes_ignored])
    end
  end

  test 'namespace watch raises Fluent::UnrecoverableError when cannot re-establish connection to k8s API server' do
    # Stub start_namespace_watch to simulate initial successful connection to API server
    stub(self).start_namespace_watch
    # Stub watch_namespaces to simulate not being able to set up watch connection to API server
    stub(@client).watch_namespaces { raise }

    @client.stub(:get_namespaces, @initial) do
      assert_raise(Fluent::UnrecoverableError) do
        set_up_namespace_thread
      end
    end
    assert_equal(3, @stats[:namespace_watch_failures])
    assert_equal(2, Thread.current[:namespace_watch_retry_count])
    assert_equal(4, Thread.current[:namespace_watch_retry_backoff_interval])
    assert_nil(@stats[:namespace_watch_error_type_notices])
  end

  test 'namespace watch resets watch retry count when exceptions are encountered and connection to k8s API server is re-established' do # rubocop:disable Layout/LineLength
    @client.stub(:get_namespaces, @initial) do
      @client.stub(:watch_namespaces, [[@created, @exception_raised]]) do
        # Force the infinite watch loop to exit after 3 seconds. Verifies that
        # no unrecoverable error was thrown during this period of time.
        assert_raise(Timeout::Error.new('execution expired')) do
          Timeout.timeout(3) do
            set_up_namespace_thread
          end
        end
        assert_operator(@stats[:namespace_watch_failures], :>=, 3)
        assert_operator(Thread.current[:namespace_watch_retry_count], :<=, 1)
        assert_operator(Thread.current[:namespace_watch_retry_backoff_interval], :<=, 1)
      end
    end
  end

  test 'namespace watch resets watch retry count when error is received and connection to k8s API server is re-established' do # rubocop:disable Layout/LineLength
    @client.stub(:get_namespaces, @initial) do
      @client.stub(:watch_namespaces, [@error]) do
        # Force the infinite watch loop to exit after 3 seconds. Verifies that
        # no unrecoverable error was thrown during this period of time.
        assert_raise(Timeout::Error.new('execution expired')) do
          Timeout.timeout(3) do
            set_up_namespace_thread
          end
        end
        assert_operator(@stats[:namespace_watch_failures], :>=, 3)
        assert_operator(Thread.current[:namespace_watch_retry_count], :<=, 1)
        assert_operator(Thread.current[:namespace_watch_retry_backoff_interval], :<=, 1)
      end
    end
  end

  test 'namespace watch continues after retries succeed' do
    @client.stub(:get_namespaces, @initial) do
      @client.stub(:watch_namespaces, [@modified, @error, @modified]) do
        # Force the infinite watch loop to exit after 3 seconds. Verifies that
        # no unrecoverable error was thrown during this period of time.
        assert_raise(Timeout::Error.new('execution expired')) do
          Timeout.timeout(3) do
            set_up_namespace_thread
          end
        end
        assert_operator(@stats[:namespace_watch_failures], :>=, 3)
        assert_operator(Thread.current[:namespace_watch_retry_count], :<=, 1)
        assert_operator(Thread.current[:namespace_watch_retry_backoff_interval], :<=, 1)
        assert_operator(@stats[:namespace_watch_error_type_notices], :>=, 3)
      end
    end
  end

  test 'namespace watch raises a GoneError when a 410 Gone error is received' do
    @cache['gone_uid'] = {}
    @client.stub(:watch_namespaces, [@gone]) do
      assert_raise(KubernetesMetadata::Common::GoneError) do
        process_namespace_watcher_notices(start_namespace_watch)
      end
      assert_equal(1, @stats[:namespace_watch_gone_notices])
    end
  end

  test 'namespace watch retries when 410 Gone errors are encountered' do
    @client.stub(:get_namespaces, @initial) do
      @client.stub(:watch_namespaces, [@created, @gone, @modified]) do
        # Force the infinite watch loop to exit after 3 seconds. Verifies that
        # no unrecoverable error was thrown during this period of time.
        assert_raise(Timeout::Error.new('execution expired')) do
          Timeout.timeout(3) do
            set_up_namespace_thread
          end
        end
        assert_operator(@stats[:namespace_watch_gone_errors], :>=, 3)
        assert_operator(@stats[:namespace_watch_gone_notices], :>=, 3)
      end
    end
  end
end
