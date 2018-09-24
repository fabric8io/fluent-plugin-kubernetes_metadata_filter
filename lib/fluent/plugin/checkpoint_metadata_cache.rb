#
# Fluentd Kubernetes Metadata Filter Plugin - Enrich Fluentd events with
# Kubernetes metadata
#
# Copyright 2017 Red Hat, Inc.
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
require "sqlite3"

module KubernetesMetadata
  module CheckPointCache
    def start_checkpoint
      while true
        log.trace "check pointing cache to disk" if log.trace?
        write_cache_to_file
        prune_old_entries
        sleep @checkpoint_interval
      end
    end

    def initialize_db
      @db = SQLite3::Database.new @checkpoint_db_path
      @db.execute <<-SQL
        create table IF NOT EXISTS cache (
          id TEXT PRIMARY KEY,
          val TEXT,
          created_at INTEGER
        );
      SQL
      @db.execute <<-SQL
        create table IF NOT EXISTS id_cache (
          id TEXT PRIMARY KEY,
          val TEXT,
          created_at INTEGER
        );
      SQL
      @db.execute <<-SQL
        create table IF NOT EXISTS namespace_cache (
          id TEXT PRIMARY KEY,
          val TEXT,
          created_at INTEGER
        );
      SQL
    end

    def prune_old_entries
      timestamp = Time.now - @cache_ttl
      @db.execute "delete from cache where created_at <= ?", timestamp.to_i
      @db.execute "delete from id_cache where created_at <= ?", timestamp.to_i
      @db.execute "delete from namespace_cache where created_at <= ?", timestamp.to_i
    end

    def write_cache_to_file
      timestamp = Time.now.to_i
      @cache.each do |k, v|
        @db.execute "insert or ignore into cache (id, val, created_at) values ( ?, ?, ?)", [k, JSON.generate(v), timestamp]
      end
      @id_cache.each do |k, v|
        @db.execute "insert or ignore into id_cache (id, val, created_at) values ( ?, ?, ?)", [k, JSON.generate(v), timestamp]
      end
      @namespace_cache.each do |k, v|
        @db.execute "insert or ignore into namespace_cache (id, val, created_at) values ( ?, ?, ?)", [k, JSON.generate(v), timestamp]
      end
    end

    def read_cache_from_file
      @db.execute("select * from cache") do |row|
        @cache[row[0]] = JSON.parse(row[1])
      end
      @db.execute("select * from id_cache") do |row|
        @id_cache[row[0]] = JSON.parse(row[1])
      end
      @db.execute("select * from namespace_cache") do |row|
        @namespace_cache[row[0]] = JSON.parse(row[1])
      end
    end
  end
end
