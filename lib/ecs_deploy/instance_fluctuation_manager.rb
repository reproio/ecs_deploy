require "aws-sdk-autoscaling"
require "aws-sdk-ec2"
require "aws-sdk-ecs"

module EcsDeploy
  class InstanceFluctuationManager
    attr_reader :logger

    MAX_UPDATABLE_ECS_CONTAINER_COUNT = 10
    MAX_DETACHEABLE_EC2_INSTACE_COUNT = 20

    def initialize(region:, cluster:, auto_scaling_group_name:, desired_capacity:, logger:)
      @region = region
      @cluster = cluster
      @auto_scaling_group_name = auto_scaling_group_name
      @desired_capacity = desired_capacity
      @logger = logger
    end

    def increase
      asg = fetch_auto_scaling_group
      current_instance_ids = asg.instances.map(&:instance_id)

      @logger.info("Increase desired capacity of #{@auto_scaling_group_name}: #{asg.desired_capacity} => #{asg.max_size}")
      as_client.update_auto_scaling_group(auto_scaling_group_name: @auto_scaling_group_name, desired_capacity: asg.max_size)

      # Run in background because increasing instances may take time
      Thread.new do
        loop do
          cluster = ecs_client.describe_clusters(clusters: [@cluster]).clusters.first
          instance_count = cluster.registered_container_instances_count
          if instance_count == asg.max_size
            @logger.info("Succeeded in increasing instances!")
            @logger.info do
              asg = fetch_auto_scaling_group
              all_instance_ids = asg.instances.map(&:instance_id)
              "Newly added: #{all_instance_ids - current_instance_ids}"
            end
            break
          end
          @logger.info("Current registered instance count: #{instance_count}")
          sleep 5
        end
      end
    end

    def decrease
      asg = fetch_auto_scaling_group

      decrease_count = asg.desired_capacity - @desired_capacity
      if decrease_count <= 0
        @logger.info("The capacity is already #{asg.desired_capacity}")
        return
      end
      @logger.info("Decrease desired capacity of #{@auto_scaling_group_name}: #{asg.desired_capacity} => #{@desired_capacity}")

      container_instance_arns = ecs_client.list_container_instances(
        cluster: @cluster
      ).flat_map(&:container_instance_arns)
      @logger.info("Container instance ARNs: #{container_instance_arns.size}")
      container_instances = container_instance_arns.each_slice(100).flat_map do |arns|
        ecs_client.describe_container_instances(
          cluster: @cluster,
          container_instances: arns
        ).container_instances
      end
      @logger.info("Container instances: #{container_instances.size}")

      az_to_container_instances = container_instances.sort_by {|ci| - ci.running_tasks_count }.group_by do |ci|
        ci.attributes.find {|attribute| attribute.name == "ecs.availability-zone" }.value
      end
      if az_to_container_instances.empty?
        @logger.info("There are no instances to terminate.")
        return
      end

      target_container_instances = extract_target_container_instances(decrease_count, az_to_container_instances)

      threads = []
      all_running_task_arns = []
      target_container_instances.map(&:container_instance_arn).each_slice(MAX_UPDATABLE_ECS_CONTAINER_COUNT) do |arns|
        ecs_client.update_container_instances_state(
          cluster: @cluster,
          container_instances: arns,
          status: "DRAINING"
        )
        arns.each do |arn|
          threads << Thread.new(arn) do |a|
            all_running_task_arns.concat(stop_tasks(a))
          end
        end
      end

      threads.each(&:join)
      ecs_client.wait_until(:tasks_stopped, cluster: @cluster, tasks: all_running_task_arns) unless all_running_task_arns.empty?
      @logger.info("All running tasks are stopped")

      instance_ids = target_container_instances.map(&:ec2_instance_id)
      terminate_instances(instance_ids)
      @logger.info("Succeeded in decreasing instances!")
    end

    private

    def aws_params
      {
        access_key_id: EcsDeploy.config.access_key_id,
        secret_access_key: EcsDeploy.config.secret_access_key,
        region: @region,
        logger: @logger
      }.reject do |_key, value|
        value.nil?
      end
    end

    def as_client
      @as_client ||= Aws::AutoScaling::Client.new(aws_params)
    end

    def ec2_client
      @ec2_client ||= Aws::EC2::Client.new(aws_params)
    end

    def ecs_client
      @ecs_client ||= Aws::ECS::Client.new(aws_params)
    end

    def fetch_auto_scaling_group
      as_client.describe_auto_scaling_groups(auto_scaling_group_names: [@auto_scaling_group_name]).auto_scaling_groups.first
    end

    # Extract container instances to terminate considering AZ balance
    def extract_target_container_instances(decrease_count, az_to_container_instances)
      target_container_instances = []
      @logger.info do
        "AZ balance: #{az_to_container_instances.sort_by {|az, _| az }.map {|az, instances| [az, instances.size] }.to_h}"
      end
      decrease_count.times do
        @logger.debug do
          "AZ balance: #{az_to_container_instances.sort_by {|az, _| az }.map {|az, instances| [az, instances.size] }.to_h}"
        end
        az = az_to_container_instances.max_by {|_az, instances| instances.size }.first
        az_to_container_instances[az].size.times do
          target_container_instance_candidate = az_to_container_instances[az].pop
          if can_terminate?(target_container_instance_candidate)
            target_container_instances << target_container_instance_candidate
            break
          else
            @logger.info("Cannot terminate container instance: #{target_container_instance_candidate}")
            az_to_container_instances[az].unshift(target_container_instance_candidate)
          end
        end
      end
      if target_container_instances.size != decrease_count
        @logger.info("target_container_instances.size != decrease_count #{target_container_instances.size} != #{decrease_count}")
      end
      @logger.info do
        "AZ balance: #{az_to_container_instances.sort_by {|az, _| az }.map {|az, instances| [az, instances.size] }.to_h}"
      end

      target_container_instances
    end

    def can_terminate?(container_instance)
      task_arns = ecs_client.list_tasks(cluster: @cluster, container_instance: container_instance.container_instance_arn).flat_map(&:task_arns)
      if task_arns.empty?
        @logger.info("#{__method__}: task_arns are empty")
        return true
      end

      tasks = task_arns.each_slice(100).flat_map {|arns| ecs_client.describe_tasks(cluster: @cluster, tasks: arns).tasks }
      if tasks.empty?
        @logger.info("#{__method__}: tasks are empty")
        return true
      end

      if tasks.all? {|task| can_stop?(task) }
        @logger.info("#{__method__}: task cannot stop")
        return true
      end

      false
    end

    def can_stop?(task)
      @task_arns ||= ecs_client.list_tasks(cluster: @cluster).flat_map(&:task_arns)
      @tasks ||= task_arns.each_slice(100).flat_map {|arns| ecs_client.describe_tasks(cluster: @cluster, tasks: task_arns).tasks }

      i = task.task_definition.rindex(":")
      task_definition_prefix = task.task_definition[0..i]
      other_tasks = @tasks.select {|t| t.task_definition.start_with?(task_definition_prefix) && t.task_definition != task.task_definition }

      @logger.info do
        messages = ["#{task.task_arn}: #{task.started_at}"]
        messages.concat(other_tasks.map {|t| "#{t.task_arn}: #{t.started_at}" })
        messages.join("\n")
      end
      other_tasks.all? {|t| t.started_at > task.started_at }
    end

    def stop_tasks(arn)
      running_task_arns = ecs_client.list_tasks(cluster: @cluster, container_instance: arn).task_arns
      unless running_task_arns.empty?
        running_tasks = ecs_client.describe_tasks(cluster: @cluster, tasks: running_task_arns).tasks
        running_tasks.each do |task|
          ecs_client.stop_task(cluster: @cluster, task: task.task_arn) if task.group.start_with?("family:")
        end
      end
      @logger.info("Tasks running on #{arn.split('/').last} will be stopped")
      running_task_arns
    end

    def terminate_instances(instance_ids)
      if instance_ids.empty?
        @logger.info("There are no instances to terminate.")
        return
      end
      instance_ids.each_slice(MAX_DETACHEABLE_EC2_INSTACE_COUNT) do |ids|
        as_client.detach_instances(
          auto_scaling_group_name: @auto_scaling_group_name,
          instance_ids: ids,
          should_decrement_desired_capacity: true
        )
      end

      ec2_client.terminate_instances(instance_ids: instance_ids)

      ec2_client.wait_until(:instance_terminated, instance_ids: instance_ids) do |w|
        w.before_wait do |attempts, response|
          @logger.info("Waiting for stopping all instances...#{attempts}")
          instances = response.reservations.flat_map(&:instances)
          instances.sort_by(&:instance_id).each do |instance|
            @logger.info("#{instance.instance_id}\t#{instance.state.name}")
          end
        end
      end
    end
  end
end
