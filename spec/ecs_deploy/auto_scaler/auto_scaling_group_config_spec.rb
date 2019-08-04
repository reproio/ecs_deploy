require "spec_helper"

require "ecs_deploy/auto_scaler/auto_scaling_group_config"
require "ecs_deploy/auto_scaler/service_config"

RSpec.describe EcsDeploy::AutoScaler::AutoScalingGroupConfig do
  describe "#update_desired_capacity" do
    subject(:auto_scaling_group_config) do
      described_class.new({
        "name"   => asg_name,
        "region" => "ap-northeast-1",
        "buffer" => buffer,
      }, Logger.new(nil))
    end

    let(:asg_name) { "asg_name" }
    let(:buffer) { 1 }
    let(:service_config) { instance_double("EcsDeploy::AutoScaler::ServiceConfig") }

    context "when the current desired capacity is greater than expected" do
      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name],
        ).and_return(
          double(
            auto_scaling_groups: [
              double(
                desired_capacity: container_instances.size,
                instances: container_instances.map { |i| double(availability_zone: i.attributes.find { |a| a.name == "ecs.availability-zone" }.value) },
              )
            ]
          )
        )

        allow(service_config).to receive(:fetch_container_instances_in_cluster).and_return(container_instances)
        allow(auto_scaling_group_config).to receive(:sleep).and_return(nil)

      end

      context "when there are deregistable instances in all availability zones" do
        let(:container_instances) do
          [
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 1,
              running_tasks_count: 0,
              ec2_instance_id: "i-000000",
              container_instance_arn: "with_pending_task",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1a")],
            ),
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 0,
              running_tasks_count: 0,
              ec2_instance_id: "i-111111",
              container_instance_arn: "with_no_task_in_ap_notrheast_1a",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1a")],
            ),
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 0,
              running_tasks_count: 1,
              ec2_instance_id: "i-222222",
              container_instance_arn: "with_essential_running_task",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1a")],
            ),
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 0,
              running_tasks_count: 0,
              ec2_instance_id: "i-333333",
              container_instance_arn: "with_no_task_in_ap_notrheast_1c",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1c")],
            ),
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 0,
              running_tasks_count: 1,
              ec2_instance_id: "i-444444",
              container_instance_arn: "with_no_essential_running_task",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1c")],
            ),
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 0,
              running_tasks_count: 0,
              ec2_instance_id: "i-555555",
              container_instance_arn: "with_no_task_in_ap_notrheast_1a_2",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1a")],
            ),
          ]
        end

        before do
          allow(service_config).to receive(:fetch_container_instance_arns_in_service).and_return(["with_essential_running_task"])
        end

        it "terminates instances without esesstial running tasks" do
          expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances).with(service_config)
          expect(service_config).to receive(:deregister_container_instance).with("with_no_task_in_ap_notrheast_1a")
          expect(service_config).to receive(:deregister_container_instance).with("with_no_essential_running_task")
          expect(service_config).to receive(:deregister_container_instance).with("with_no_task_in_ap_notrheast_1a_2")
          expect_any_instance_of(Aws::AutoScaling::Client).to receive(:detach_instances).with(
            auto_scaling_group_name: asg_name,
            instance_ids: ["i-555555", "i-111111", "i-444444"],
            should_decrement_desired_capacity: true,
          )
          expect_any_instance_of(Aws::EC2::Client).to receive(:terminate_instances).with(instance_ids: ["i-555555", "i-111111", "i-444444"])

          auto_scaling_group_config.update_desired_capacity(2, service_config)
        end
      end

      context "when there are deregistable instances only in one availability zone" do
        let(:container_instances) do
          [
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 0,
              running_tasks_count: 1,
              ec2_instance_id: "i-000000",
              container_instance_arn: "with_essential_running_task_1a_0",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1a")],
            ),
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 0,
              running_tasks_count: 1,
              ec2_instance_id: "i-111111",
              container_instance_arn: "with_essential_running_task_1a_1",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1a")],
            ),
            Aws::ECS::Types::ContainerInstance.new(
              pending_tasks_count: 0,
              running_tasks_count: 0,
              ec2_instance_id: "i-222222",
              container_instance_arn: "with_no_essential_running_task_1c",
              attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1c")],
            ),
          ]
        end

        before do
          allow(service_config).to receive(:fetch_container_instance_arns_in_service).and_return([
            "with_essential_running_task_1a_0",
            "with_essential_running_task_1a_1",
          ])
        end

        it "dosen't terminates any instancess" do
          expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances).with(service_config)
          expect(service_config).to_not receive(:deregister_container_instance)
          expect_any_instance_of(Aws::AutoScaling::Client).to_not receive(:detach_instances)
          expect_any_instance_of(Aws::EC2::Client).to_not receive(:terminate_instances)

          auto_scaling_group_config.update_desired_capacity(1, service_config)
        end
      end
    end

    context "when the current desired capacity is less than expected" do
      let(:desired_count) { 2 }

      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name]
        ).and_return(double(auto_scaling_groups: [double(desired_capacity: desired_count, max_size: 100)]))
      end

      it "updates the desired capacity of the auto scaling group" do
        expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances).with(service_config)
        expect_any_instance_of(Aws::AutoScaling::Client).to receive(:update_auto_scaling_group).with(
          auto_scaling_group_name: asg_name,
          min_size: 0,
          max_size: 100,
          desired_capacity: desired_count + buffer,
        )

        auto_scaling_group_config.update_desired_capacity(desired_count, service_config)
      end
    end

    context "when the current desired capacity is expected" do
      let(:desired_count) { 2 }

      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name]
        ).and_return(double(auto_scaling_groups: [double(desired_capacity: desired_count + buffer)]))
      end

      it "does nothing" do
        expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances).with(service_config)
        expect_any_instance_of(Aws::EC2::Client).to_not receive(:terminate_instances)
        expect_any_instance_of(Aws::AutoScaling::Client).to_not receive(:update_auto_scaling_group)

        auto_scaling_group_config.update_desired_capacity(desired_count, service_config)
      end
    end
  end
end
