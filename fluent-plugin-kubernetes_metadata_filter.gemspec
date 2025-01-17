# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name = 'fluent-plugin-kubernetes_metadata_filter'
  spec.version = '3.7.0'
  spec.authors = ['OpenShift Cluster Logging', 'Jimmi Dyson']
  spec.email = ['team-logging@redhat.com', 'jimmidyson@gmail.com']
  spec.description = 'Filter plugin to add Kubernetes metadata'
  spec.summary = 'Fluentd filter plugin to add Kubernetes metadata'
  spec.homepage = 'https://github.com/fabric8io/fluent-plugin-kubernetes_metadata_filter'
  spec.license = 'Apache-2.0'

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(['git', 'ls-files', '-z'], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) || f.start_with?('coverage/', 'test/', '.git', '.circleci', '.rubocop.yml', 'Gemfile')
    end
  end

  spec.required_ruby_version = '>= 2.7.0'

  spec.add_dependency 'fluentd', ['>= 0.14.0', '< 1.19']
  spec.add_dependency 'kubeclient', ['>= 4.0.0', '< 5.0.0']
  spec.add_dependency 'sin_lru_redux'
end
