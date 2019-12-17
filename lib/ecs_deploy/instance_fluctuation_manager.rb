require "aws-sdk-autoscaling"
require "aws-sdk-ec2"
require "aws-sdk-ecs"

module EcsDeploy
  class InstanceFluctuationManager
    attr_reader :logger

    def initialize(region:, cluster:, cluster_to_asg:, desired_capacity:, logger:)
      @region = region
      @cluster = cluster
      @cluster_to_asg = cluster_to_asg
      @desired_capacity = desired_capacity
      @logger = logger

      unless cluster_to_asg.key?(cluster)
        raise ArgumentError, "Unknown cluster: #{cluster}"
      end

      @asg_name = cluster_to_asg[cluster]
    end

    def increase
      asg = as_client.describe_auto_scaling_groups(auto_scaling_group_names: [@asg_name]).auto_scaling_groups.first

      @logger.info("Increase desired capacity of #{@asg_name}: #{asg.desired_capacity} => #{asg.max_size}")
      as_client.update_auto_scaling_group(auto_scaling_group_name: @asg_name, desired_capacity: asg.max_size)

      # Run in background because increasing instances may take time
      Thread.new do
        loop do
          cluster = ecs_client.describe_clusters(clusters: [@cluster]).clusters.first
          instance_count = cluster.registered_container_instances_count
          if instance_count == asg.max_size
            @logger.info("Succeeded to increase instance count!")
            break
          end
          @logger.info("Current registered instance count: #{instance_count}")
          sleep 5
        end
      end
    end

    def decrease
      asg = as_client.describe_auto_scaling_groups(auto_scaling_group_names: [@asg_name]).auto_scaling_groups.first

      decrease_count = asg.desired_capacity - @desired_capacity
      if decrease_count <= 0
        @logger.info("The capacity is already #{asg.desired_capacity}")
        return
      end
      @logger.info("Decrease desired capacity of #{@asg_name}: #{asg.desired_capacity} => #{@desired_capacity}")

      container_instance_arns = ecs_client.list_container_instances(
        cluster: @cluster
      ).container_instance_arns
      container_instances = ecs_client.describe_container_instances(
        cluster: @cluster,
        container_instances: container_instance_arns
      ).container_instances

      az_to_container_instances = container_instances.sort_by {|ci| - ci.running_tasks_count }.group_by do |ci|
        ci.attributes.find {|attribute| attribute.name == "ecs.availability-zone" }.value
      end
      if az_to_container_instances.empty?
        @logger.info("There are no instances to terminate.")
        return
      end

      target_container_instances = extract_target_container_instances(decrease_count, az_to_container_instances)

      threads = []
      target_container_instances.map(&:container_instance_arn).each_slice(10) do |arns|
        ecs_client.update_container_instances_state(
          cluster: @cluster,
          container_instances: arns,
          status: "DRAINING"
        )
        arns.each do |arn|
          threads << Thread.new(arn) do |a|
            stop_tasks(a)
          end
        end
      end

      threads.each(&:join)

      instance_ids = target_container_instances.map(&:ec2_instance_id)
      terminate_instances(instance_ids)
      @logger.info("Succeeded to decrease instances!")
    end

    private

    def as_client
      @as_client ||= Aws::AutoScaling::Client.new(
        access_key_id: EcsDeploy.config.access_key_id,
        secret_access_key: EcsDeploy.config.secret_access_key,
        region: @region,
        logger: @logger
      )
    end

    def ec2_client
      @ec2_client ||= Aws::EC2::Client.new(
        access_key_id: EcsDeploy.config.access_key_id,
        secret_access_key: EcsDeploy.config.secret_access_key,
        region: @region,
        logger: @logger
      )
    end

    def ecs_client
      @ecs_client ||= Aws::ECS::Client.new(
        access_key_id: EcsDeploy.config.access_key_id,
        secret_access_key: EcsDeploy.config.secret_access_key,
        region: @region,
        logger: @logger
      )
    end

    # Extract container instances to terminate considering AZ balance
    def extract_target_container_instances(decrease_count, az_to_container_instances)
      target_container_instances = []
      decrease_count.times do
        @logger.debug do
          "AZ balance: #{az_to_container_instances.sort_by {|az, _| az }.map {|az, instances| [az, instances.size] }.to_h}"
        end
        az = az_to_container_instances.max_by {|_az, instances| instances.size }.first
        target_container_instances << az_to_container_instances[az].pop
      end
      @logger.info do
        "AZ balance: #{az_to_container_instances.sort_by {|az, _| az }.map {|az, instances| [az, instances.size] }.to_h}"
      end

      target_container_instances
    end

    def stop_tasks(arn)
      running_task_arns = ecs_client.list_tasks(cluster: @cluster, container_instance: arn).task_arns
      unless running_task_arns.empty?
        running_tasks = ecs_client.describe_tasks(cluster: @cluster, tasks: running_task_arns).tasks
        running_tasks.each do |task|
          ecs_client.stop_task(cluster: @cluster, task: task.task_arn) if task.group.start_with?("family:")
        end
        ecs_client.wait_until(:tasks_stopped, cluster: @cluster, tasks: running_task_arns)
      end
      @logger.info("Task #{arn.split('/').last} stopped")
    end

    def terminate_instances(instance_ids)
      if instance_ids.empty?
        @logger.info("There are no instances to terminate.")
        return
      end
      instance_ids.each_slice(20) do |ids|
        as_client.detach_instances(
          auto_scaling_group_name: @asg_name,
          instance_ids: ids,
          should_decrement_desired_capacity: true
        )
      end

      ec2_client.terminate_instances(instance_ids: instance_ids)

      loop do
        instances = ec2_client.describe_instances(instance_ids: instance_ids).reservations.flat_map(&:instances)
        break if instances.all? {|instance| instance.state.name == "terminated" }

        @logger.info("Waiting for stopping all instances...")
        instances.sort_by(&:instance_id).each do |instance|
          @logger.info("#{instance.instance_id}\t#{instance.state.name}")
        end
        sleep 10
      end
    end
  end
end
