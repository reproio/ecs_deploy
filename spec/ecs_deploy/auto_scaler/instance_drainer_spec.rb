require "spec_helper"

require "ecs_deploy/auto_scaler/auto_scaling_group_config"
require "ecs_deploy/auto_scaler/instance_drainer"

RSpec.describe EcsDeploy::AutoScaler::InstanceDrainer do
  describe "#poll_spot_instance_interruption_warnings" do
    subject(:drainer) do
      described_class.new(
        auto_scaling_group_configs: [asg_config],
        spot_fleet_request_configs: [double(id: "sfr_id", region: "ap-northeast-1", cluster: nil, disable_draining: disable_draining)],
        logger: Logger.new(nil),
      )
    end

    let(:asg_config) do
      instance_double("EcsDeploy::AutoScaler::AutoScalingGroupConfig",
        name: "asg_name",
        region: "ap-northeast-1",
        cluster: "ecs-cluster",
        disable_draining: disable_draining,
      )
    end

    let(:instances) do
      [
        { instance_id: 'i-000000', tags: [{ key: "aws:ec2spot:fleet-request-id", value: "sfr_id" }] },
        { instance_id: 'i-111111', tags: [{ key: "aws:ec2spot:fleet-request-id", value: "another_sfr_id" }] },
        { instance_id: 'i-222222', tags: [{ key: "aws:autoscaling:groupName", value: "asg_name" }] },
        { instance_id: 'i-333333', tags: [{ key: "aws:autoscaling:groupName", value: "another_asg_name" }] },
        { instance_id: 'i-444444', tags: [] },
      ]
    end

    let(:messages) do
      instances.map do |i|
        {
          body: %Q|{"version":"0","id":"478e68b4-9ad3-1fb4-e8a2-aef2d793738d","detail-type":"EC2 Spot Instance Interruption Warning","source":"aws.ec2","account":"1234","time":"2019-10-05T14:19:37Z","region":"ap-northeast-1","resources":["arn:aws:ec2:ap-northeast-1a:instance/#{i[:instance_id]}"],"detail":{"instance-id":"#{i[:instance_id]}","instance-action":"terminate"}}|,
        }
      end
    end

    let(:ec2_client) { Aws::EC2::Client.new(stub_responses: true) }
    let(:ecs_client) { Aws::ECS::Client.new(stub_responses: true) }
    let(:sqs_client) { Aws::SQS::Client.new(stub_responses: true) }

    before do
      allow(drainer).to receive(:ec2_client) { ec2_client }
      allow(drainer).to receive(:ecs_client) { ecs_client }
      allow(drainer).to receive(:sqs_client) { sqs_client }

      sqs_client.stub_responses(:receive_message, { messages: messages })
      allow(sqs_client).to receive(:delete_message_batch) do
        drainer.stop
        throw :stop_polling
      end

      ec2_client.stub_responses(:describe_instances, ->(context) {
        if context.params[:instance_ids] == instances.map { |i| i[:instance_id] }
          { reservations: [{ instances: instances }] }
        else
          {}
        end
      })

      ecs_client.stub_responses(:list_container_instances, ->(context) {
        if context.params[:cluster] == nil && context.params[:filter] == "ec2InstanceId in [i-000000]"
          { container_instance_arns: ["arn:i-000000"] }
        elsif context.params[:cluster] == "ecs-cluster" && context.params[:filter] == "ec2InstanceId in [i-222222]"
          { container_instance_arns: ["arn:i-222222"] }
        else
          {}
        end
      })
    end

    [nil, false, "false"].each do |disable_draining|
      context "with disable_draining #{disable_draining.inspect}" do
        let(:disable_draining) { disable_draining }

        it "updates the state of interrupted instances to 'DRAINING'" do
          expect(asg_config).to receive(:detach_instances).with(instance_ids: ["i-222222"], should_decrement_desired_capacity: false)

          drainer.poll_spot_instance_interruption_warnings("https://sqs.ap-northeast-1.amazonaws.com/account_id/queue_name")

          expect(ecs_client.api_requests).to include({
            operation_name: :update_container_instances_state,
            params: { cluster: nil, container_instances: ["arn:i-000000"], status: "DRAINING" },
            context: a_kind_of(Seahorse::Client::RequestContext),
          })
          expect(ecs_client.api_requests).to include({
            operation_name: :update_container_instances_state,
            params: { cluster: "ecs-cluster", container_instances: ["arn:i-222222"], status: "DRAINING" },
            context: a_kind_of(Seahorse::Client::RequestContext),
          })
        end
      end
    end

    [true, "true"].each do |disable_draining|
      context "with disable_draining #{disable_draining.inspect}" do
        let(:disable_draining) { disable_draining }

        it "updates the state of interrupted instances to 'DRAINING'" do
          expect(asg_config).to receive(:detach_instances).with(instance_ids: ["i-222222"], should_decrement_desired_capacity: false)

          drainer.poll_spot_instance_interruption_warnings("https://sqs.ap-northeast-1.amazonaws.com/account_id/queue_name")

          expect(ecs_client.api_requests).to eq []
        end
      end
    end
  end
end
