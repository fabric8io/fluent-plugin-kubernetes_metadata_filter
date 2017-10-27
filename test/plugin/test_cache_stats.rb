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
require 'fluent/plugin/kubernetes_metadata_stats'
require 'webmock/test_unit'
WebMock.disable_net_connect!

class KubernetesMetadataCacheStatsTest < Test::Unit::TestCase
  
    test 'watch stats' do
      require 'lru_redux'
      stats = KubernetesMetadata::Stats.new
      stats.bump(:missed)
      stats.bump(:deleted)
      stats.bump(:deleted)

      assert_equal("stats - deleted: 2, missed: 1", stats.to_s)
    end
    
end
