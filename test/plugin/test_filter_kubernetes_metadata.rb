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

class KubernetesMetadataFilterTest < Test::Unit::TestCase
  include Fluent

  setup do
    Fluent::Test.setup
    @time = Fluent::Engine.now
  end

  VAR_LOG_CONTAINER_TAG = 'var.log.containers.fabric8-console-controller-98rqc_default_fabric8-console-container-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459.log'
  VAR_LOG_POD_TAG = 'var.log.pods.default_fabric8-console-controller-98rqc_c76927af-f563-11e4-b32d-54ee7527188d.fabric8-console-container.0.log'

  def create_driver(conf = '')
    Test::Driver::Filter.new(Plugin::KubernetesMetadataFilter).configure(conf)
  end

  sub_test_case 'configure' do
    test 'check default' do
      d = create_driver
      assert_equal(1000, d.instance.cache_size)
    end

    sub_test_case 'stats_interval' do

      test 'enables stats when greater than zero' do
        d = create_driver('stats_interval 1')
        assert_equal(1, d.instance.stats_interval)
        d.instance.dump_stats
        assert_false(d.instance.instance_variable_get("@curr_time").nil?)
      end

      test 'disables stats when <= zero' do
        d = create_driver('stats_interval 0')
        assert_equal(0, d.instance.stats_interval)
         d.instance.dump_stats
        assert_nil(d.instance.instance_variable_get("@curr_time"))
      end

    end

    test 'check test_api_adapter' do
      d = create_driver('test_api_adapter KubernetesMetadata::TestApiAdapter')
      assert_equal('KubernetesMetadata::TestApiAdapter', d.instance.test_api_adapter)
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
        ENV['KUBERNETES_SERVICE_HOST'] = 'localhost'
        ENV['KUBERNETES_SERVICE_PORT'] = '8443'

        Dir.mktmpdir do |dir|
          # Fake token file and CA crt.
          expected_cert_path = File.join(dir, Plugin::KubernetesMetadataFilter::K8_POD_CA_CERT)
          expected_token_path = File.join(dir, Plugin::KubernetesMetadataFilter::K8_POD_TOKEN)

          File.open(expected_cert_path, 'w')
          File.open(expected_token_path, 'w')

          d = create_driver("
              watch false
              secret_dir #{dir}
            ")

          assert_equal(d.instance.kubernetes_url, 'https://localhost:8443/api')
          assert_equal(d.instance.ca_file, expected_cert_path)
          assert_equal(d.instance.bearer_token_file, expected_token_path)
        end
      ensure
        ENV['KUBERNETES_SERVICE_HOST'] = nil
        ENV['KUBERNETES_SERVICE_PORT'] = nil
      end
    end

    test 'service account credential files are tested for existence' do
      VCR.use_cassette('valid_kubernetes_api_server') do
        ENV['KUBERNETES_SERVICE_HOST'] = 'localhost'
        ENV['KUBERNETES_SERVICE_PORT'] = '8443'

        Dir.mktmpdir do |dir|
          d = create_driver("
              watch false
              secret_dir #{dir}
            ")
          assert_equal(d.instance.kubernetes_url, 'https://localhost:8443/api')
          assert_nil(d.instance.ca_file, nil)
          assert_nil(d.instance.bearer_token_file)
        end
      ensure
        ENV['KUBERNETES_SERVICE_HOST'] = nil
        ENV['KUBERNETES_SERVICE_PORT'] = nil
      end
    end
  end

  sub_test_case 'filter' do
    def emit(msg = {}, config = '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ', d: nil)
      d = create_driver(config) if d.nil?
      d.run(default_tag: VAR_LOG_CONTAINER_TAG) do
        d.feed(@time, msg)
      end
      d.filtered.map(&:last)
    end

    def emit_with_tag(tag, msg = {}, config = '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
      d = create_driver(config)
      d.run(default_tag: tag) do
        d.feed(@time, msg)
      end
      d.filtered.map(&:last)
    end

    sub_test_case 'parsing_pod_metadata when container_status is missing from the pod status' do
      test 'using the tag_to_kubernetes_name_regexp for /var/log/containers ' do
        VCR.use_cassettes(
          [
            { name: 'valid_kubernetes_api_server' },
            { name: 'kubernetes_get_api_v1' },
            { name: 'kubernetes_get_namespace_default' },
            { name: 'kubernetes_get_pod_container_init' }
          ]) do
          filtered = emit({}, "
            kubernetes_url https://localhost:8443
            watch false
            cache_size 1
          ")
          expected_kube_metadata = {
            'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
            },
            'kubernetes' => {
              'container_image'=>'fabric8/hawtio-kubernetes:latest',
              'container_name'=>'fabric8-console-container',
              'host' => 'jimmi-redhat.localnet',
              'pod_name' => 'fabric8-console-controller-98rqc',
              'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
              'namespace_name' => 'default',
              'namespace_labels' => {
                'tenant' => 'test'
              },
              'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
              'pod_ip' => '172.17.0.8',
              'master_url' => 'https://localhost:8443',
              'labels' => {
                'component' => 'fabric8Console'
              }
            }
          }
          assert_equal(expected_kube_metadata, filtered[0])
        end
      end
      test 'using the tag_to_kubernetes_name_regexp for /var/log/pods' do
        VCR.use_cassettes(
          [
            { name: 'valid_kubernetes_api_server' },
            { name: 'kubernetes_get_api_v1' },
            { name: 'kubernetes_get_namespace_default' },
            { name: 'kubernetes_get_pod_container_init' }
          ]) do
          filtered = emit_with_tag(VAR_LOG_POD_TAG,{}, "
            kubernetes_url https://localhost:8443
            watch false
            cache_size 1
          ")
          expected_kube_metadata = {
            'kubernetes' => {
              'container_image'=>'fabric8/hawtio-kubernetes:latest',
              'container_name'=>'fabric8-console-container',
              'host' => 'jimmi-redhat.localnet',
              'pod_name' => 'fabric8-console-controller-98rqc',
              'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
              'namespace_name' => 'default',
              'namespace_labels' => {
                'tenant' => 'test'
              },
              'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
              'pod_ip' => '172.17.0.8',
              'master_url' => 'https://localhost:8443',
              'labels' => {
                'component' => 'fabric8Console'
              }
            }
          }
          assert_equal(expected_kube_metadata, filtered[0])
        end
      end
    end

    test 'inability to connect to the api server handles exception and doensnt block pipeline' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }]) do
        driver = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
        stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default/pods/fabric8-console-controller-98rqc').to_raise(SocketError.new('error from pod fetch'))
        stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default').to_raise(SocketError.new('socket error from namespace fetch'))
        filtered = emit({ 'time' => '2015-05-08T09:22:01Z' }, '', d: driver)
        expected_kube_metadata = {
          'time' => '2015-05-08T09:22:01Z',
          'docker'=>{
            'container_id'=>'49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_id' => 'orphaned',
            'namespace_name' => '.orphaned',
            'orphaned_namespace' => 'default'
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata where id cache hit and metadata miss' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }]) do
        driver = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
        cache = driver.instance.instance_variable_get(:@id_cache)
        cache['49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'] = {
          pod_id: 'c76927af-f563-11e4-b32d-54ee7527188d',
          namespace_id: '898268c8-4a36-11e5-9d81-42010af0194c'
        }
        stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default/pods/fabric8-console-controller-98rqc').to_timeout
        stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default').to_timeout
        filtered = emit({ 'time' => '2015-05-08T09:22:01Z' }, '', d: driver)
        expected_kube_metadata = {
          'time' => '2015-05-08T09:22:01Z',
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d'
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata where id cache hit and metadata is reloaded' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }, { name: 'kubernetes_get_pod' }, { name: 'kubernetes_get_namespace_default' }]) do
        driver = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
        cache = driver.instance.instance_variable_get(:@id_cache)
        cache['49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'] = {
          pod_id: 'c76927af-f563-11e4-b32d-54ee7527188d',
          namespace_id: '898268c8-4a36-11e5-9d81-42010af0194c'
        }
        filtered = emit({ 'time' => '2015-05-08T09:22:01Z' }, '', d: driver)
        expected_kube_metadata = {
          'time' => '2015-05-08T09:22:01Z',
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'namespace_labels' => {
              'tenant' => 'test'
            },
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'master_url' => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata' do

      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }, { name: 'kubernetes_get_pod' }, { name: 'kubernetes_get_namespace_default' }]) do
        filtered = emit({ 'time' => '2015-05-08T09:22:01Z' })
        expected_kube_metadata = {
          'time' => '2015-05-08T09:22:01Z',
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'namespace_labels' => {
              'tenant' => 'test'
            },
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'master_url' => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'kubernetes metadata is cloned so it further processing does not modify the cache' do

      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }, { name: 'kubernetes_get_pod' }, { name: 'kubernetes_get_namespace_default' }]) do

        d = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1')
        d.run(default_tag: VAR_LOG_POD_TAG) do
          d.feed(@time, { 'time' => '2015-05-08T09:22:01Z' })
          d.feed(@time, { 'time' => '2015-05-08T09:22:01Z' })
        end
        filtered = d.filtered.map(&:last)
        assert_not_equal(filtered[0]['kubernetes']['labels'].object_id, filtered[1]['kubernetes']['labels'].object_id, "Exp. meta to be cloned")
      end
    end

    test 'with docker & kubernetes metadata & namespace_id enabled' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }, { name: 'kubernetes_get_pod' },
                         { name: 'kubernetes_get_namespace_default', options: { allow_playback_repeats: true } }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
        expected_kube_metadata = {
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'namespace_labels' => {
              'tenant' => 'test'
            },
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'master_url' => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata using bearer token' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server_using_token' }, { name: 'kubernetes_get_api_v1_using_token' },
                         { name: 'kubernetes_get_pod_using_token' }, { name: 'kubernetes_get_namespace_default_using_token' }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          verify_ssl false
          watch false
          bearer_token_file test/plugin/test.token
        ')
        expected_kube_metadata = {
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'master_url' => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata but no configured api server' do
      filtered = emit({}, '')
      expected_kube_metadata = {
        'docker'=>{
          'container_id'=>'49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
        },
        'kubernetes' => {
          'pod_name' => 'fabric8-console-controller-98rqc',
          'container_name' => 'fabric8-console-container',
          'namespace_name' => 'default'
        }
      }
      assert_equal(expected_kube_metadata, filtered[0])
    end

    test 'with docker & inaccessible kubernetes metadata' do
      stub_request(:any, 'https://localhost:8443/api').to_return(
        'body' => {
          'versions' => ['v1beta3', 'v1']
        }.to_json
      )
      stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default/pods/fabric8-console-controller-98rqc').to_timeout
      stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default').to_timeout
      filtered = emit
      expected_kube_metadata = {
        'docker'=>{
          'container_id'=>'49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
        },
        'kubernetes' => {
          'pod_name' => 'fabric8-console-controller-98rqc',
          'container_name' => 'fabric8-console-container',
          'namespace_name' => '.orphaned',
          'orphaned_namespace' => 'default',
          'namespace_id' => 'orphaned'
        }
      }
      assert_equal(expected_kube_metadata, filtered[0])
    end

    test 'with dot in pod name' do
      stub_request(:any, 'https://localhost:8443/api').to_return(
        'body' => {
          'versions' => ['v1beta3', 'v1']
        }.to_json
      )
      stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default/pods/fabric8-console-controller.98rqc').to_timeout
      filtered = emit_with_tag('var.log.containers.fabric8-console-controller.98rqc_default_fabric8-console-container-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459.log', {}, '')
      expected_kube_metadata = {
        'docker'=>{
          'container_id'=>'49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
        },
        'kubernetes' => {
          'pod_name' => 'fabric8-console-controller.98rqc',
          'container_name' => 'fabric8-console-container',
          'namespace_name' => 'default'
        }
      }
      assert_equal(expected_kube_metadata, filtered[0])
    end

    test 'with docker metadata, non-kubernetes' do
      filtered = emit_with_tag('non-kubernetes', {}, '')
      assert_false(filtered[0].key?(:kubernetes))
    end

    test 'ignores invalid json in log field' do
      json_log = "{'foo':123}"
      msg = {
        'log' => json_log
      }
      filtered = emit_with_tag('non-kubernetes', msg, '')
      assert_equal(msg, filtered[0])
    end

    test 'with kubernetes annotations' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' },
                         { name: 'kubernetes_docker_metadata_annotations' },
                         { name: 'kubernetes_get_namespace_default' }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          annotation_match [ "^custom.+", "two"]
        ')
        expected_kube_metadata = {
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'master_url' => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            },
            'annotations' => {
              'custom.field1' => 'hello_kitty',
              'field.two' => 'value'
            }
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with kubernetes namespace annotations' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' },
                         { name: 'kubernetes_docker_metadata_annotations' },
                         { name: 'kubernetes_get_namespace_default' }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          annotation_match [ "^custom.+", "two", "workspace*"]
        ')
        expected_kube_metadata = {
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'master_url' => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            },
            'annotations' => {
              'custom.field1' => 'hello_kitty',
              'field.two' => 'value'
            },
            'namespace_annotations' => {
              'workspaceId' => 'myWorkspaceName'
            }
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with kubernetes namespace annotations no match' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' },
                         { name: 'kubernetes_docker_metadata_annotations' },
                         { name: 'kubernetes_get_namespace_default' }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          annotation_match [ "noMatch*"]
        ')
        expected_kube_metadata = {
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'master_url' => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'processes all events when reading from MessagePackEventStream' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' },
                         { name: 'kubernetes_get_api_v1' },
                         { name: 'kubernetes_get_pod' },
                         { name: 'kubernetes_get_namespace_default' }]) do
        entries = [[@time, { 'time' => '2015-05-08T09:22:01Z' }], [@time, { 'time' => '2015-05-08T09:22:01Z' }]]
        array_stream = Fluent::ArrayEventStream.new(entries)
        msgpack_stream = Fluent::MessagePackEventStream.new(array_stream.to_msgpack_stream)

        d = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          stats_interval 0
        ')
        d.run do
          d.feed(VAR_LOG_CONTAINER_TAG, msgpack_stream)
        end
        filtered = d.filtered.map(&:last)

        expected_kube_metadata = {
          'time' => '2015-05-08T09:22:01Z',
          'docker' => {
            'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            'namespace_id' => '898268c8-4a36-11e5-9d81-42010af0194c',
            'namespace_labels' => {
              'tenant' => 'test'
            },
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'master_url' => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
        assert_equal(expected_kube_metadata, filtered[1])
      end
    end

    test 'with docker & kubernetes metadata using skip config params' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }, { name: 'kubernetes_get_pod' },
                         { name: 'kubernetes_get_namespace_default' }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          skip_labels true
          skip_container_metadata true
          skip_master_url true
          skip_namespace_metadata true
        ')
        expected_kube_metadata = {
          'docker'=>{
            'container_id'=>'49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8'
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata using skip namespace labels config param' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }, { name: 'kubernetes_get_pod' },
                         { name: 'kubernetes_get_namespace_default' }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          stats_interval 0
          skip_namespace_labels true
          skip_master_url true
        ')
        expected_kube_metadata = {
          'docker'=>{
            'container_id'=>'49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            "namespace_id"=>"898268c8-4a36-11e5-9d81-42010af0194c",
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end
    test 'with docker & kubernetes metadata using skip pod labels config param' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' }, { name: 'kubernetes_get_api_v1' }, { name: 'kubernetes_get_pod' },
                         { name: 'kubernetes_get_namespace_default' }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          stats_interval 0
          skip_pod_labels true
          skip_master_url true
        ')
        expected_kube_metadata = {
          'docker'=>{
            'container_id'=>'49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            "namespace_id"=>"898268c8-4a36-11e5-9d81-42010af0194c",
            'namespace_labels' => {
              'tenant' => 'test'
            },
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end
    test 'with docker & kubernetes metadata using include ownerrefs metadata' do
      VCR.use_cassettes([{ name: 'valid_kubernetes_api_server' },
                         { name: 'kubernetes_get_api_v1' },
                         { name: 'kubernetes_get_pod_with_ownerrefs' },
                         { name: 'kubernetes_get_namespace_default' }]) do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          stats_interval 0
          skip_pod_labels true
          skip_master_url true
          include_ownerrefs_metadata true
        ')
        expected_kube_metadata = {
          'docker'=>{
            'container_id'=>'49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host' => 'jimmi-redhat.localnet',
            'pod_name' => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'container_image' => 'fabric8/hawtio-kubernetes:latest',
            'container_image_id' => 'docker://b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303',
            'namespace_name' => 'default',
            "namespace_id"=>"898268c8-4a36-11e5-9d81-42010af0194c",
            'namespace_labels' => {
              'tenant' => 'test'
            },
            'pod_id' => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'pod_ip' => '172.17.0.8',
            'ownerrefs' => [{
              'kind' => 'ReplicaSet',
              'name' => 'fabric8-console-controller'
            }]
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

  end
end
