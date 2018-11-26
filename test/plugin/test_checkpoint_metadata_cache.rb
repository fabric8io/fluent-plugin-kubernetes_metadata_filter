require_relative '../helper'
require_relative '../../lib/fluent/plugin/checkpoint_metadata_cache'
require_relative '../../lib/fluent/plugin/kubernetes_metadata_cache_strategy'
require 'lru_redux'
require 'timecop'

class TestCheckPointCache
  include KubernetesMetadata::PersistentCache

  def initialize
    @cache = LruRedux::TTL::ThreadSafeCache.new(100, 3600)
    @id_cache = LruRedux::TTL::ThreadSafeCache.new(100, 3600)
    @namespace_cache = LruRedux::TTL::ThreadSafeCache.new(100, 3600)
    @orphaned_namespace_name = '.orphaned'
    @orphaned_namespace_id = 'orphaned'
    @checkpoint_ttl = 3000
  end

  attr_accessor :stats, :cache, :id_cache, :namespace_cache, :allow_orphans, :checkpoint_db_path

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

class PersistentCacheTest < Test::Unit::TestCase
  def setup
    @checkpoint = TestCheckPointCache.new
    @checkpoint.checkpoint_db_path = '/tmp/test.db'
    File.delete(@checkpoint.checkpoint_db_path) if File.exist?(@checkpoint.checkpoint_db_path)
    @pod_uuid = 'some_pod_uuid'
    @pod_name = 'some_pod_name'
    @namespace_uuid = 'some_namespace_uuid'
    @namespace_name = 'some_namespace_name'
    @container_id = 'some_container_id'
    @namespaces_labels_data = {'key' => 'value'}
    @id_cache_data = {@container_id => {:pod_id => @pod_uuid, :namespace_id => @namespace_uuid}}
    @namespace_data = {'namespace_id' => @namespace_uuid, 'creation_timestamp' => @time.to_s, 'namespace_labels' => @namespaces_labels_data}
    @cache_data = {'namespace_name' => @namespace_name, 'pod_id' => @pod_uuid, 'pod_name' => @pod_name}
    @checkpoint.initialize_db
  end

  def teardown
    File.delete(@checkpoint.checkpoint_db_path) if File.exist?(@checkpoint.checkpoint_db_path)
  end

  def wipe_cache
    @checkpoint.id_cache = {}
    @checkpoint.namespace_cache = {}
    @checkpoint.cache = {}
  end

  test 'check for read and write of cache elements' do
    @checkpoint.id_cache = @id_cache_data
    @checkpoint.namespace_cache = @namespace_data
    @checkpoint.cache = @cache_data
    @checkpoint.write_cache_to_file
    wipe_cache
    @checkpoint.read_cache_from_file
    assert_equal(@id_cache_data, @checkpoint.id_cache)
    assert_equal(@namespace_data, @checkpoint.namespace_cache)
    assert_equal(@cache_data, @checkpoint.cache)
  end

  test 'ensure older entries into the database are pruned' do
    @checkpoint.id_cache = @id_cache_data
    @checkpoint.namespace_cache = @namespace_data
    @checkpoint.cache = @cache_data
    @checkpoint.write_cache_to_file
    Timecop.travel(Time.now + 3500)
    @checkpoint.prune_old_entries
    wipe_cache
    @checkpoint.read_cache_from_file
    assert_empty(@checkpoint.id_cache)
    assert_empty(@checkpoint.namespace_cache)
    assert_empty(@checkpoint.cache)
  end

  test 'ensure older entries into the database are not pruned' do
    @checkpoint.id_cache = @id_cache_data
    @checkpoint.namespace_cache = @namespace_data
    @checkpoint.cache = @cache_data
    @checkpoint.write_cache_to_file
    Timecop.travel(Time.now + 1500)
    @checkpoint.prune_old_entries
    wipe_cache
    @checkpoint.read_cache_from_file
    assert_equal(@id_cache_data, @checkpoint.id_cache)
    assert_equal(@namespace_data, @checkpoint.namespace_cache)
    assert_equal(@cache_data, @checkpoint.cache)
  end


end