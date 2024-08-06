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
        "services" => [],
      }, Logger.new(nil))
    end

    let(:asg_name) { "asg_name" }
    let(:buffer) { 1 }
    let(:cluster_resource_manager) { instance_double("EcsDeploy::AutoScaler::ClusterResourceManager") }

    before do
      allow(auto_scaling_group_config).to receive(:cluster_resource_manager) { cluster_resource_manager }
    end

    context "when the current desired capacity is greater than expected" do
      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name],
        ).and_return(
          double(
            auto_scaling_groups: [
              double(
                desired_capacity: container_instances.size,
                instances: container_instances.map do |i|
                  double(
                    availability_zone: i.attributes.find { |a| a.name == "ecs.availability-zone" }.value,
                    instance_id: i.ec2_instance_id,
                    lifecycle_state: "InService",
                  )
                end,
              )
            ]
          )
        )

        allow(cluster_resource_manager).to receive(:fetch_container_instances_in_cluster).and_return(container_instances)
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
          allow(cluster_resource_manager).to receive(:fetch_container_instance_arns_in_service).and_return(["with_essential_running_task"])
        end

        it "terminates instances without esesstial running tasks" do
          expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances)
          expect(cluster_resource_manager).to receive(:deregister_container_instance).with("with_no_task_in_ap_notrheast_1a")
          expect(cluster_resource_manager).to receive(:deregister_container_instance).with("with_no_essential_running_task")
          expect(cluster_resource_manager).to receive(:deregister_container_instance).with("with_no_task_in_ap_notrheast_1a_2")
          expect(cluster_resource_manager).to receive(:trigger_capacity_update).with(container_instances.size, 3)
          expect_any_instance_of(Aws::AutoScaling::Client).to receive(:detach_instances).with(
            auto_scaling_group_name: asg_name,
            instance_ids: ["i-555555", "i-111111", "i-444444"],
            should_decrement_desired_capacity: true,
          )
          expect_any_instance_of(Aws::EC2::Client).to receive(:terminate_instances).with(instance_ids: ["i-555555", "i-111111", "i-444444"])

          auto_scaling_group_config.update_desired_capacity(2)
        end
      end

      context "when there are deregisterable instances only in one availability zone where there are fewer instances" do
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
          allow(cluster_resource_manager).to receive(:fetch_container_instance_arns_in_service).and_return([
            "with_essential_running_task_1a_0",
            "with_essential_running_task_1a_1",
          ])
        end

        it "dosen't terminates any instances" do
          expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances)
          expect(cluster_resource_manager).to_not receive(:deregister_container_instance)
          expect(cluster_resource_manager).to_not receive(:trigger_capacity_update)
          expect_any_instance_of(Aws::AutoScaling::Client).to_not receive(:detach_instances)
          expect_any_instance_of(Aws::EC2::Client).to_not receive(:terminate_instances)

          auto_scaling_group_config.update_desired_capacity(1)
        end
      end
    end

    context "when the current desired capacity is less than expected" do
      let(:current_capacity) { 2 }
      let(:desired_capacity) { current_capacity + buffer }

      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name]
        ).and_return(double(auto_scaling_groups: [double(desired_capacity: current_capacity, max_size: 100)]))
      end

      it "updates the desired capacity of the auto scaling group" do
        expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances)
        expect(cluster_resource_manager).to receive(:trigger_capacity_update).with(current_capacity, desired_capacity)
        expect_any_instance_of(Aws::AutoScaling::Client).to receive(:update_auto_scaling_group).with(
          auto_scaling_group_name: asg_name,
          min_size: 0,
          max_size: 100,
          desired_capacity: desired_capacity,
        )

        auto_scaling_group_config.update_desired_capacity(current_capacity)
      end
    end

    context "when the current desired capacity is expected" do
      let(:current_capacity) { 2 + buffer }

      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name]
        ).and_return(double(auto_scaling_groups: [double(desired_capacity: current_capacity)]))
      end

      it "does nothing" do
        expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances)
        expect(cluster_resource_manager).to_not receive(:trigger_capacity_update)
        expect_any_instance_of(Aws::EC2::Client).to_not receive(:terminate_instances)
        expect_any_instance_of(Aws::AutoScaling::Client).to_not receive(:update_auto_scaling_group)

        auto_scaling_group_config.update_desired_capacity(current_capacity - buffer)
      end
    end

    context "when detached instance is still in the ecs cluster" do
      let(:container_instances) do
        [
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 0,
            running_tasks_count: 0,
            ec2_instance_id: "i-000000",
            container_instance_arn: "with_no_pending_and_running_task_1a",
            attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1a")],
          ),
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 0,
            running_tasks_count: 0,
            ec2_instance_id: "i-111111",
            container_instance_arn: "already_detached_by_drainer_but_still_in_the_cluster",
            attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1a")],
          ),
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 0,
            running_tasks_count: 1,
            ec2_instance_id: "i-222222",
            container_instance_arn: "with_running_task",
            attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1c")],
          ),
          Aws::ECS::Types::ContainerInstance.new(
            pending_tasks_count: 0,
            running_tasks_count: 0,
            ec2_instance_id: "i-333333",
            container_instance_arn: "with_no_pending_and_running_task_1c",
            attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "ap-notrheast-1c")],
          ),
        ]
      end
      let(:auto_scaling_group_instances) do
        [
          Aws::AutoScaling::Types::Instance.new(
            instance_id: "i-000000",
            availability_zone: "ap-notrheast-1a",
            lifecycle_state: "InService",
            health_status: "Healthy",
            launch_template: "launch_template",
            protected_from_scale_in: true,
          ),
          Aws::AutoScaling::Types::Instance.new(
            instance_id: "i-222222",
            availability_zone: "ap-notrheast-1c",
            lifecycle_state: "InService",
            health_status: "Healthy",
            launch_template: "launch_template",
            protected_from_scale_in: true,
          ),
          Aws::AutoScaling::Types::Instance.new(
            instance_id: "i-333333",
            availability_zone: "ap-notrheast-1c",
            lifecycle_state: "InService",
            health_status: "Healthy",
            launch_template: "launch_template",
            protected_from_scale_in: true,
          ),
        ]
      end

      before do
        allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
          auto_scaling_group_names: [asg_name],
        ).and_return(
          double(
            auto_scaling_groups: [
              double(
                desired_capacity: container_instances.size,
                instances: auto_scaling_group_instances.map do |i|
                  double(
                    availability_zone: i.availability_zone,
                    instance_id: i.instance_id,
                    lifecycle_state: "InService",
                  )
                end,
              )
            ]
          )
        )

        allow(cluster_resource_manager).to receive(:fetch_container_instances_in_cluster).and_return(container_instances)
        allow(auto_scaling_group_config).to receive(:sleep).and_return(nil)
        allow(cluster_resource_manager).to receive(:fetch_container_instance_arns_in_service).and_return(["with_running_task"])
      end

      it "terminates auto scaliing group instances without esesstial running tasks" do
        expect(auto_scaling_group_config).to receive(:detach_and_terminate_orphan_instances)
        expect(cluster_resource_manager).to receive(:deregister_container_instance).with("with_no_pending_and_running_task_1c")
        expect(cluster_resource_manager).not_to receive(:deregister_container_instance).with("already_detached_but_still_in_the_cluster")
        expect_any_instance_of(Aws::AutoScaling::Client).to receive(:detach_instances).with(
          auto_scaling_group_name: asg_name,
          instance_ids: ["i-333333"],
          should_decrement_desired_capacity: true,
        )
        expect_any_instance_of(Aws::EC2::Client).to receive(:terminate_instances).with(instance_ids: ["i-333333"])
        expect(cluster_resource_manager).to receive(:trigger_capacity_update).with(container_instances.size, 3)

        auto_scaling_group_config.update_desired_capacity(2)
      end
    end
  end

  describe "#detach_instances" do
    subject(:auto_scaling_group_config) do
      described_class.new({
        "name"   => asg_name,
        "region" => "ap-northeast-1",
        "buffer" => 0,
        "services" => [],
      }, Logger.new(nil))
    end

    let(:asg_name) { "asg_name" }
    let(:auto_scaling_group_instances) do
      [
        Aws::AutoScaling::Types::Instance.new(
          instance_id: "i-000000",
          availability_zone: "ap-notrheast-1a",
          lifecycle_state: "InService",
          health_status: "Healthy",
          launch_template: "launch_template",
          protected_from_scale_in: true,
        ),
        Aws::AutoScaling::Types::Instance.new(
          instance_id: "i-222222",
          availability_zone: "ap-notrheast-1c",
          lifecycle_state: "Standby",
          health_status: "Healthy",
          launch_template: "launch_template",
          protected_from_scale_in: true,
        ),
        Aws::AutoScaling::Types::Instance.new(
          instance_id: "i-333333",
          availability_zone: "ap-notrheast-1c",
          lifecycle_state: "Terminating",
          health_status: "",
          launch_template: "launch_template",
          protected_from_scale_in: true,
        ),
      ]
    end

    before do
      allow_any_instance_of(Aws::AutoScaling::Client).to receive(:describe_auto_scaling_groups).with(
        auto_scaling_group_names: [asg_name],
      ).and_return(
        double(
          auto_scaling_groups: [
            double(
              desired_capacity: auto_scaling_group_instances.size,
              instances: auto_scaling_group_instances.map do |i|
                double(
                  availability_zone: i.availability_zone,
                  instance_id: i.instance_id,
                  lifecycle_state: i.lifecycle_state,
                )
              end,
            )
          ]
        )
      )
    end

    it "detaches only detachable instances" do
      expect_any_instance_of(Aws::AutoScaling::Client).to receive(:detach_instances).with(
        auto_scaling_group_name: asg_name,
        instance_ids: ["i-000000", "i-222222"],
        should_decrement_desired_capacity: false,
      )

      auto_scaling_group_config.detach_instances(instance_ids: ["i-000000", "i-222222", "i-333333"], should_decrement_desired_capacity: false)
    end
  end

end
