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
Rake::TestTask.new(:base_test) do |t|
  # To run test for only one file (or file path pattern)
  #  $ bundle exec rake base_test TEST=test/test_specified_path.rb
  #  $ bundle exec rake base_test TEST=test/test_*.rb
  t.libs << 'test'
  t.test_files = Dir['test/**/test_*.rb'].sort
  t.warning = false
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

desc 'Profile the tests while running them'
namespace :profile do
task :test do
  require "ruby-prof"
  require "fileutils"
  RubyProf.start
  `ruby -Itest test/**/*_test.rb`
  results = RubyProf.stop
  # Print a flat profile to text
  File.open "./profiler-graph.html", 'w' do |file|
    RubyProf::GraphHtmlPrinter.new(results).print(file)
  end
  File.open "./profiler-stack.html", 'w' do |file|
    printer = RubyProf::CallStackPrinter.new(results)
    printer.print(file)
  end
end
end

desc 'Benchmarks the cache strategy (via tests)'
namespace :benchmark do
  task :cache do
    require "benchmark"
    Benchmark.bm do|x|
      n = 100
      x.report("unique caching:")  {
        n.times do
          `ruby -Itest test/**/test_cache_strategy.rb`
        end
      }
      x.report("simple caching:") { 
        n.times do
          `ruby -Itest test/**/test_cache_strategy_simple.rb`
        end
      }
    end
  end
end