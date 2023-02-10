# v1.0

## Release v1.0.4 - 2023/02/10

### Bug fixes

- Fix Aws::AutoScaling::Errors::ValidationError https://github.com/reproio/ecs_deploy/pull/85

- Fix Timeout::Error that occurs in trigger_capacity_update https://github.com/reproio/ecs_deploy/pull/80

- use force a new deployment, when switching from launch type to capacity provider strategy on an existing service https://github.com/reproio/ecs_deploy/pull/75

### Enhancement

- Run test with Ruby 3.2 https://github.com/reproio/ecs_deploy/pull/83

- Merge `propagate_tags` to service_options when updating service https://github.com/reproio/ecs_deploy/pull/82

- Show service event logs while waiting for services https://github.com/reproio/ecs_deploy/pull/81

- Stop supporting ruby 2.4 https://github.com/reproio/ecs_deploy/pull/79

- Display warning that desired count has reached max value https://github.com/reproio/ecs_deploy/pull/78

- Make draining feature opt-outable https://github.com/reproio/ecs_deploy/pull/77

- Add capacity_provider_strategy options to Service https://github.com/reproio/ecs_deploy/pull/74

## Release v1.0.3 - 2021/11/17

### Bug fixes
* Fix bug that `InstanceFluctuationManager#decrement` tries to detach instances whose status is 'DEREGISTERING'
  https://github.com/reproio/ecs_deploy/pull/72

### Enhancement
* Add a cluster name to deployment logs
  https://github.com/reproio/ecs_deploy/pull/71


## Release v1.0.2 - 2021/05/26

### Enhancement

* add option enable_execute_command to support ECS Exec
  https://github.com/reproio/ecs_deploy/pull/69

## Release v1.0.1 - 2021/05/19

### Enhancement

* retry register_task_definition by AWS SDK feature
  https://github.com/reproio/ecs_deploy/pull/67
* Support Ruby 3.0
  https://github.com/reproio/ecs_deploy/pull/66
* Wait until stop old tasks
  https://github.com/reproio/ecs_deploy/pull/65
* Add prioritized_over_upscale_triggers option to triggers
  https://github.com/reproio/ecs_deploy/pull/62
* Display only unstable services in EcsDeploy::Service#wait_all_running
  https://github.com/reproio/ecs_deploy/pull/61

## Release v1.0.0 - 2019/12/24

### New feature

* Add tasks to deploy the application faster
  https://github.com/reproio/ecs_deploy/pull/57

### Enhancement

* Add parameters `ecs_wait_until_services_stable_max_attempts` and `ecs_wait_until_services_stable_delay`
  https://github.com/reproio/ecs_deploy/pull/30
* Detect region automatically according to AWS SDK
  https://github.com/reproio/ecs_deploy/pull/31
* Support new features of ECS to support Fargate
  https://github.com/reproio/ecs_deploy/pull/32
* Ignore running tasks which don't belong to the ECS services on deregistering container instances
  https://github.com/reproio/ecs_deploy/pull/33
* Drop AWS SDK 2 support
  https://github.com/reproio/ecs_deploy/pull/34
* Support scheduling_strategy option
  https://github.com/reproio/ecs_deploy/pull/35
* Support execution_role_arn on task_definition
  https://github.com/reproio/ecs_deploy/pull/36
* Support spot fleet requests and container instance draining
  https://github.com/reproio/ecs_deploy/pull/40
* Add network_configuration paramters to ScheduledTask
  https://github.com/reproio/ecs_deploy/pull/46
* Support tagging ECS resources
  https://github.com/reproio/ecs_deploy/pull/48
  https://github.com/reproio/ecs_deploy/pull/49
* Wait for stopping tasks until tasks stop
  https://github.com/reproio/ecs_deploy/pull/50
* Improve performance when start tasks
  https://github.com/reproio/ecs_deploy/pull/53
* Improve stability of auto scaling groups managed by ecs_auto_scaler
  https://github.com/reproio/ecs_deploy/pull/55

### Bug fixes

* Fix infinite loop that occurs when there are more than 100 container instances
  https://github.com/reproio/ecs_deploy/pull/38
* Fix errors that occur on decreasing more than 20 container instances
  https://github.com/reproio/ecs_deploy/pull/39

# Ancient releases

## Release v0.3.2 - 2017/23/10

### Enhancement

* Remove execution feature
  https://github.com/reproio/ecs_deploy/pull/24
* Support container overrides in scheduled tasks
  https://github.com/reproio/ecs_deploy/pull/26

### Bug fixes

* Fix deployment errors that occur when `ecs_scheduled_tasks` is not set
  https://github.com/reproio/ecs_deploy/pull/27

## Release v0.3.1 - 2017/04/08

### Bug fixes

* Fix block parameter name

## Release v0.3.0 - 2017/03/08

### New feature

* Support ScheduledTask deployment
  https://github.com/reproio/ecs_deploy/pull/22

### Enhancement

* Support network_mode and placement_constraints
* Introduce `ecs_registered_tasks` capistrano variable
  https://github.com/reproio/ecs_deploy/pull/23

### Bug fixes

* Filter inactive services
  https://github.com/reproio/ecs_deploy/pull/19
* Wait 10 services at once
  https://github.com/reproio/ecs_deploy/pull/20
  https://github.com/reproio/ecs_deploy/pull/21

## Release v0.2.0 - 2016/31/10

### Enhancement

* Support task role arn
  https://github.com/reproio/ecs_deploy/pull/13
* Make the scale-in process safe
  https://github.com/reproio/ecs_deploy/pull/14
* Support ALB
  https://github.com/reproio/ecs_deploy/pull/15

## Release v0.1.2 - 2016/28/07

### Bug fixes

* Fix rollback bug
  https://github.com/reproio/ecs_deploy/pull/11

## Release v0.1.1 - 2016/03/07

### Bug fixes

* Add missing desired_count for backend services
  https://github.com/reproio/ecs_deploy/pull/9

## Release v0.1.0 - 2016/27/06

Initial release.
