# frozen_string_literal: true

require 'bundler/setup'
require 'bundler/gem_tasks'
require 'rake/testtask'
require 'bump/tasks'
require 'rubocop/rake_task'

task test: [:base_test]
task default: [:test, :build, :rubocop]

RuboCop::RakeTask.new

desc 'Run test_unit based test'
Rake::TestTask.new(:base_test) do |task|
  # To run test for only one file (or file path pattern)
  #  $ bundle exec rake base_test TEST=test/test_specified_path.rb
  #  $ bundle exec rake base_test TEST=test/test_*.rb
  task.libs << 'test'
  task.test_files = Dir['test/**/test_*.rb'].sort
  task.warning = false
end

desc 'Add copyright headers'
task :headers do
  require 'rubygems'
  require 'copyright_header'

  args = {
    license: 'Apache-2.0',
    copyright_software: 'Fluentd Kubernetes Metadata Filter Plugin',
    copyright_software_description: 'Enrich Fluentd events with Kubernetes metadata',
    copyright_holders: ['Red Hat, Inc.'],
    copyright_years: ['2015-2021'],
    add_path: 'lib:test',
    output_dir: '.'
  }

  command_line = CopyrightHeader::CommandLine.new(args)
  command_line.execute
end
