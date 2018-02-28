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
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_kubernetes_metadata'

require 'webmock/test_unit'
WebMock.disable_net_connect!

class KubernetesMetadataFilterTest < Test::Unit::TestCase
  include Fluent

  setup do
    Fluent::Test.setup
    @time = Fluent::Engine.now
  end

  DEFAULT_TAG = 'var.log.containers.fabric8-console-controller-98rqc_default_fabric8-console-container-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459.log'

  def create_driver(conf = '')
    Test::Driver::Filter.new(Plugin::KubernetesMetadataFilter).configure(conf)
  end

  sub_test_case 'dump_stats' do

    test 'dump stats with include_namespace_metadata' do
      VCR.use_cassette('kubernetes_docker_metadata') do
        d = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_metadata false
          stats_interval 0
        ')
        d.instance.dump_stats
      end
    end

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
            expected_cert_path = File.join(dir, Plugin::KubernetesMetadataFilter::K8_POD_CA_CERT)
            expected_token_path = File.join(dir, Plugin::KubernetesMetadataFilter::K8_POD_TOKEN)

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
          include_namespace_metadata true
        ', d: nil)
      d = create_driver(config) if d.nil?
      if ENV['LOGLEVEL'] 
        logger = Logger.new(STDOUT)
        logger.level = eval("Logger::#{ENV['LOGLEVEL'].upcase}")
        instance = d.instance
        instance.instance_variable_set(:@log,logger)
      end
      d.run(default_tag: DEFAULT_TAG) {
        d.feed(@time, msg)
      }
      d.filtered.map{|e| e.last}
    end

    def emit_with_tag(tag, msg={}, config='
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
        ')
      d = create_driver(config)
      d.run(default_tag: tag) {
        d.feed(@time, msg)
      }
      d.filtered.map{|e| e.last}
    end

    test 'with docker & kubernetes metadata where id cache hit and metadata miss' do
      VCR.use_cassette('kubernetes_docker_metadata') do
        driver = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_metadata true
        ')
        cache = driver.instance.instance_variable_get(:@id_cache)
        cache['49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'] = {
            :pod_id       =>'c76927af-f563-11e4-b32d-54ee7527188d',
            :namespace_id =>'898268c8-4a36-11e5-9d81-42010af0194c'
        }
        stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default/pods/fabric8-console-controller-98rqc').to_timeout
        stub_request(:any, 'https://localhost:8443/api/v1/namespaces/default').to_timeout
        filtered = emit({'time'=>'2015-05-08T09:22:01Z'}, '', d:driver)
        expected_kube_metadata = {
          'time'=>'2015-05-08T09:22:01Z',
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'pod_name'       => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata where id cache hit and metadata is reloaded' do
      VCR.use_cassette('kubernetes_docker_metadata') do
        driver = create_driver('
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_metadata true
        ')
        cache = driver.instance.instance_variable_get(:@id_cache)
        cache['49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'] = {
            :pod_id       =>'c76927af-f563-11e4-b32d-54ee7527188d',
            :namespace_id =>'898268c8-4a36-11e5-9d81-42010af0194c'
        }
        filtered = emit({'time'=>'2015-05-08T09:22:01Z'}, '', d:driver)
        expected_kube_metadata = {
          'time'=>'2015-05-08T09:22:01Z',
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host'           => 'jimmi-redhat.localnet',
            'pod_name'       => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'     => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata' do
      VCR.use_cassette('kubernetes_docker_metadata') do
        filtered = emit({'time'=>'2015-05-08T09:22:01Z'})
        expected_kube_metadata = {
          'time'=>'2015-05-08T09:22:01Z',
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host'           => 'jimmi-redhat.localnet',
            'pod_name'       => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'     => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }

        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata & namespace_id enabled' do
      VCR.use_cassette('metadata_with_namespace_id') do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_id true
        ')
        expected_kube_metadata = {
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host'           => 'jimmi-redhat.localnet',
            'pod_name'       => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'     => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with docker & kubernetes metadata using bearer token' do
      VCR.use_cassette('kubernetes_docker_metadata_using_bearer_token') do
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
            'host'           => 'jimmi-redhat.localnet',
            'pod_name'       => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'     => 'https://localhost:8443',
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
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
              'pod_name'       => 'fabric8-console-controller-98rqc',
              'container_name' => 'fabric8-console-container',
              'namespace_name' => 'default',
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
      filtered = emit()
      expected_kube_metadata = {
        'docker' => {
          'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
        },
        'kubernetes' => {
          'pod_name'       => 'fabric8-console-controller-98rqc',
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
        'docker' => {
          'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
        },
        'kubernetes' => {
          'pod_name'       => 'fabric8-console-controller.98rqc',
          'container_name' => 'fabric8-console-container',
          'namespace_name' => 'default'
        }
      }
      assert_equal(expected_kube_metadata, filtered[0])
    end

    test 'with docker metadata, non-kubernetes' do
      filtered = emit_with_tag('non-kubernetes', {}, '')
      assert_false(filtered[0].has_key?(:kubernetes))
    end

    test 'merges json log data' do
      json_log = {
        'hello' => 'world'
      }
      msg = {
        'log' => "#{json_log.to_json}"
      }
      filtered = emit_with_tag('non-kubernetes', msg, '')
      assert_equal(msg.merge(json_log), filtered[0])
    end

    test 'merges json log data in MESSAGE' do
      json_log = {
        'hello' => 'world'
      }
      msg = {
        'MESSAGE' => "#{json_log.to_json}"
      }
      filtered = emit_with_tag('non-kubernetes', msg, 'use_journal true')
      assert_equal(msg.merge(json_log), filtered[0])
    end

    test 'merges json log data with message field' do
      json_log = {
        'timeMillis' => 1459853347608,
        'thread' => 'main',
        'level' => 'INFO',
        'loggerName' => 'org.apache.camel.spring.SpringCamelContext',
        'message' => 'Total 1 routes, of which 1 is started.',
        'endOfBatch' => false,
        'loggerFqcn' => 'org.apache.logging.slf4j.Log4jLogger'
      }
      msg = {
        'log' => "#{json_log.to_json}"
      }
      filtered = emit_with_tag('non-kubernetes', msg, '')
      assert_equal(msg.merge(json_log), filtered[0])
    end

    test 'ignores invalid json in log field' do
      json_log = "{'foo':123}"
      msg = {
          'log' => json_log
      }
      filtered = emit_with_tag('non-kubernetes', msg, '')
      assert_equal(msg, filtered[0])
    end

    test 'merges json log data with message field in MESSAGE' do
      json_log = {
        'timeMillis' => 1459853347608,
        'thread' => 'main',
        'level' => 'INFO',
        'loggerName' => 'org.apache.camel.spring.SpringCamelContext',
        'message' => 'Total 1 routes, of which 1 is started.',
        'endOfBatch' => false,
        'loggerFqcn' => 'org.apache.logging.slf4j.Log4jLogger'
      }
      msg = {
        'MESSAGE' => "#{json_log.to_json}"
      }
      filtered = emit_with_tag('non-kubernetes', msg, 'use_journal true')
      assert_equal(msg.merge(json_log), filtered[0])
    end

    test 'emit individual fields from json, throw out whole original string' do
      json_log = {
        'hello' => 'world',
        'more' => 'data'
      }
      msg = {
        'log' => "#{json_log.to_json}"
      }
      filtered = emit_with_tag('non-kubernetes', msg, 'preserve_json_log false')
      assert_equal(json_log, filtered[0])
    end

    test 'emit individual fields from json, throw out whole original string in MESSAGE' do
      json_log = {
        'hello' => 'world',
        'more' => 'data'
      }
      msg = {
        'MESSAGE' => "#{json_log.to_json}"
      }
      filtered = emit_with_tag('non-kubernetes', msg, '
preserve_json_log false
use_journal true
')
      assert_equal(json_log, filtered[0])
    end

    test 'with kubernetes dotted labels, de_dot enabled' do
      VCR.use_cassette('kubernetes_docker_metadata_dotted_labels') do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_metadata true
        ')
        expected_kube_metadata = {
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host'             => 'jimmi-redhat.localnet',
            'pod_name'         => 'fabric8-console-controller-98rqc',
            'container_name'   => 'fabric8-console-container',
            'namespace_id'     => '898268c8-4a36-11e5-9d81-42010af0194c',
            'namespace_labels' => {
              'kubernetes_io/namespacetest' => 'somevalue'
            },
            'namespace_name'   => 'default',
            'pod_id'           => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'       => 'https://localhost:8443',
            'labels' => {
              'kubernetes_io/test' => 'somevalue'
            }
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with kubernetes dotted labels, de_dot disabled' do
      VCR.use_cassette('kubernetes_docker_metadata_dotted_labels') do
        filtered = emit({}, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          de_dot false
          include_namespace_metadata true
        ')
        expected_kube_metadata = {
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host'             => 'jimmi-redhat.localnet',
            'pod_name'         => 'fabric8-console-controller-98rqc',
            'container_name'   => 'fabric8-console-container',
            'namespace_id'     => '898268c8-4a36-11e5-9d81-42010af0194c',
            'namespace_labels' => {
              'kubernetes.io/namespacetest' => 'somevalue'
            },
            'namespace_name'   => 'default',
            'pod_id'           => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'       => 'https://localhost:8443',
            'labels' => {
              'kubernetes.io/test' => 'somevalue'
            }
          }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'invalid de_dot_separator config' do
      assert_raise Fluent::ConfigError do
        create_driver('
          de_dot_separator contains.
        ')
      end
    end

    test 'with records from journald and docker & kubernetes metadata' do
      # with use_journal true should ignore tags and use CONTAINER_NAME and CONTAINER_ID_FULL
      tag = 'var.log.containers.junk1_junk2_junk3-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed450.log'
      msg = {
        'CONTAINER_NAME' => 'k8s_fabric8-console-container.db89db89_fabric8-console-controller-98rqc_default_c76927af-f563-11e4-b32d-54ee7527188d_89db89db',
        'CONTAINER_ID_FULL' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459',
        'randomfield' => 'randomvalue'
      }
      VCR.use_cassette('kubernetes_docker_metadata') do
        filtered = emit_with_tag(tag, msg, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          use_journal true
        ')
        expected_kube_metadata = {
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host'           => 'jimmi-redhat.localnet',
            'pod_name'       => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'     => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }.merge(msg)
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with records from journald and docker & kubernetes metadata & namespace_id enabled' do
      # with use_journal true should ignore tags and use CONTAINER_NAME and CONTAINER_ID_FULL
      tag = 'var.log.containers.junk1_junk2_junk3-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed450.log'
      msg = {
        'CONTAINER_NAME' => 'k8s_fabric8-console-container.db89db89_fabric8-console-controller-98rqc_default_c76927af-f563-11e4-b32d-54ee7527188d_89db89db',
        'CONTAINER_ID_FULL' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459',
        'randomfield' => 'randomvalue'
      }
      VCR.use_cassette('metadata_with_namespace_id') do
        filtered = emit_with_tag(tag, msg, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_id true
          use_journal true
        ')
        expected_kube_metadata = {
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host'           => 'jimmi-redhat.localnet',
            'pod_name'       => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'     => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }.merge(msg)
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with kubernetes annotations' do
      VCR.use_cassette('kubernetes_docker_metadata_annotations') do
        filtered = emit({},'
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
                'host'           => 'jimmi-redhat.localnet',
                'pod_name'       => 'fabric8-console-controller-98rqc',
                'container_name' => 'fabric8-console-container',
                'namespace_name' => 'default',
                'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
                'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
                'master_url'     => 'https://localhost:8443',
                'labels'         => {
                    'component' => 'fabric8Console'
                },
                'annotations'    => {
                    'custom_field1' => 'hello_kitty',
                    'field_two' => 'value'
                }
            }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with records from journald and docker & kubernetes metadata, alternate form' do
      # with use_journal true should ignore tags and use CONTAINER_NAME and CONTAINER_ID_FULL
      tag = 'var.log.containers.junk1_junk2_junk3-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed450.log'
      msg = {
        'CONTAINER_NAME' => 'alt_fabric8-console-container_fabric8-console-controller-98rqc_default_c76927af-f563-11e4-b32d-54ee7527188d_0',
        'CONTAINER_ID_FULL' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459',
        'randomfield' => 'randomvalue'
      }
      VCR.use_cassette('kubernetes_docker_metadata') do
        filtered = emit_with_tag(tag, msg, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          use_journal true
        ')
        expected_kube_metadata = {
          'docker' => {
              'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
          },
          'kubernetes' => {
            'host'           => 'jimmi-redhat.localnet',
            'pod_name'       => 'fabric8-console-controller-98rqc',
            'container_name' => 'fabric8-console-container',
            'namespace_name' => 'default',
            'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
            'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
            'master_url'     => 'https://localhost:8443',
            'labels' => {
              'component' => 'fabric8Console'
            }
          }
        }.merge(msg)
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with kubernetes namespace annotations' do
      VCR.use_cassette('kubernetes_docker_metadata_annotations') do
        filtered = emit({},'
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_metadata true
          annotation_match [ "^custom.+", "two", "workspace*"]
        ')
        expected_kube_metadata = {
            'docker' => {
                'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
            },
            'kubernetes' => {
                'host'           => 'jimmi-redhat.localnet',
                'pod_name'       => 'fabric8-console-controller-98rqc',
                'container_name' => 'fabric8-console-container',
                'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
                'namespace_name' => 'default',
                'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
                'master_url'     => 'https://localhost:8443',
                'labels'         => {
                    'component' => 'fabric8Console'
                },
                'annotations'    => {
                    'custom_field1' => 'hello_kitty',
                    'field_two' => 'value'
                },
                'namespace_annotations'    => {
                    'workspaceId' => 'myWorkspaceName'
                }
            }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end

    test 'with kubernetes namespace annotations no match' do
      VCR.use_cassette('kubernetes_docker_metadata_annotations') do
        filtered = emit({},'
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          include_namespace_metadata true
          annotation_match [ "noMatch*"]
        ')
        expected_kube_metadata = {
            'docker' => {
                'container_id' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459'
            },
            'kubernetes' => {
                'host'           => 'jimmi-redhat.localnet',
                'pod_name'       => 'fabric8-console-controller-98rqc',
                'container_name' => 'fabric8-console-container',
                'namespace_id'   => '898268c8-4a36-11e5-9d81-42010af0194c',
                'namespace_name' => 'default',
                'pod_id'         => 'c76927af-f563-11e4-b32d-54ee7527188d',
                'master_url'     => 'https://localhost:8443',
                'labels'         => {
                    'component' => 'fabric8Console'
                }
            }
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end
    test 'with CONTAINER_NAME that does not match' do
      tag = 'var.log.containers.junk4_junk5_junk6-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed450.log'
      msg = {
        'CONTAINER_NAME' => 'does_not_match',
        'CONTAINER_ID_FULL' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459',
        'randomfield' => 'randomvalue'
      }
      VCR.use_cassette('kubernetes_docker_metadata_annotations') do
        filtered = emit_with_tag(tag, msg, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          use_journal true
        ')
        expected_kube_metadata = {
          'CONTAINER_NAME' => 'does_not_match',
          'CONTAINER_ID_FULL' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459',
          'randomfield' => 'randomvalue'
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end
    test 'with CONTAINER_NAME starts with k8s_ that does not match' do
      tag = 'var.log.containers.junk4_junk5_junk6-49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed450.log'
      msg = {
        'CONTAINER_NAME' => 'k8s_doesnotmatch',
        'CONTAINER_ID_FULL' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459',
        'randomfield' => 'randomvalue'
      }
      VCR.use_cassette('kubernetes_docker_metadata_annotations') do
        filtered = emit_with_tag(tag, msg, '
          kubernetes_url https://localhost:8443
          watch false
          cache_size 1
          use_journal true
        ')
        expected_kube_metadata = {
          'CONTAINER_NAME' => 'k8s_doesnotmatch',
          'CONTAINER_ID_FULL' => '49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459',
          'randomfield' => 'randomvalue'
        }
        assert_equal(expected_kube_metadata, filtered[0])
      end
    end
  end
end
