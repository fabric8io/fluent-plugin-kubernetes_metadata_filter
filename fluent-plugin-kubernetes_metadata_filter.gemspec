# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |gem|
  gem.name          = 'fluent-plugin-kubernetes_metadata_filter'
  gem.version       = '3.7.0'
  gem.authors       = ['OpenShift Cluster Logging','Jimmi Dyson']
  gem.email         = ['team-logging@redhat.com','jimmidyson@gmail.com']
  gem.description   = 'Filter plugin to add Kubernetes metadata'
  gem.summary       = 'Fluentd filter plugin to add Kubernetes metadata'
  gem.homepage      = 'https://github.com/fabric8io/fluent-plugin-kubernetes_metadata_filter'
  gem.license       = 'Apache-2.0'

  gem.files         = `git ls-files`.split($/)

  gem.required_ruby_version = '>= 2.7.0'

  gem.add_runtime_dependency 'fluentd', ['>= 0.14.0', '< 1.19']
  gem.add_runtime_dependency 'kubeclient', ['>= 4.0.0', '< 5.0.0']
  gem.add_runtime_dependency 'sin_lru_redux'

  gem.add_development_dependency 'bump'
  gem.add_development_dependency 'bundler', '~> 2.0'
  gem.add_development_dependency 'copyright-header'
  gem.add_development_dependency 'minitest', '~> 4.0'
  gem.add_development_dependency 'rake'
  gem.add_development_dependency 'test-unit', '~> 3.5.5'
  gem.add_development_dependency 'test-unit-rr', '~> 1.0.3'
  gem.add_development_dependency 'vcr'
  gem.add_development_dependency 'webmock'
  gem.add_development_dependency 'yajl-ruby'
end
