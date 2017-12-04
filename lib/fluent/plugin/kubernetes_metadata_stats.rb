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
require 'lru_redux'
module KubernetesMetadata
  class Stats

    def initialize
      @stats = ::LruRedux::TTL::ThreadSafeCache.new(1000, 3600)
    end

    def bump(key)
        @stats[key] = @stats.getset(key) { 0 } + 1
    end

    def set(key, value)
       @stats[key] = value
    end

    def [](key)
      @stats[key]
    end

    def to_s
      "stats - " + [].tap do |a|
          @stats.each {|k,v| a << "#{k.to_s}: #{v}"}
      end.join(', ')
    end

  end
end
