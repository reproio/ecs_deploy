# v1.0

## Release v1.0.0 - 2019/12/24

### New feature

* Add tasks to deploy the application faster
  https://github.com/reproio/ecs_deploy/pull/57

### Enhancement

* Add parameters `ecs_wait_until_services_stable_max_attempts` and `ecs_wait_until_services_stable_delay`
  https://github.com/reproio/ecs_deploy/pull/30
* Detect region automatically according to AWS SDK
  https://github.com/reproio/ecs_deploy/pull/31
* Support new features of ECS to add Fargate support
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
  https://github.com/reproio/ecs_deploy/pull/50
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

## Release v0.3.1 - 2017/04/08

### Bug fixes

* Fix block parameter name

## Release v0.3.0 - 2017/03/08

### Enhancement

* Support network_mode and placement_constraints

### Bug fixes

* Filter inactive services
  https://github.com/reproio/ecs_deploy/pull/19
* Wait 10 services at once
  https://github.com/reproio/ecs_deploy/pull/20
  https://github.com/reproio/ecs_deploy/pull/21
* Support ScheduledTask deployment
  https://github.com/reproio/ecs_deploy/pull/22

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
