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

class KubernetesMetadataCacheStrategyMock
  include KubernetesMetadata::CacheStrategy

  attr_accessor :stats, :cache, :id_cache, :namespace_cache, :allow_orphans

  def initialize
    @stats = KubernetesMetadata::Stats.new
    @cache = LruRedux::TTL::ThreadSafeCache.new(100, 3600, true)
    @id_cache = LruRedux::TTL::ThreadSafeCache.new(100, 3600, true)
    @namespace_cache = LruRedux::TTL::ThreadSafeCache.new(100, 3600, true)
    @orphaned_namespace_name = '.orphaned'
    @orphaned_namespace_id = 'orphaned'
  end

  def fetch_pod_metadata(_namespace_name, _pod_name)
    {}
  end

  def fetch_namespace_metadata(_namespace_name)
    {}
  end

  def log
    logger = {}

    def logger.on_trace
      true
    end

    def logger.trace(message)
    end

    logger
  end
end

class TestCacheStrategy < Test::Unit::TestCase
  def setup
    @strategy = KubernetesMetadataCacheStrategyMock.new
    @cache_key = 'some_long_container_id'
    @namespace_name = 'some_namespace_name'
    @namespace_uuid = 'some_namespace_uuid'
    @pod_name = 'some_pod_name'
    @pod_uuid = 'some_pod_uuid'
    @time = Time.now
    @pod_meta = { 'pod_id' => @pod_uuid, 'labels' => { 'meta' => 'pod' } }
    @namespace_meta = { 'namespace_id' => @namespace_uuid, 'creation_timestamp' => @time.to_s }
  end

  test 'when cached metadata is found' do
    exp = @pod_meta.merge(@namespace_meta)
    exp.delete('creation_timestamp')
    @strategy.id_cache[@cache_key] = { pod_id: @pod_uuid, namespace_id: @namespace_uuid }
    @strategy.cache[@pod_uuid] = @pod_meta
    @strategy.namespace_cache[@namespace_uuid] = @namespace_meta

    assert_equal(exp, @strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time, {}))
  end

  test 'when previously processed record for pod but metadata is not cached and can not be fetched' do
    exp = { 'pod_id' => @pod_uuid, 'namespace_id' => @namespace_uuid }
    @strategy.id_cache[@cache_key] = { pod_id: @pod_uuid, namespace_id: @namespace_uuid }
    @strategy.stub(:fetch_pod_metadata, {}) do
      @strategy.stub(:fetch_namespace_metadata, nil) do
        assert_equal(exp, @strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time, {}))
      end
    end
  end

  test 'when metadata is not cached and is fetched' do
    exp = @pod_meta.merge(@namespace_meta)
    exp.delete('creation_timestamp')
    @strategy.stub(:fetch_pod_metadata, @pod_meta) do
      @strategy.stub(:fetch_namespace_metadata, @namespace_meta) do
        assert_equal(exp, @strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time, {}))
        assert_true(@strategy.id_cache.key?(@cache_key))
      end
    end
  end

  test 'when metadata is not cached and pod is deleted and namespace metadata is fetched' do
    # this is the case for a record from a deleted pod where no other
    # records were read.  using the container hash since that is all
    # we ever will have and should allow us to process all the deleted
    # pod records
    exp = { 'pod_id' => @cache_key, 'namespace_id' => @namespace_uuid }
    @strategy.stub(:fetch_pod_metadata, {}) do
      @strategy.stub(:fetch_namespace_metadata, @namespace_meta) do
        assert_equal(exp, @strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time, {}))
        assert_true(@strategy.id_cache.key?(@cache_key))
      end
    end
  end

  test 'when metadata is not cached and pod is deleted and namespace is for a different namespace with the same name' do
    # this is the case for a record from a deleted pod from a deleted namespace
    # where new namespace was created with the same name
    exp = { 'namespace_id' => @namespace_uuid }
    @strategy.stub(:fetch_pod_metadata, {}) do
      @strategy.stub(:fetch_namespace_metadata, @namespace_meta) do
        assert_equal(exp, @strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time - (1 * 86_400), {}))
        assert_true(@strategy.id_cache.key?(@cache_key))
      end
    end
  end

  test 'when metadata is not cached and no metadata can be fetched and not allowing orphans' do
    # we should never see this since pod meta should not be retrievable
    # unless the namespace exists
    @strategy.stub(:fetch_pod_metadata, @pod_meta) do
      @strategy.stub(:fetch_namespace_metadata, {}) do
        assert_empty(@strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time - (1 * 86_400), {}))
      end
    end
  end

  test 'when metadata is not cached and no metadata can be fetched and allowing orphans' do
    # we should never see this since pod meta should not be retrievable
    # unless the namespace exists
    @strategy.allow_orphans = true
    exp = { 'orphaned_namespace' => 'namespace', 'namespace_name' => '.orphaned', 'namespace_id' => 'orphaned' }
    @strategy.stub(:fetch_pod_metadata, @pod_meta) do
      @strategy.stub(:fetch_namespace_metadata, {}) do
        assert_equal(exp, @strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time - (1 * 86_400), {}))
      end
    end
  end

  test 'when metadata is not cached and no metadata can be fetched and not allowing orphans for multiple records' do
    # processing a batch of records with no meta. ideally we only hit the api server once
    batch_miss_cache = {}
    @strategy.stub(:fetch_pod_metadata, {}) do
      @strategy.stub(:fetch_namespace_metadata, {}) do
        assert_empty(@strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time, batch_miss_cache))
      end
    end

    assert_empty(@strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time, batch_miss_cache))
  end

  test 'when metadata is not cached and no metadata can be fetched and allowing orphans for multiple records' do
    # we should never see this since pod meta should not be retrievable
    # unless the namespace exists
    @strategy.allow_orphans = true
    exp = { 'orphaned_namespace' => 'namespace', 'namespace_name' => '.orphaned', 'namespace_id' => 'orphaned' }
    batch_miss_cache = {}
    @strategy.stub(:fetch_pod_metadata, {}) do
      @strategy.stub(:fetch_namespace_metadata, {}) do
        assert_equal(exp, @strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time, batch_miss_cache))
      end
    end

    assert_equal(exp, @strategy.get_pod_metadata(@cache_key, 'namespace', 'pod', @time, batch_miss_cache))
  end
end
