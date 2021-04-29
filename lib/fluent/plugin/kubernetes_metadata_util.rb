# frozen_string_literal: true

#
# Fluentd Kubernetes Metadata Filter Plugin - Enrich Fluentd events with
# Kubernetes metadata
#
# Copyright 2021 Red Hat, Inc.
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
module KubernetesMetadata
  module Util
    def create_time_from_record(record, internal_time)
      time_key = @time_fields.detect { |ii| record.key?(ii) }
      time = record[time_key]
      if time.nil? || time.is_a?(String) && time.chop.empty?
        # `internal_time` is a Fluent::EventTime, it can't compare with Time.
        return Time.at(internal_time.to_f)
      end

      if ['_SOURCE_REALTIME_TIMESTAMP', '__REALTIME_TIMESTAMP'].include?(time_key)
        timei = time.to_i
        return Time.at(timei / 1_000_000, timei % 1_000_000)
      end
      return Time.at(time) if time.is_a?(Numeric)

      Time.parse(time)
    end
  end
end

#https://stackoverflow.com/questions/5622435/how-do-i-convert-a-ruby-class-name-to-a-underscore-delimited-symbol
class String
  def underscore
    word = self.dup
    word.gsub!(/::/, '_')
    word.gsub!(/([A-Z]+)([A-Z][a-z])/,'\1_\2')
    word.gsub!(/([a-z\d])([A-Z])/,'\1_\2')
    word.tr!("-", "_")
    word.downcase!
    word
  end
end