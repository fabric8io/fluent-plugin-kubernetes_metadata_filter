# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |gem|
  gem.name          = 'fluent-plugin-kubernetes_metadata_filter'
  gem.version       = '2.7.2'
  gem.authors       = ['Jimmi Dyson']
  gem.email         = ['jimmidyson@gmail.com']
  gem.description   = 'Filter plugin to add Kubernetes metadata'
  gem.summary       = 'Fluentd filter plugin to add Kubernetes metadata'
  gem.homepage      = 'https://github.com/fabric8io/fluent-plugin-kubernetes_metadata_filter'
  gem.license       = 'Apache-2.0'

  gem.files         = `git ls-files`.split($/)

  gem.required_ruby_version = '>= 2.5.0'

  gem.add_runtime_dependency 'fluentd', ['>= 0.14.0', '< 1.15']
  gem.add_runtime_dependency 'kubeclient', '< 5'
  gem.add_runtime_dependency 'lru_redux'

  gem.add_development_dependency 'bump'
  gem.add_development_dependency 'bundler', '~> 2.0'
  gem.add_development_dependency 'copyright-header'
  gem.add_development_dependency 'minitest', '~> 4.0'
  gem.add_development_dependency 'rake'
  gem.add_development_dependency 'test-unit', '~> 3.0.2'
  gem.add_development_dependency 'test-unit-rr', '~> 1.0.3'
  gem.add_development_dependency 'vcr'
  gem.add_development_dependency 'webmock'
  gem.add_development_dependency 'yajl-ruby'
end
