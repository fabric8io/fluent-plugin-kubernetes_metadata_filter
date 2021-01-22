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
class KubernetesMetadataCacheStatsTest < Test::Unit::TestCase
  include KubernetesMetadata::Util

  def setup
    @time_fields = ['time']
    @internal_time = Time.now
  end

  test '#create_time_from_record when time is empty' do
    record = { 'time' => ' ' }
    assert_equal(@internal_time.to_i, create_time_from_record(record, @internal_time).to_i)
  end
  test '#create_time_from_record when time is nil' do
    record = {}
    assert_equal(@internal_time.to_i, create_time_from_record(record, @internal_time).to_i)
  end

  test '#create_time_from_record when time is an integer' do
    exp_time = Time.now
    record = { 'time' => exp_time.to_i }
    assert_equal(exp_time.to_i, create_time_from_record(record, @internal_time).to_i)
  end

  test '#create_time_from_record when time is a string' do
    exp_time = Time.now
    record = { 'time' => exp_time.to_s }
    assert_equal(exp_time.to_i, create_time_from_record(record, @internal_time).to_i)
  end

  test '#create_time_from_record when timefields include journal time fields' do
    @time_fields = ['_SOURCE_REALTIME_TIMESTAMP']
    exp_time = Time.now
    record = { '_SOURCE_REALTIME_TIMESTAMP' => exp_time.to_i.to_s }
    assert_equal(Time.at(exp_time.to_i / 1_000_000, exp_time.to_i % 1_000_000).to_i, create_time_from_record(record, @internal_time).to_i)
  end
end
