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

require 'bundler/setup'
require 'codeclimate-test-reporter'

SimpleCov.start do
  formatter(
    SimpleCov::Formatter::MultiFormatter.new([
                                               SimpleCov::Formatter::HTMLFormatter,
                                               CodeClimate::TestReporter::Formatter
                                             ])
  )
end

require 'test/unit'
require 'fileutils'
require 'fluent/log'
require 'fluent/test'
require 'minitest/autorun'
require 'minitest/pride'
require 'vcr'
require 'ostruct'
require 'fluent/plugin/filter_kubernetes_metadata'
require 'fluent/test/driver/filter'
require 'kubeclient'

require 'webmock/minitest'
WebMock.disable_net_connect!

VCR.configure do |config|
  config.cassette_library_dir = 'test/cassettes'
  config.hook_into :webmock # or :fakeweb
  config.ignore_hosts 'codeclimate.com'
end

def unused_port
  s = TCPServer.open(0)
  port = s.addr[1]
  s.close
  port
end

def ipv6_enabled?
  require 'socket'

  begin
    TCPServer.open('::1', 0)
    true
  rescue StandardError
    false
  end
end
