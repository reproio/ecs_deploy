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

  spec.add_runtime_dependency "aws-sdk", "~> 2.4"
  spec.add_runtime_dependency "terminal-table"
  spec.add_runtime_dependency "paint"

  spec.add_development_dependency "bundler", "~> 1.11"
  spec.add_development_dependency "rake", "~> 10.0"
end
