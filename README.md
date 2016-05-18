# EcsDeploy

Helper script for deployment to Amazon ECS.

This gem is experimental.

Main purpose is combination with capistrano API.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ecs_deploy', github: "joker1007/ecs_deploy"
```

And then execute:

    $ bundle

## Usage

Use by Capistrano.

```ruby
# Capfile
require 'ecs_deploy/capistrano'

# deploy.rb
set :ecs_default_cluster, "ecs-cluster-name"
set :ecs_access_key_id, "dummy" # optional, if nil, use environment variable
set :ecs_secret_access_key, "dummy" # optional, if nil, use environment variable
set :ecs_region, %w(ap-northeast-1) # optional, if nil, use environment variable
set :ecs_service_role, "customEcsServiceRole" # default: ecsServiceRole
set :ecs_deploy_wait_timeout, 600 # default: 300

set :ecs_tasks, [
  {
    name: "myapp-#{fetch(:rails_env)}",
    container_definitions: [
      {
        name: "myapp",
        image: "#{fetch(:docker_registry_host_with_port)}/myapp:#{fetch(:sha1)}",
        cpu: 1024,
        memory: 512,
        port_mappings: [],
        essential: true,
        environment: [
          {name: "RAILS_ENV", value: fetch(:rails_env)},
        ],
        mount_points: [
          {
            source_volume: "sockets_path",
            container_path: "/app/tmp/sockets",
            read_only: false,
          },
        ],
        volumes_from: [],
        log_configuration: {
          log_driver: "fluentd",
          options: {
            "tag" => "docker.#{fetch(:rails_env)}.#{name}.{{.ID}}",
          },
        },
      },
      {
        name: "nginx",
        image: "#{fetch(:docker_registry_host_with_port)}/my-nginx",
        cpu: cpu,
        memory: memory,
        links: [],
        port_mappings: [
          {container_port: 443, host_port: 443, protocol: "tcp"},
        ],
        essential: true,
        environment: {},
        mount_points: [],
        volumes_from: [
          {source_container: "myapp-#{fetch(:rails_env)}", read_only: false},
        ],
        log_configuration: {
          log_driver: "fluentd",
          options: {
            "tag" => "docker.#{fetch(:rails_env)}.#{name}.{{.ID}}",
          },
        },
      }
    ],
    volumes: [{name: "sockets_path", host: {}}],
    executions: [ # execution task on deploy timing
      {container_overrides: [{name: "myapp", command: ["db_migrate"]}]},
    ]
  },
]

set :ecs_services, [
  {
    name: "myapp-#{fetch(:rails_env)}",
    elb_name: "service-elb-name",
    elb_service_port: 443,
    elb_healthcheck_port: 443,
    elb_container_name: "nginx",
    desired_count: 1,
    deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 50},
  },
]
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/joker1007/ecs_deploy.

