require "spec_helper"

require "ecs_deploy/auto_scaler/auto_scaling_group_config"
require "ecs_deploy/auto_scaler/service_config"

RSpec.describe EcsDeploy::AutoScaler::AutoScalingGroupConfig do
  describe "#update_auto_scaling_group" do
    subject(:auto_scaling_group_config) do
      described_class.new({
        "name"   => asg_name,
        "region" => "ap-northeast-1",
        "buffer" => buffer,
      }, Logger.new(nil))
    end

    let(:asg_name) { "asg_name" }
    let(:buffer) { 1 }
    let(:desired_tasks) { 2 }
    let(:service_config) { instance_double("EcsDeploy::AutoScaler::ServiceConfig") }

    context "when the current desired capacity is greater than expected" do
      let(:container_instances) do
        [
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 1,
            running_tasks_count: 0,
            ec2_instance_id: "i-000000",
            container_instance_arn: "with_pending_task",
          ),
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 0,
            running_tasks_count: 0,
            ec2_instance_id: "i-111111",
            container_instance_arn: "with_no_task_1"
          ),
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 0,
            running_tasks_count: 1,
            ec2_instance_id: "i-222222",
            container_instance_arn: "with_essential_running_task"
          ),
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 0,
            running_tasks_count: 1,
            ec2_instance_id: "i-333333",
            container_instance_arn: "with_no_essential_running_task"
          ),
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 0,
            running_tasks_count: 0,
            ec2_instance_id: "i-444444",
            container_instance_arn: "with_no_task_2"
          ),
        ]
      end

      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name]
        ).and_return(double(auto_scaling_groups: [double(desired_capacity: container_instances.size)]))

        allow(service_config).to receive(:fetch_container_instance_arns_in_service).and_return(["with_essential_running_task"])
        allow(service_config).to receive(:fetch_container_instances_in_cluster).and_return(container_instances)
        allow(auto_scaling_group_config).to receive(:sleep).and_return(nil)
      end

      it "terminates instances without esesstial running tasks" do
        expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances).with(service_config)
        expect(service_config).to receive(:deregister_container_instance).with("with_no_task_1")
        expect(service_config).to receive(:deregister_container_instance).with("with_no_essential_running_task")
        expect_any_instance_of(Aws::AutoScaling::Client).to receive(:detach_instances).with(
          auto_scaling_group_name: asg_name,
          instance_ids: ["i-111111", "i-333333"],
          should_decrement_desired_capacity: true,
        )
        expect_any_instance_of(Aws::EC2::Client).to receive(:terminate_instances).with(instance_ids: ["i-111111", "i-333333"])

        auto_scaling_group_config.update_auto_scaling_group(desired_tasks, service_config)
      end
    end

    context "when the current desired capacity is less than expected" do
      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name]
        ).and_return(double(auto_scaling_groups: [double(desired_capacity: desired_tasks, max_size: 100)]))
      end

      it "updates the desired capacity of the auto scaling group" do
        expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances).with(service_config)
        expect_any_instance_of(Aws::AutoScaling::Client).to receive(:update_auto_scaling_group).with(
          auto_scaling_group_name: asg_name,
          min_size: 0,
          max_size: 100,
          desired_capacity: desired_tasks + buffer,
        )

        auto_scaling_group_config.update_auto_scaling_group(desired_tasks, service_config)
      end
    end

    context "when the current desired capacity is expected" do
      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name]
        ).and_return(double(auto_scaling_groups: [double(desired_capacity: desired_tasks + buffer)]))
      end

      it "does nothing" do
        expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances).with(service_config)
        expect_any_instance_of(Aws::EC2::Client).to_not receive(:terminate_instances)
        expect_any_instance_of(Aws::AutoScaling::Client).to_not receive(:update_auto_scaling_group)

        auto_scaling_group_config.update_auto_scaling_group(desired_tasks, service_config)
      end
    end
  end
end
