# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ecs_deploy/version'

Gem::Specification.new do |spec|
  spec.name          = "ecs_deploy"
  spec.version       = EcsDeploy::VERSION
  spec.authors       = ["joker1007"]
  spec.email         = ["kakyoin.hierophant@gmail.com"]

  spec.summary       = %q{AWS ECS deploy helper}
  spec.description   = %q{AWS ECS deploy helper}
  spec.homepage      = "https://github.com/reproio/ecs_deploy"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "aws-sdk-autoscaling", "~> 1"
  spec.add_runtime_dependency "aws-sdk-cloudwatch", "~> 1"
  spec.add_runtime_dependency "aws-sdk-cloudwatchevents", "~> 1"
  spec.add_runtime_dependency "aws-sdk-ec2", "~> 1"
  spec.add_runtime_dependency "aws-sdk-ecs", "~> 1"
  spec.add_runtime_dependency "aws-sdk-sqs", "~> 1"
  spec.add_runtime_dependency "terminal-table"
  spec.add_runtime_dependency "paint"

  spec.add_development_dependency "bundler", ">= 1.11", "< 3"
  spec.add_development_dependency "rake", ">= 10.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
