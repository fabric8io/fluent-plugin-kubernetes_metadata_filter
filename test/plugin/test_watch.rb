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

class TestWatch < Test::Unit::TestCase
  def thread_current_running?
    true
  end

  setup do
    @annotations_regexps = []
    @namespace_cache = {}
    @watch_retry_max_times = 2
    @watch_retry_interval = 1
    @watch_retry_exponential_backoff_base = 2
    @cache = {}
    @stats = KubernetesMetadata::Stats.new
    Thread.current[:pod_watch_retry_count] = 0
    Thread.current[:namespace_watch_retry_count] = 0

    @client = {}

    def @client.watch_pods(_options = {})
      []
    end

    def @client.watch_namespaces(_options = {})
      []
    end

    def @client.get_namespaces(_options = {})
      { items: [], metadata: { resourceVersion: '12345' } }
    end

    def @client.get_pods(_options = {})
      { items: [], metadata: { resourceVersion: '12345' } }
    end

    @exception_raised = :blow_up_when_used
  end

  def watcher=(value)
  end

  def log
    logger = {}

    def logger.debug(message)
    end

    def logger.info(message, error)
    end

    def logger.error(message, error)
    end

    def logger.warn(message)
    end

    logger
  end
end
