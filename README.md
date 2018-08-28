# EcsDeploy

Helper script for deployment to Amazon ECS.

This gem is experimental.

Main purpose is combination with capistrano API.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ecs_deploy', github: "reproio/ecs_deploy"
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
set :ecs_region, %w(ap-northeast-1) # optional, if nil, use environment variable
set :ecs_service_role, "customEcsServiceRole" # default: ecsServiceRole
set :ecs_deploy_wait_timeout, 600 # default: 300
set :ecs_wait_until_services_stable_max_attempts, 40 # optional
set :ecs_wait_until_services_stable_delay, 15 # optional

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
        cpu: 256,
        memory: 256,
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
  },
]

set :ecs_scheduled_tasks, [
  {
    cluster: "default", # Unless this key, use fetch(:ecs_default_cluster)
    rule_name: "schedule_name",
    schedule_expression: "cron(0 12 * * ? *"),
    description: "schedule_description", # Optional
    target_id: "task_name", # Unless this key, use task_definition_name
    task_definition_name: "myapp-#{fetch(:rails_env)}",
    task_count: 2, # Default 1
    revision: 12, # Optional
    role_arn: "TaskRoleArn", # Optional
    container_overrides: [ # Optional
      name: "myapp-main",
      command: ["ls"],
    ]
  }
]

set :ecs_services, [
  {
    name: "myapp-#{fetch(:rails_env)}",
    load_balancers: [
      {
        load_balancer_name: "service-elb-name",
        container_port: 443,
        container_name: "nginx",
      },
      {
        target_group_arn: "alb_target_group_arn",
        container_port: 443,
        container_name: "nginx",
      }
    ],
    desired_count: 1,
    deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 50},
  },
]
```

```sh
cap <stage> ecs:register_task_definition # register ecs_tasks as TaskDefinition
cap <stage> ecs:deploy_scheduled_task # register ecs_scheduled_tasks to CloudWatchEvent
cap <stage> ecs:deploy # create or update Service by ecs_services info

cap <stage> ecs:rollback # deregister current task definition and update Service by previous revision of current task definition
```

### Rollback example

| sequence | taskdef  | service       | desc    |
| -------- | -------- | ------------- | ------  |
| 1        | myapp:12 | myapp-service |         |
| 2        | myapp:13 | myapp-service |         |
| 3        | myapp:14 | myapp-service | current |

After rollback

| sequence | taskdef  | service       | desc       |
| -------- | -------- | ------------- | ------     |
| 1        | myapp:12 | myapp-service |            |
| 2        | myapp:13 | myapp-service |            |
| 3        | myapp:14 | myapp-service | deregister |
| 4        | myapp:13 | myapp-service | current    |

And rollback again

| sequence | taskdef  | service       | desc       |
| -------- | -------- | ------------- | ------     |
| 1        | myapp:12 | myapp-service |            |
| 2        | myapp:13 | myapp-service | previous   |
| 3        | myapp:14 | myapp-service | deregister |
| 4        | myapp:13 | myapp-service | deregister |
| 5        | myapp:12 | myapp-service | current    |

And deploy new version

| sequence | taskdef  | service       | desc       |
| -------- | -------- | ------------- | ------     |
| 1        | myapp:12 | myapp-service |            |
| 2        | myapp:13 | myapp-service |            |
| 3        | myapp:14 | myapp-service | deregister |
| 4        | myapp:13 | myapp-service | deregister |
| 5        | myapp:12 | myapp-service |            |
| 6        | myapp:15 | myapp-service | current    |

And rollback

| sequence | taskdef  | service       | desc       |
| -------- | -------- | ------------- | ------     |
| 1        | myapp:12 | myapp-service |            |
| 2        | myapp:13 | myapp-service |            |
| 3        | myapp:14 | myapp-service | deregister |
| 4        | myapp:13 | myapp-service | deregister |
| 5        | myapp:12 | myapp-service |            |
| 6        | myapp:15 | myapp-service | deregister |
| 7        | myapp:12 | myapp-service | current    |

## Autoscaler

Write config file (YAML format).

```yaml
# ポーリング時にupscale_triggersに指定した状態のalarmがあればstep分serviceとinstanceを増やす (max_task_countまで)
# ポーリング時にdownscale_triggersに指定した状態のalarmがあればstep分serviceとinstanceを減らす (min_task_countまで)
# max_task_countは段階的にリミットを設けられるようにする
# 一回リミットに到達するとcooldown_for_reach_maxを越えても状態が継続したら再開するようにする

polling_interval: 60

auto_scaling_groups:
  - name: ecs-cluster-nodes
    region: ap-northeast-1
    buffer: 1 # タスク数に対する余剰のインスタンス数

services:
  - name: repro-api-production
    cluster: ecs-cluster
    region: ap-northeast-1
    auto_scaling_group_name: ecs-cluster-nodes
    step: 1
    idle_time: 240
    max_task_count: [10, 25]
    scheduled_min_task_count:
      - {from: "1:45", to: "4:30", count: 8}
    cooldown_time_for_reach_max: 600
    min_task_count: 0
    upscale_triggers:
      - alarm_name: "ECS [repro-api-production] CPUUtilization"
        state: ALARM
      - alarm_name: "ELB repro-api-a HTTPCode_Backend_5XX"
        state: ALARM
        step: 2
    downscale_triggers:
      - alarm_name: "ECS [repro-api-production] CPUUtilization (low)"
        state: OK
```

```sh
ecs_auto_scaler <config yaml>
```

I recommends deploy `ecs_auto_scaler` on ECS too.

### IAM policy for autoscaler

The following policy is required for the preceding configuration:

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "cloudwatch:DescribeAlarms",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances",
        "ecs:DescribeContainerInstances",
        "ecs:DescribeServices",
        "ecs:ListContainerInstances",
        "ecs:UpdateService"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DetachInstances",
        "autoscaling:UpdateAutoScalingGroup"
      ],
      "Resource": [
        "arn:aws:autoscaling:ap-northeast-1:<account-id>:autoScalingGroup:<group-id>:autoScalingGroupName/ecs-cluster-nodes"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DeregisterContainerInstance"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:cluster/ecs-cluster"
      ]
    }
  ]
}
```


## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/reproio/ecs_deploy.
