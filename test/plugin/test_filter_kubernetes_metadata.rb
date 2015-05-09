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
require 'fluent/plugin/filter_kubernetes_metadata'

require 'webmock/test_unit'
WebMock.disable_net_connect!

class KubernetesMetadataFilterTest < Test::Unit::TestCase
  include Fluent

  setup do
    Fluent::Test.setup
    @time = Fluent::Engine.now
  end

  def create_driver(conf = '')
    Test::FilterTestDriver.new(KubernetesMetadataFilter).configure(conf, true)
  end

  sub_test_case 'configure' do
    test 'check default' do
      assert_raise Fluent::ConfigError do
        create_driver
      end
    end

    test 'kubernetes url' do
      VCR.use_cassette('valid_kubernetes_api_server') do
        d = create_driver(%[
          kubernetes_url https://localhost:8443
        ])
        assert_equal('https://localhost:8443', d.instance.kubernetes_url)
        assert_equal(1000, d.instance.cache_size)
      end
    end

    test 'cache size' do
      VCR.use_cassette('valid_kubernetes_api_server') do
        d = create_driver(%[
          kubernetes_url https://localhost:8443
          cache_size 1
        ])
        assert_equal('https://localhost:8443', d.instance.kubernetes_url)
        assert_equal(1, d.instance.cache_size)
      end
    end

    test 'invalid API server config' do
      VCR.use_cassette('invalid_api_server_config') do
        assert_raise Fluent::ConfigError do
          d = create_driver(%[
            kubernetes_url https://localhost:8443
            bearer_token_file test/plugin/test.token
            verify_ssl false
          ])
        end
      end
    end
  end

  sub_test_case 'filter_stream' do

    def emit(msg, config=%[
          kubernetes_url https://localhost:8443
          cache_size 1
        ])
      d = create_driver(config)
      d.run {
        d.emit(msg, @time)
      }.filtered
    end

    test 'with docker & kubernetes metadata' do
      VCR.use_cassette('kubernetes_docker_metadata') do
        msg = {
            :docker => {
                :name => '/k8s_fabric8-console-container.efbd6e64_fabric8-console-controller-98rqc_default_c76927af-f563-11e4-b32d-54ee7527188d_42cbc279'
            }
        }
        es = emit(msg)
        expected_kube_metadata = {
            :kubernetes => {
              :host => "jimmi-redhat.localnet",
              :pod_name =>"fabric8-console-controller-98rqc",
              :container_name => "fabric8-console-container",
              :namespace => "default",
              :uid => "c76927af-f563-11e4-b32d-54ee7527188d",
              :labels => {
                :component => "fabric8Console"
              }
            }
        }
        assert_equal(msg.merge(expected_kube_metadata), es.instance_variable_get(:@record_array)[0])
      end
    end

    test 'with docker & kubernetes metadata using bearer token' do
      VCR.use_cassette('kubernetes_docker_metadata_using_bearer_token') do
        msg = {
            :docker => {
                :name => '/k8s_fabric8-console-container.efbd6e64_fabric8-console-controller-98rqc_default_c76927af-f563-11e4-b32d-54ee7527188d_42cbc279'
            }
        }
        es = emit(msg, %[
          kubernetes_url https://localhost:8443
          verify_ssl false
          bearer_token_file test/plugin/test.token
        ])
        expected_kube_metadata = {
            :kubernetes => {
              :host => "jimmi-redhat.localnet",
              :pod_name =>"fabric8-console-controller-98rqc",
              :container_name => "fabric8-console-container",
              :namespace => "default",
              :uid => "c76927af-f563-11e4-b32d-54ee7527188d",
              :labels => {
                :component => "fabric8Console"
              }
            }
        }
        assert_equal(msg.merge(expected_kube_metadata), es.instance_variable_get(:@record_array)[0])
      end
    end

    test 'with docker metadata, non-kubernetes' do
      VCR.use_cassette('non_kubernetes_docker_metadata') do
        msg = {
            :docker => {
                :name => '/k8s_POD.c0b903ca_fabric8-forge-controller-ymkew_default_bcde9961-f4b7-11e4-bdbf-54ee7527188d_e1f00705'
            }
        }
        es = emit(msg)
        assert_equal(msg, es.instance_variable_get(:@record_array)[0])
        assert_false(es.instance_variable_get(:@record_array)[0].has_key?(:kubernetes))
      end
    end

    test 'without docker metadata' do
      VCR.use_cassette('valid_kubernetes_api_server') do
        msg = {'foo' => 'bar'}
        es = emit(msg)
        assert_equal(msg, es.instance_variable_get(:@record_array)[0])
      end
    end

  end
end