require 'aws-sdk-cloudwatchevents'
require 'timeout'

module EcsDeploy
  class ScheduledTask
    class PutTargetsFailure < StandardError; end

    attr_reader :cluster, :region, :schedule_rule_name

    def initialize(cluster:, rule_name:, schedule_expression:, task_definition_name:, role_arn:, region: nil, **options)
      @cluster = cluster
      @rule_name = rule_name
      @schedule_expression = schedule_expression
      @task_definition_name = task_definition_name
      @role_arn = role_arn

      @options = options.dup
      @options[:enabled] = @options.fetch(:enabled, true)
      @options[:target_id] ||= task_definition_name
      @options[:task_count] ||= 1
      @options[:launch_type] ||= "EC2"

      region ||= EcsDeploy.config.default_region
      params ||= EcsDeploy.config.ecs_client_params

      @client = region ? Aws::ECS::Client.new(params.merge(region: region)) : Aws::ECS::Client.new(params)
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
      suffix = @options[:revision] ? ":#{@options[:revision]}" : ""
      name = "#{@task_definition_name}#{suffix}"
      @client.describe_task_definition(task_definition: name).task_definition.task_definition_arn
    end

    def put_rule
      res = @cloud_watch_events.put_rule(
        name: @rule_name,
        schedule_expression: @schedule_expression,
        state: @options[:enabled] ? "ENABLED" : "DISABLED",
        description: @options[:description],
      )
      EcsDeploy.logger.info "created cloudwatch event rule [#{res.rule_arn}] [#{@region}] [#{Paint['OK', :green]}]"
    end

    def put_targets
      target = {
        id: @options[:target_id],
        arn: cluster_arn,
        role_arn: @role_arn,
        ecs_parameters: @options.except(:enabled, :description, :target_id, :revision, :container_overrides).merge(
          task_definition_arn: task_definition_arn,
        ),
      }
      target[:ecs_parameters].compact!

      if @options[:container_overrides]
        target.merge!(input: { containerOverrides: @options[:container_overrides] }.to_json)
      end

      res = @cloud_watch_events.put_targets(
        rule: @rule_name,
        targets: [target]
      )
      if res.failed_entry_count.zero?
        EcsDeploy.logger.info "created cloudwatch event target [#{@options[:target_id]}] [#{@region}] [#{Paint['OK', :green]}]"
      else
        res.failed_entries.each do |entry|
          EcsDeploy.logger.error "failed to create cloudwatch event target [#{@region}] target_id=#{entry.target_id} error_code=#{entry.error_code} error_message=#{entry.error_message}"
        end
        raise PutTargetsFailure
      end
    end
  end
end
