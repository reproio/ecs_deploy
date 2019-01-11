require 'aws-sdk-cloudwatchevents'
require 'timeout'

module EcsDeploy
  class ScheduledTask
    class PutTargetsFailure < StandardError; end

    attr_reader :cluster, :region, :schedule_rule_name

    def initialize(
      cluster:, rule_name:, schedule_expression:, enabled: true, description: nil, target_id: nil,
      task_definition_name:, revision: nil, task_count: nil, role_arn:, network_configuration: nil, launch_type: nil, platform_version: nil, group: nil,
      region: nil, container_overrides: nil
    )
      @cluster = cluster
      @rule_name = rule_name
      @schedule_expression = schedule_expression
      @enabled = enabled
      @description = description
      @target_id = target_id || task_definition_name
      @task_definition_name = task_definition_name
      @task_count = task_count || 1
      @revision = revision
      @role_arn = role_arn
      @network_configuration = network_configuration
      @launch_type = launch_type || "EC2"
      @platform_version = platform_version
      @group = group
      region ||= EcsDeploy.config.default_region
      @container_overrides = container_overrides

      @client = region ? Aws::ECS::Client.new(region: region) : Aws::ECS::Client.new
      @region = @client.config.region
      @cloud_watch_events = Aws::CloudWatchEvents::Client.new(region: @region)
    end

    def deploy
      put_rule
      put_targets
    end

    private

    def cluster_arn
      cl = @client.describe_clusters(clusters: [@cluster]).clusters[0]
      if cl
        cl.cluster_arn
      end
    end

    def task_definition_arn
      suffix = @revision ? ":#{@revision}" : ""
      name = "#{@task_definition_name}#{suffix}"
      @client.describe_task_definition(task_definition: name).task_definition.task_definition_arn
    end

    def put_rule
      res = @cloud_watch_events.put_rule(
        name: @rule_name,
        schedule_expression: @schedule_expression,
        state: @enabled ? "ENABLED" : "DISABLED",
        description: @description,
      )
      EcsDeploy.logger.info "create cloudwatch event rule [#{res.rule_arn}] [#{@region}] [#{Paint['OK', :green]}]"
    end

    def put_targets
      target = {
        id: @target_id,
        arn: cluster_arn,
        role_arn: @role_arn,
        ecs_parameters: {
          task_definition_arn: task_definition_arn,
          task_count: @task_count,
          network_configuration: @network_configuration,
          launch_type: @launch_type,
          platform_version: @platform_version,
          group: @group,
        },
      }
      target[:ecs_parameters].compact!

      if @container_overrides
        target.merge!(input: { containerOverrides: @container_overrides }.to_json)
      end

      res = @cloud_watch_events.put_targets(
        rule: @rule_name,
        targets: [target]
      )
      if res.failed_entry_count.zero?
        EcsDeploy.logger.info "create cloudwatch event target [#{@target_id}] [#{@region}] [#{Paint['OK', :green]}]"
      else
        res.failed_entries.each do |entry|
          EcsDeploy.logger.error "failed to create cloudwatch event target [#{@region}] target_id=#{entry.target_id} error_code=#{entry.error_code} error_message=#{entry.error_message}"
        end
        raise PutTargetsFailure
      end
    end
  end
end
