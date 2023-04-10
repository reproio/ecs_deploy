require "aws-sdk-autoscaling"
require "aws-sdk-ec2"
require "aws-sdk-ecs"

module EcsDeploy
  class InstanceFluctuationManager
    attr_reader :logger

    MAX_UPDATABLE_ECS_CONTAINER_COUNT = 10
    MAX_DETACHEABLE_EC2_INSTACE_COUNT = 20
    MAX_DESCRIBABLE_ECS_TASK_COUNT = 100

    def initialize(region:, cluster:, auto_scaling_group_name:, desired_capacity:, logger:)
      @region = region
      @cluster = cluster
      @auto_scaling_group_name = auto_scaling_group_name
      @desired_capacity = desired_capacity
      @logger = logger
    end

    def increase
      asg = fetch_auto_scaling_group

      @logger.info("Increasing desired capacity of #{@auto_scaling_group_name}: #{asg.desired_capacity} => #{asg.max_size}")
      as_client.update_auto_scaling_group(auto_scaling_group_name: @auto_scaling_group_name, desired_capacity: asg.max_size)

      # Run in background because increasing instances may take time
      Thread.new do
        loop do
          cluster = ecs_client.describe_clusters(clusters: [@cluster]).clusters.first
          instance_count = cluster.registered_container_instances_count
          if instance_count == asg.max_size
            @logger.info("Succeeded in increasing instances!")
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
      @logger.info("Decreasing desired capacity of #{@auto_scaling_group_name}: #{asg.desired_capacity} => #{@desired_capacity}")

      container_instances = ecs_client.list_container_instances(cluster: @cluster).flat_map do |resp|
        ecs_client.describe_container_instances(
          cluster: @cluster,
          container_instances: resp.container_instance_arns
        ).container_instances
      end

      # The status of ECS instances sometimes seems to remain 'DEREGISTERING' for a few minutes after they are terminated.
      container_instances.reject! { |ci| ci.status == 'DEREGISTERING' }

      az_to_container_instances = container_instances.sort_by {|ci| - ci.running_tasks_count }.group_by do |ci|
        ci.attributes.find {|attribute| attribute.name == "ecs.availability-zone" }.value
      end
      if az_to_container_instances.empty?
        @logger.info("There are no instances to terminate.")
        return
      end

      target_container_instances = extract_target_container_instances(decrease_count, az_to_container_instances)

      @logger.info("running tasks: #{ecs_client.list_tasks(cluster: @cluster).task_arns.size}")
      all_running_task_arns = []
      target_container_instances.map(&:container_instance_arn).each_slice(MAX_UPDATABLE_ECS_CONTAINER_COUNT) do |arns|
        @logger.info(arns)
        ecs_client.update_container_instances_state(
          cluster: @cluster,
          container_instances: arns,
          status: "DRAINING"
        )
        arns.each do |arn|
          all_running_task_arns.concat(list_running_task_arns(arn))
        end
      end

      stop_tasks_not_belonging_service(all_running_task_arns)
      wait_until_tasks_stopped(all_running_task_arns)

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
      @ecs_client ||= Aws::ECS::Client.new(aws_params.merge(EcsDeploy.config.ecs_client_params))
    end

    def fetch_auto_scaling_group
      as_client.describe_auto_scaling_groups(auto_scaling_group_names: [@auto_scaling_group_name]).auto_scaling_groups.first
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

    # list tasks whose desired_status is "RUNNING" or
    # whoose desired_status is "STOPPED" but last_status is "RUNNING" on the ECS container
    def list_running_task_arns(container_instance_arn)
      running_tasks_arn = ecs_client.list_tasks(cluster: @cluster, container_instance: container_instance_arn).flat_map(&:task_arns)
      stopped_tasks_arn = ecs_client.list_tasks(cluster: @cluster, container_instance: container_instance_arn, desired_status: "STOPPED").flat_map(&:task_arns)
      stopped_running_task_arns = stopped_tasks_arn.each_slice(MAX_DESCRIBABLE_ECS_TASK_COUNT).flat_map do |arns|
        ecs_client.describe_tasks(cluster: @cluster, tasks: arns).tasks.select do |task|
          task.desired_status == "STOPPED" && task.last_status == "RUNNING"
        end
      end.map(&:task_arn)
      running_tasks_arn + stopped_running_task_arns
    end

    def wait_until_tasks_stopped(task_arns)
      @logger.info("All old tasks: #{task_arns.size}")
      task_arns.each_slice(MAX_DESCRIBABLE_ECS_TASK_COUNT).each do |arns|
        ecs_client.wait_until(:tasks_stopped, cluster: @cluster, tasks: arns)
      end
      @logger.info("All old tasks are stopped")
    end

    def stop_tasks_not_belonging_service(running_task_arns)
      @logger.info("Running tasks: #{running_task_arns.size}")
      unless running_task_arns.empty?
        running_task_arns.each_slice(MAX_DESCRIBABLE_ECS_TASK_COUNT).each do |arns|
          ecs_client.describe_tasks(cluster: @cluster, tasks: arns).tasks.each do |task|
            ecs_client.stop_task(cluster: @cluster, task: task.task_arn) if task.group.start_with?("family:")
          end
        end
      end
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
