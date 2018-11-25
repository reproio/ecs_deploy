require "spec_helper"

require "ecs_deploy/auto_scaler/instance_drainer"

RSpec.describe EcsDeploy::AutoScaler::InstanceDrainer do
  describe "#poll_spot_instance_interruption_warnings" do
    subject(:drainer) do
      described_class.new(service_configs, Logger.new(nil))
    end

    let(:service_configs) do
      [
        double(region: "ap-northeast-1", auto_scaling_group_name: nil, spot_fleet_request_id: "sfr_id", cluster: nil, foo: 1),
        double(region: "ap-northeast-1", auto_scaling_group_name: "asg_name", spot_fleet_request_id: nil, cluster: "ecs-cluster"),
      ]
    end

    let(:instances) do
      [
        Aws::EC2::Types::Instance.new(instance_id: 'i-000000', tags: [double(key: "aws:ec2spot:fleet-request-id", value: "sfr_id")]),
        Aws::EC2::Types::Instance.new(instance_id: 'i-111111', tags: [double(key: "aws:ec2spot:fleet-request-id", value: "another_sfr_id")]),
        Aws::EC2::Types::Instance.new(instance_id: 'i-222222', tags: [double(key: "aws:autoscaling:groupName", value: "asg_name")]),
        Aws::EC2::Types::Instance.new(instance_id: 'i-333333', tags: [double(key: "aws:autoscaling:groupName", value: "another_asg_name")]),
        Aws::EC2::Types::Instance.new(instance_id: 'i-444444', tags: []),
      ]
    end

    let(:messages) do
      instances.map do |i|
        double(
          body: %Q|{"detail":{"instance-id":"#{i.instance_id}"}}|,
          message_id: i.instance_id,
          receipt_handle: nil,
        )
      end
    end

    before do
      allow_any_instance_of(Aws::SQS::Client).to receive(:receive_message).and_return(double(messages: messages))
      allow_any_instance_of(Aws::SQS::Client).to receive(:delete_message_batch) do
        drainer.stop
        throw :stop_polling
      end

      allow_any_instance_of(Aws::EC2::Client).to receive(:describe_instances).with(
        instance_ids: instances.map(&:instance_id)
      ).and_return(double(reservations: [double(instances: instances)]))
    end

    it "updates the state of instances to be interrupted to 'DRAINING'" do
      expect_any_instance_of(Aws::ECS::Client).to receive(:list_container_instances).with(
        cluster: nil,
        filter: "ec2InstanceId in [i-000000]",
      ).and_return(double(container_instance_arns: ["arn:i-000000"]))
      expect_any_instance_of(Aws::ECS::Client).to receive(:list_container_instances).with(
        cluster: "ecs-cluster",
        filter: "ec2InstanceId in [i-222222]",
      ).and_return(double(container_instance_arns: ["arn:i-222222"]))

      expect_any_instance_of(Aws::ECS::Client).to receive(:update_container_instances_state).with(
        cluster: nil,
        container_instances: ["arn:i-000000"],
        status: "DRAINING",
      ).and_return("arn:i-000000")
      expect_any_instance_of(Aws::ECS::Client).to receive(:update_container_instances_state).with(
        cluster: "ecs-cluster",
        container_instances: ["arn:i-222222"],
        status: "DRAINING",
      ).and_return("arn:i-222222")

      drainer.poll_spot_instance_interruption_warnings("https://sqs.ap-northeast-1.amazonaws.com/account_id/queue_name")
    end
  end
end
