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

class TestSimpleCacheStrategy

  require_relative '../../lib/fluent/plugin/kubernetes_metadata_simple_cache_strategy'
  include KubernetesMetadata::SimpleCacheStrategy

  def initialize
    @stats = KubernetesMetadata::Stats.new
    @cache = LruRedux::TTL::ThreadSafeCache.new(100, 3600)
    @namespace_cache = LruRedux::TTL::ThreadSafeCache.new(100, 3600)
  end

  attr_accessor :stats, :cache, :namespace_cache

  def fetch_pod_metadata(_namespace_name, _pod_name)
    {}
  end

  def fetch_namespace_metadata(_namespace_name)
    {}
  end

  def log
    logger = {}
    def logger.trace?
      true
    end

    def logger.trace(message)
    end
    logger
  end
end

class KubernetesMetadataSimpleCacheStrategyTest < Test::Unit::TestCase
  def setup
    @strategy = TestSimpleCacheStrategy.new
    @containerId = 'some_long_container_id'
    @namespace_name = 'some_namespace_name'
    @namespace_uuid = 'some_namespace_uuid'
    @pod_name = 'some_pod_name'
    @pod_uuid = 'some_pod_uuid'
    @time = Time.now
    @pod_meta = { 'pod_id' => @pod_uuid, 'labels' => { 'meta' => 'pod' } }
    @namespace_meta = { 'namespace_id' => @namespace_uuid, 'creation_timestamp' => @time.to_s }
    @batch_miss_cache = {}
  end

  test 'when cached metadata is found' do
    exp = @pod_meta.merge(@namespace_meta)
    exp.delete('creation_timestamp')
    @strategy.cache["namespace_pod"] = exp
    @strategy.namespace_cache['namespace'] = @namespace_meta
    assert_equal(exp, @strategy.get_pod_metadata(@containerId, 'namespace', 'pod', @time, {}))
  end

  test 'when metadata is not cached and is fetched' do
    exp = @pod_meta.merge(@namespace_meta)
    @strategy.stub :fetch_pod_metadata, @pod_meta do
      @strategy.stub :fetch_namespace_metadata, @namespace_meta do
        assert_equal(exp, @strategy.get_pod_metadata(@containerId, 'namespace', 'pod', @time, {}))
      end
    end
  end

  test 'when metadata is not cached and pod is deleted and namespace metadata is fetched' do
    # this is the case for a record from a deleted pod where no other
    # records were read.
    exp = @namespace_meta
    @strategy.stub :fetch_pod_metadata, {} do
      @strategy.stub :fetch_namespace_metadata, @namespace_meta do
        assert_equal(exp, @strategy.get_pod_metadata(@containerId, 'namespace', 'pod', @time, @batch_miss_cache))
      end
    end
    # assert subsequent call returns same
    assert_equal(exp, @strategy.get_pod_metadata(@containerId, 'namespace', 'pod', @time, @batch_miss_cache))
  end

  test 'when metadata is not cached and no metadata can be fetched' do
    # Unretrievable pod and namespace info should result in simply returning the
    # metadata that can be gleened from the tag (namespace name, pod name, container hash)
    @strategy.stub :fetch_pod_metadata, {} do
      @strategy.stub :fetch_namespace_metadata, {} do
        assert_equal({}, @strategy.get_pod_metadata(@containerId, 'aNamespace', 'aPod', @time, @batch_miss_cache))
      end
    end
    # assert subsequent call returns same
    assert_equal({}, @strategy.get_pod_metadata(@containerId, 'aNamespace', 'aPod', @time, @batch_miss_cache))
  end
end
