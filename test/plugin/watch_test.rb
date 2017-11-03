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
require 'ostruct'

class WatchTest < Test::Unit::TestCase
   
    setup do
      @annotations_regexps = []
      @namespace_cache = {}
      @cache = {}
      @stats = KubernetesMetadata::Stats.new
      @client = OpenStruct.new
      def @client.resourceVersion
        '12345'
      end
      def @client.watch_pods(value)
         []
      end
      def @client.watch_namespaces(value)
         []
      end
      def @client.get_namespaces 
          self
      end
      def @client.get_pods
          self
      end
    end

    def watcher=(value)
    end

    def log
        logger = {}
        def logger.debug(message)
        end
        logger
    end

end
