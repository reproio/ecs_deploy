require "aws-sdk-ec2"
require "aws-sdk-ecs"
require "aws-sdk-sqs"
require "ecs_deploy"

module EcsDeploy
  module AutoScaler
    class InstanceDrainer
      def initialize(auto_scaling_group_configs:, spot_fleet_request_configs:, logger:)
        @auto_scaling_group_configs = auto_scaling_group_configs || []
        @spot_fleet_request_configs = spot_fleet_request_configs || []
        @logger = logger
        @stop = false
      end

      def poll_spot_instance_interruption_warnings(queue_url)
        @logger.debug "Start polling spot instance interruption warnings of #{queue_url}"

        # cf. https://docs.aws.amazon.com/general/latest/gr/rande.html#sqs_region
        region = URI.parse(queue_url).host.split(".")[1]
        sqs_client = Aws::SQS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: @logger,
        )

        poller = Aws::SQS::QueuePoller.new(queue_url, client: sqs_client)
        poller.before_request do |stats|
          throw :stop_polling if @stop
        end

        until @stop
          begin
            poller.poll(max_number_of_messages: 10, visibility_timeout: 15) do |messages, _|
              instance_ids = messages.map do |msg|
                JSON.parse(msg.body).dig("detail", "instance-id")
              end
              set_instance_state_to_draining(instance_ids, region)
            end
          rescue => e
            AutoScaler.error_logger.error(e)
          end
        end

        @logger.debug "Stop polling spot instance interruption warnings of #{queue_url}"
      end

      def stop
        @stop = true
      end

      private

      def set_instance_state_to_draining(instance_ids, region)
        cluster_to_instance_ids = Hash.new{ |h, k| h[k] = [] }
        ec2_client(region).describe_instances(instance_ids: instance_ids).reservations.each do |reservation|
          reservation.instances.each do |i|
            sfr_id = i.tags.find { |t| t.key == "aws:ec2spot:fleet-request-id" }&.value
            if sfr_id
              config = @spot_fleet_request_configs.find { |c| c.id == sfr_id && c.region == region }
              cluster_to_instance_ids[config.cluster] << i.instance_id if config
              next
            end

            asg_name = i.tags.find { |t| t.key == "aws:autoscaling:groupName" }&.value
            if asg_name
              config = @auto_scaling_group_configs.find { |c| c.name == asg_name && c.region == region }
              cluster_to_instance_ids[config.cluster] << i.instance_id if config
            end
          end
        end

        cl = ecs_client(region)
        cluster_to_instance_ids.each do |cluster, instance_ids|
          arns = cl.list_container_instances(
            cluster: cluster,
            filter: "ec2InstanceId in [#{instance_ids.join(",")}]",
          ).container_instance_arns

          if instance_ids.size != arns.size
            AutoScaler.error_logger.warn("The number of ARNs differs from the number of instance IDs: instance_ids: #{instance_ids.inspect}, container_instance_arns: #{arns.inspect}")
          end
          next if arns.empty?

          cl.update_container_instances_state(
            cluster: cluster,
            container_instances: arns,
            status: "DRAINING",
          )
          @logger.info "Draining instances: region: #{region}, cluster: #{cluster}, instance_ids: #{instance_ids.inspect}, container_instance_arns: #{arns.inspect}"
        end
      end

      def ec2_client(region)
        Aws::EC2::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: @logger,
        )
      end

      def ecs_client(region)
        Aws::ECS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: @logger,
        )
      end
    end
  end
end
