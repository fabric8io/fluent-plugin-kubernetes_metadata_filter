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
    Test::FilterTestDriver.new(KubernetesMetadataFilter, 'var.log.containers.fabric8-console-controller-98rqc_default_fabric8-console-container-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459.log').configure(conf, true)
  end

  sub_test_case 'configure' do
    test 'check default' do
      d = create_driver
      assert_equal(1000, d.instance.cache_size)
    end

    test 'kubernetes url' do
      VCR.use_cassette('valid_kubernetes_api_server') do
        d = create_driver('
          kubernetes_url https://localhost:8443
          watch false
        ')
        assert_equal('https://localhost:8443', d.instance.kubernetes_url)
        assert_equal(1000, d.instance.cache_size)
      end
    end

    test 'cache size' do
      VCR.use_cassette('valid_kubernetes_api_server') do
        d = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
        assert_equal('https://localhost:8443', d.instance.kubernetes_url)
        assert_equal(1, d.instance.cache_size)
      end
    end

    test 'invalid API server config' do
      VCR.use_cassette('invalid_api_server_config') do
        assert_raise Fluent::ConfigError do
          create_driver('
            kubernetes_url https://localhost:8443
            bearer_token_file test/plugin/test.token
            watch false
            verify_ssl false
          ')
        end
      end
    end

    test 'service account credentials' do
      VCR.use_cassette('valid_kubernetes_api_server') do
        begin
          ENV['KUBERNETES_SERVICE_HOST'] = 'localhost'
          ENV['KUBERNETES_SERVICE_PORT'] = '8443'

          Dir.mktmpdir { |dir|
            # Fake token file and CA crt.
            expected_cert_path = File.join(dir, KubernetesMetadataFilter::K8_POD_CA_CERT)
            expected_token_path = File.join(dir, KubernetesMetadataFilter::K8_POD_TOKEN)

            File.open(expected_cert_path, "w") {}
            File.open(expected_token_path, "w") {}

            d = create_driver("
              watch false
              secret_dir #{dir}
            ")

            assert_equal(d.instance.kubernetes_url, "https://localhost:8443/api")
            assert_equal(d.instance.ca_file, expected_cert_path)
            assert_equal(d.instance.bearer_token_file, expected_token_path)
          }
        ensure
          ENV['KUBERNETES_SERVICE_HOST'] = nil
          ENV['KUBERNETES_SERVICE_PORT'] = nil
        end
      end
    end

    test 'service account credential files are tested for existence' do
      VCR.use_cassette('valid_kubernetes_api_server') do
        begin
          ENV['KUBERNETES_SERVICE_HOST'] = 'localhost'
          ENV['KUBERNETES_SERVICE_PORT'] = '8443'

          Dir.mktmpdir { |dir|
            d = create_driver("
              watch false
              secret_dir #{dir}
            ")
            assert_equal(d.instance.kubernetes_url, "https://localhost:8443/api")
            assert_false(d.instance.ca_file.present?)
            assert_false(d.instance.bearer_token_file.present?)
          }
        ensure
          ENV['KUBERNETES_SERVICE_HOST'] = nil
          ENV['KUBERNETES_SERVICE_PORT'] = nil
        end
      end
    end
  end

  sub_test_case 'filter_stream' do

    def emit(msg={}, config='
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
      d = create_driver(config)
      d.run {
        d.emit(msg, @time)
      }.filtered
    end

    def emit_with_tag(tag, msg={}, config='
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
      d = create_driver(config)
      d.run {
        d.emit_with_tag(tag, msg, @time)
      }.filtered
    end

    test 'with docker & kubernetes metadata' do
      VCR.use_cassette('kubernetes_docker_metadata') do
        es = emit()
        expected_kube_metadata = {
          docker: {
              container_id: '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          kubernetes: {
            host:           'jimmi-redhat.localnet',
            pod_name:       'fabric8-console-controller-98rqc',
            container_name: 'fabric8-console-container',
            namespace_name: 'default',
            pod_id:         'c76927af-f563-11e4-b32d-54ee7527188d',
            labels: {
              component: 'fabric8Console'
            }
          }
        }
        assert_equal(expected_kube_metadata, es.instance_variable_get(:@record_array)[0])
      end
    end

    test 'with docker & kubernetes metadata & namespace_id enabled' do
      VCR.use_cassette('metadata_with_namespace_id') do
        es = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_id true
        ')
        expected_kube_metadata = {
          docker: {
              container_id: '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          kubernetes: {
            host:           'jimmi-redhat.localnet',
            pod_name:       'fabric8-console-controller-98rqc',
            container_name: 'fabric8-console-container',
            namespace_name: 'default',
            namespace_id:   '898268c8-4a36-11e5-9d81-42010af0194c',
            pod_id:         'c76927af-f563-11e4-b32d-54ee7527188d',
            labels: {
              component: 'fabric8Console'
            }
          }
        }
        assert_equal(expected_kube_metadata, es.instance_variable_get(:@record_array)[0])
      end
    end

    test 'with docker & kubernetes metadata using bearer token' do
      VCR.use_cassette('kubernetes_docker_metadata_using_bearer_token') do
        es = emit({}, '
          kubernetes_url https://localhost:8443
          verify_ssl false
          watch false
          bearer_token_file test/plugin/test.token
        ')
        expected_kube_metadata = {
          docker: {
            container_id: '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          kubernetes: {
            host:           'jimmi-redhat.localnet',
            pod_name:       'fabric8-console-controller-98rqc',
            container_name: 'fabric8-console-container',
            namespace_name: 'default',
            pod_id:         'c76927af-f563-11e4-b32d-54ee7527188d',
            labels: {
              component: 'fabric8Console'
            }
          }
        }
        assert_equal(expected_kube_metadata, es.instance_variable_get(:@record_array)[0])
      end
    end

    test 'with docker & kubernetes metadata but no configured api server' do
      es = emit({}, '')
      expected_kube_metadata = {
          docker: {
              container_id: '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          kubernetes: {
              pod_name:       'fabric8-console-controller-98rqc',
              container_name: 'fabric8-console-container',
              namespace_name: 'default',
          }
      }
      assert_equal(expected_kube_metadata, es.instance_variable_get(:@record_array)[0])
    end

    test 'with docker & inaccessible kubernetes metadata' do
      stub_request(:any, 'https://localhost:8443/api').to_return(
        body: {
          versions: ['v1beta3', 'v1']
        }.to_json
      )
      stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default/pods/fabric8-console-controller-98rqc').to_timeout
      es = emit()
      expected_kube_metadata = {
        docker: {
          container_id: '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
        },
        kubernetes: {
          pod_name:       'fabric8-console-controller-98rqc',
          container_name: 'fabric8-console-container',
          namespace_name: 'default'
        }
      }
      assert_equal(expected_kube_metadata, es.instance_variable_get(:@record_array)[0])
    end

    test 'with dot in pod name' do
      stub_request(:any, 'https://localhost:8443/api').to_return(
        body: {
          versions: ['v1beta3', 'v1']
        }.to_json
      )
      stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default/pods/fabric8-console-controller.98rqc').to_timeout
      es = emit_with_tag('var.log.containers.fabric8-console-controller.98rqc_default_fabric8-console-container-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459.log', {}, '')
      expected_kube_metadata = {
        docker: {
          container_id: '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
        },
        kubernetes: {
          pod_name:       'fabric8-console-controller.98rqc',
          container_name: 'fabric8-console-container',
          namespace_name: 'default'
        }
      }
      assert_equal(expected_kube_metadata, es.instance_variable_get(:@record_array)[0])
    end

    test 'with docker metadata, non-kubernetes' do
      es = emit_with_tag('non-kubernetes', {}, '')
      assert_false(es.instance_variable_get(:@record_array)[0].has_key?(:kubernetes))
    end

    test 'merges json log data' do
      json_log = {
        'hello' => 'world'
      }
      msg = {
        'log' => "#{json_log.to_json}"
      }
      es = emit_with_tag('non-kubernetes', msg, '')
      assert_equal(msg.merge(json_log), es.instance_variable_get(:@record_array)[0])
    end
  end
end
