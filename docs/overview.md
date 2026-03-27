# Project Overview: ecs_deploy

## Purpose

`ecs_deploy` is a Ruby gem that automates deployment to AWS ECS (Elastic Container Service). It provides two main capabilities:

1. **Capistrano integration** — A set of Capistrano tasks for registering ECS task definitions, deploying/rolling back ECS services, and deploying CloudWatch-based scheduled tasks. It abstracts away the complexity of interacting with the AWS ECS and CloudWatch Events APIs during a standard Capistrano-based deployment workflow.

2. **ECS Auto Scaler** — A standalone long-running daemon (`exe/ecs_auto_scaler`) that monitors CloudWatch alarms and automatically scales ECS services and their underlying EC2 capacity (via Auto Scaling Groups or Spot Fleet Requests). It also handles spot instance interruption warnings by draining affected instances before termination.

The gem targets Ruby-based infrastructure teams running containerized workloads on ECS with EC2 launch type, especially those already using Capistrano for deployment orchestration.

## Directory Structure

```
ecs_deploy/
├── bin/
│   ├── console          # IRB console with gem loaded
│   └── setup            # Dev setup script
├── exe/
│   └── ecs_auto_scaler  # CLI entry point for the auto-scaler daemon
├── lib/
│   └── ecs_deploy/
│       ├── auto_scaler/
│       │   ├── auto_scaling_group_config.rb   # ASG capacity management
│       │   ├── cluster_resource_manager.rb    # Thread-safe capacity tracking
│       │   ├── config_base.rb                 # Shared config base class
│       │   ├── instance_drainer.rb            # Spot interruption handling via SQS
│       │   ├── service_config.rb              # Per-service scaling logic
│       │   ├── spot_fleet_request_config.rb   # Spot Fleet capacity management
│       │   └── trigger_config.rb              # CloudWatch alarm trigger
│       ├── auto_scaler.rb                     # Main auto-scaler loop
│       ├── capistrano.rb                      # Capistrano task definitions
│       ├── configuration.rb                   # Global gem configuration
│       ├── instance_fluctuation_manager.rb    # Pre/post deploy scaling helper
│       ├── scheduled_task.rb                  # CloudWatch Events scheduled tasks
│       ├── service.rb                         # ECS service create/update/delete
│       ├── task_definition.rb                 # ECS task definition registration
│       ├── version.rb
│       └── ecs_deploy.rb                      # Entry point, logger, config
├── spec/
│   ├── ecs_deploy/
│   │   ├── auto_scaler/
│   │   │   ├── auto_scaling_group_config_spec.rb
│   │   │   ├── cluster_resource_manager_spec.rb
│   │   │   ├── instance_drainer_spec.rb
│   │   │   └── service_config_spec.rb
│   │   ├── auto_scaler_spec.rb
│   │   └── instance_fluctuation_manager_spec.rb
│   ├── fixtures/files/
│   │   ├── ecs_auto_scaler_config_in_new_format.yaml
│   │   └── ecs_auto_scaler_config_in_old_format.yaml
│   └── spec_helper.rb
├── .github/workflows/
│   └── test.yml          # CI: RSpec across Ruby 2.5–3.2
├── CHANGELOG.md
├── Gemfile
├── Rakefile
├── README.md
├── ecs_deploy.gemspec
└── renovate.json
```

## Tech Stack

| Category        | Technology                              |
|-----------------|-----------------------------------------|
| Language        | Ruby (2.5–3.2)                          |
| Package format  | RubyGems (`.gemspec`)                   |
| Deployment hook | Capistrano                              |
| Cloud provider  | AWS                                     |
| AWS services    | ECS, EC2, Auto Scaling, Spot Fleet, CloudWatch, CloudWatch Events, SQS |
| AWS SDK         | aws-sdk-* (~> 1, individual service gems) |
| Testing         | RSpec 3                                 |
| CI              | GitHub Actions                          |
| Dependency mgmt | Renovate (automated updates)            |
| Output styling  | terminal-table, paint                   |

## Key Files

| File | Role |
|------|------|
| `lib/ecs_deploy/ecs_deploy.rb` | Gem entry point; sets up logger and configuration |
| `lib/ecs_deploy/configuration.rb` | Global configuration struct (timeouts, credentials, retry params) |
| `lib/ecs_deploy/capistrano.rb` | Capistrano task definitions for deploy/rollback/scaling |
| `lib/ecs_deploy/task_definition.rb` | ECS task definition registration/deregistration |
| `lib/ecs_deploy/service.rb` | ECS service create/update/delete with stability polling |
| `lib/ecs_deploy/scheduled_task.rb` | CloudWatch Events scheduled task management |
| `lib/ecs_deploy/auto_scaler.rb` | Auto-scaler daemon main loop (polling, signals, threading) |
| `lib/ecs_deploy/auto_scaler/service_config.rb` | Per-service scale-up/down logic, cooldowns, scheduled min tasks |
| `lib/ecs_deploy/auto_scaler/auto_scaling_group_config.rb` | ASG desired capacity calculation and instance deregistration |
| `lib/ecs_deploy/auto_scaler/cluster_resource_manager.rb` | Thread-safe ECS cluster capacity tracking |
| `lib/ecs_deploy/auto_scaler/instance_drainer.rb` | Spot interruption SQS polling; drain/detach instances |
| `exe/ecs_auto_scaler` | CLI binary that starts the auto-scaler daemon |

## Dependencies

### Runtime

| Gem | Purpose |
|-----|---------|
| `aws-sdk-autoscaling (~> 1)` | Auto Scaling Group management |
| `aws-sdk-cloudwatch (~> 1)` | CloudWatch alarm queries |
| `aws-sdk-cloudwatchevents (~> 1)` | Scheduled task (CloudWatch Events) management |
| `aws-sdk-ec2 (~> 1)` | EC2 instance termination and info |
| `aws-sdk-ecs (~> 1)` | Core ECS API (services, tasks, clusters) |
| `aws-sdk-sqs (~> 1)` | SQS polling for spot interruption notices |
| `terminal-table` | Tabular output in CLI |
| `paint` | Colored terminal output |

### Development

| Gem | Purpose |
|-----|---------|
| `bundler (>= 1.11, < 3)` | Dependency management |
| `rake` | Task runner (default: `rspec`) |
| `rspec (~> 3.0)` | Test framework |
| `rexml` | Required by AWS SDK in Ruby 3+ |

## Setup & Usage

### Installation

Add to your application's `Gemfile`:

```ruby
gem 'ecs_deploy'
```

### Capistrano Integration

In `Capfile`:

```ruby
require 'ecs_deploy/capistrano'
```

Available tasks:

| Task | Description |
|------|-------------|
| `ecs:register_task_definition` | Register ECS task definitions |
| `ecs:deploy_scheduled_task` | Deploy CloudWatch scheduled tasks |
| `ecs:deploy` | Create or update ECS services |
| `ecs:rollback` | Rollback to the previous task definition |
| `ecs:increase_instances_to_max_size` | Scale up ECS instances before deploy |
| `ecs:terminate_redundant_instances` | Scale down ECS instances after deploy |

### Auto Scaler

Run as a daemon:

```bash
bundle exec ecs_auto_scaler /path/to/config.yaml
```

The auto-scaler reads a YAML configuration file defining services, triggers (CloudWatch alarms), and backing capacity (ASG or Spot Fleet). It polls every 30 seconds by default and responds to OS signals:

| Signal | Effect |
|--------|--------|
| `TERM` / `INT` | Graceful shutdown |
| `CONT` | Resume after pause |
| `TSTP` | Pause draining only |
