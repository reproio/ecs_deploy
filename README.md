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
    schedule_expression: "cron(0 12 * * ? *)",
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

The autoscaler of `ecs_deploy` supports auto scaling of ECS services and clusters.

### Prerequisits

* You use a ECS cluster whose instances belong to either an auto scaling group or a spot fleet request
* You have CloudWatch alarms and you want to scale services when their state changes

### How to use autoscaler

First, write a configuration file (YAML format) like below:

```yaml
# ポーリング時にupscale_triggersに指定した状態のalarmがあればstep分serviceとinstanceを増やす (max_task_countまで)
# ポーリング時にdownscale_triggersに指定した状態のalarmがあればstep分serviceとinstanceを減らす (min_task_countまで)
# max_task_countは段階的にリミットを設けられるようにする
# 一回リミットに到達するとcooldown_for_reach_maxを越えても状態が継続したら再開するようにする

polling_interval: 60

auto_scaling_groups:
  - name: ecs-cluster-nodes
    region: ap-northeast-1
    cluster: ecs-cluster
    # autoscaler will set the capacity to (buffer + desired_tasks * required_capacity).
    # Adjust this value if it takes much time to prepare ECS instances and launch new tasks.
    buffer: 1
    disable_draining: false # cf. spot_instance_intrp_warns_queue_urls
    services:
      - name: repro-api-production
        step: 1
        idle_time: 240
        max_task_count: [10, 25]
        scheduled_min_task_count:
          - {from: "1:45", to: "4:30", count: 8}
        cooldown_time_for_reach_max: 600
        min_task_count: 0
        # Required capacity per task (default: 1)
        # You should specify "binpack" as task placement strategy if the value is less than 1 and you use an auto scaling group.
        required_capacity: 0.5
        upscale_triggers:
          - alarm_name: "ECS [repro-api-production] CPUUtilization"
            state: ALARM
          - alarm_name: "ELB repro-api-a HTTPCode_Backend_5XX"
            state: ALARM
            step: 2
        downscale_triggers:
          - alarm_name: "ECS [repro-api-production] CPUUtilization (low)"
            state: OK

spot_fleet_requests:
  - id: sfr-354de735-2c17-4565-88c9-10ada5b957e5
    region: ap-northeast-1
    cluster: ecs-cluster-for-worker
    buffer: 1
    disable_draining: false # cf. spot_instance_intrp_warns_queue_urls
    services:
      - name: repro-worker-production
        step: 1
        idle_time: 240
        cooldown_time_for_reach_max: 600
        min_task_count: 0
        # Required capacity per task (default: 1)
        # The capacity assumes that WeightedCapacity is equal to the number of vCPUs.
        required_capacity: 2
        upscale_triggers:
          - alarm_name: "ECS [repro-worker-production] CPUUtilization"
            state: ALARM
        downscale_triggers:
          - alarm_name: "ECS [repro-worker-production] CPUUtilization (low)"
            state: OK
          - alarm_name: "Aurora DMLLatency is high"
            state: ALARM
            prioritized_over_upscale_triggers: true

# When you use spot instances, instances that receive interruption warnings should be drained.
# If you set URLs of SQS queues for spot instance interruption warnings to `spot_instance_intrp_warns_queue_urls`,
# autoscaler drains instances to interrupt and detaches the instances from the auto scaling groups with
# should_decrement_desired_capacity false.
# If you set ECS_ENABLE_SPOT_INSTANCE_DRAINING to true, we recommend that you opt out of the draining feature
# by setting disable_draining to true in the configurations of auto scaling groups and spot fleet requests.
# Otherwise, instances don't seem to be drained on rare occasions.
# Even if you opt out of the feature, you still have the advantage of setting `spot_instance_intrp_warns_queue_urls`
# because instances to interrupt are replaced with new instances as soon as possible.
spot_instance_intrp_warns_queue_urls:
  - https://sqs.ap-northeast-1.amazonaws.com/<account-id>/spot-instance-intrp-warns
```

Then, execute the following command:

```sh
ecs_auto_scaler <config yaml>
```

I recommends deploy `ecs_auto_scaler` on ECS too.

### Signals

 Signal    | Description
-----------|------------------------------------------------------------
 TERM, INT | Shutdown gracefully
 CONT      | Resume auto scaling
 TSTP      | Pause auto scaling (Run only container instance draining)

### IAM policy for autoscaler

The following permissions are required for the preceding configuration of "repro-api-production" service:

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
        "ecs:ListTasks"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:UpdateService"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:service/ecs-cluster/repro-api-production"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeTasks"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:task/ecs-cluster/*"
      ]
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
        "ecs:DescribeContainerInstances"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:container-instance/ecs-cluster/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DeregisterContainerInstance",
        "ecs:ListContainerInstances"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:cluster/ecs-cluster"
      ]
    }
  ]
}
```

If you use spot instances, additional permissions are required like below:

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ecs:UpdateContainerInstancesState",
      "Resource": "arn:aws:ecs:ap-northeast-1:<account-id>:container-instance/ecs-cluster/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:DeleteMessage",
        "sqs:DeleteMessageBatch",
        "sqs:ReceiveMessage"
      ],
      "Resource": "arn:aws:sqs:ap-northeast-1:<account-id>:spot-instance-intrp-warns"
    }
  ]
}
```

The following permissions are required for the preceding configuration of "repro-worker-production" service:

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:DeleteMessage",
        "sqs:DeleteMessageBatch",
        "sqs:ReceiveMessage"
      ],
      "Resource": "arn:aws:sqs:ap-northeast-1:<account-id>:spot-instance-intrp-warns"
    },
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:DescribeAlarms",
        "ec2:DescribeInstances",
        "ec2:DescribeSpotFleetInstances",
        "ec2:DescribeSpotFleetRequests",
        "ec2:ModifySpotFleetRequest",
        "ec2:TerminateInstances",
        "ecs:ListTasks"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:UpdateService"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:service/ecs-cluster-for-worker/repro-worker-production"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeTasks"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:task/ecs-cluster-for-worker/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeContainerInstances",
        "ecs:UpdateContainerInstancesState"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:container-instance/ecs-cluster-for-worker/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:ListContainerInstances"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:cluster/ecs-cluster-for-worker"
      ]
    }
  ]
}
```

### How to deploy faster with Auto Scaling Group

Add following configuration to your deploy.rb and hooks if you need.

```ruby
# deploy.rb
set :ecs_instance_fluctuation_manager_configs, [
  {
    region: "ap-northeast-1",
    cluster: "CLUSTER_NAME",
    auto_scaling_group_name: "AUTO_SCALING_GROUP_NAME",
    desired_capacity: 20, # original capacity of auto scaling group
  }
]
```

This configuration enables tasks `ecs:increase_instances_to_max_size` and `ecs:terminate_redundant_instances`.
If this configuration is not set, the above tasks do nothing.
The task `ecs:increase_instances_to_max_size` will increase ECS instances.
The task `ecs:terminate_redundant_instances` will decrease ECS instances considering AZ balance.

Hook configuration example:

```ruby
after "deploy:updating", "ecs:increase_instances_to_max_size"
after "deploy:finished", "ecs:terminate_redundant_instances"
after "deploy:failed", "ecs:terminate_redundant_instances"
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/reproio/ecs_deploy.
