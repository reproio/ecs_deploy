require "spec_helper"

require "logger"
require "stringio"
require "ecs_deploy/instance_fluctuation_manager"

RSpec.describe EcsDeploy::InstanceFluctuationManager do
  let(:logdev) do
    StringIO.new
  end
  let(:instance_fluctuation_manager) do
    described_class.new(
      region: "ap-northeast-1",
      cluster: "cluster",
      auto_scaling_group_name: "asg-cluster",
      desired_capacity: 50,
      logger: ::Logger.new(logdev)
    )
  end

  describe "#increase" do
    context "w/o error" do
      before do
        @auto_scaling_groups = [
          Aws::AutoScaling::Types::AutoScalingGroup.new(
            desired_capacity: 50,
            max_size: 100
          )
        ]
        Aws.config[:autoscaling] = {
          stub_responses: {
            describe_auto_scaling_groups: lambda do |_|
              Aws::AutoScaling::Types::AutoScalingGroupsType.new(
                auto_scaling_groups: @auto_scaling_groups,
              )
            end,
            update_auto_scaling_group: lambda do |_|
              # no error
              nil
            end
          }
        }

        cluster = Aws::ECS::Types::Cluster.new(registered_container_instances_count: 50)
        expect(cluster).to receive(:registered_container_instances_count)
          .exactly(5).times.and_return(60, 70, 80, 90, 100)
        @clusters = [cluster]
        Aws.config[:ecs] = {
          stub_responses: {
            describe_clusters: lambda do |_|
              Aws::ECS::Types::DescribeClustersResponse.new(clusters: @clusters)
            end
          }
        }

        allow(instance_fluctuation_manager).to receive(:sleep)
      end

      it "succeeded in increasing instances" do
        thread = instance_fluctuation_manager.increase
        thread.join
        log = logdev.string
        expect(log).to include("Increasing desired capacity of asg-cluster: 50 => 100")
        [60, 70, 80, 90].each do |count|
          expect(log).to include("Current registered instance count: #{count}")
        end
        expect(log).to include("Succeeded in increasing instances!")
      end
    end
  end

  describe("#decrease") do
    context "w/ 2 availability zones" do
      before do
        @auto_scaling_groups = [
          Aws::AutoScaling::Types::AutoScalingGroup.new(
            desired_capacity: 100,
            max_size: 100
          )
        ]
        Aws.config[:autoscaling] = {
          stub_responses: {
            describe_auto_scaling_groups: lambda do |_|
              Aws::AutoScaling::Types::AutoScalingGroupsType.new(
                auto_scaling_groups: @auto_scaling_groups,
              )
            end,
            update_auto_scaling_group: lambda do |_|
              # no error
            end,
            detach_instances: lambda do |_|
              # no error
            end
          }
        }

        arns = (1..100).to_a.map {|n| sprintf("arn:aws:ecs:ap-northeast-1:xxx:container-instance/%03d", n) }
        availability_zones = [
          Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "zone-a"),
          Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "zone-b"),
        ]
        container_instances = arns.map do |arn|
          Aws::ECS::Types::ContainerInstance.new(
            container_instance_arn: arn,
            running_tasks_count: rand(1..10),
            attributes: [availability_zones.sample],
            ec2_instance_id: "ec2-#{arn}"
          )
        end
        task_arns = (1..10).to_a.map {|n| sprintf("task-arn%02d", n) }
        tasks = task_arns.map do |arn|
          group = ["family:#{arn}", "dummy:#{arn}"].sample
          Aws::ECS::Types::Task.new(task_arn: arn, group: group)
        end
        Aws.config[:ecs] = {
          stub_responses: {
            list_container_instances: lambda do |_|
              Aws::ECS::Types::ListContainerInstancesResponse.new(container_instance_arns: arns)
            end,
            describe_container_instances: lambda do |_|
              Aws::ECS::Types::DescribeContainerInstancesResponse.new(container_instances: container_instances)
            end,
            update_container_instances_state: lambda do |_|
              # no error
            end,
            list_tasks: lambda do |_|
              Aws::ECS::Types::ListTasksResponse.new(task_arns: task_arns)
            end,
            describe_tasks: lambda do |_|
              Aws::ECS::Types::DescribeTasksResponse.new(tasks: tasks)
            end,
            stop_task: lambda do |_|
              # no error
            end
          }
        }
        # Must stub after set :stub_responses to Aws.config[:ecs]
        ecs_client = instance_fluctuation_manager.send(:ecs_client)
        allow(ecs_client).to receive(:wait_until)
        expect(ecs_client).to receive(:stop_task).at_most(arns.size * tasks.size).times

        Aws.config[:ec2] = {
          stub_responses: {
            terminate_instances: {}
          }
        }
        ec2_client = instance_fluctuation_manager.send(:ec2_client)
        allow(ec2_client).to receive(:wait_until)
      end

      it "succeeded in decreasing instances" do
        instance_fluctuation_manager.decrease
        log = logdev.string
        expect(log).to include("Decreasing desired capacity of asg-cluster: 100 => 50")
        expect(log).to include("Succeeded in decreasing instances!")
        instance_size_per_az = log.lines.grep(/AZ balance/).last.scan(/AZ balance: \{"zone-a"=>(\d+), "zone-b"=>(\d+)\}/).flatten.map(&:to_i)
        expect(instance_size_per_az).to contain_exactly(25, 25)
      end
    end

    context "w/ 3 availability_zones" do
      before do
        @auto_scaling_groups = [
          Aws::AutoScaling::Types::AutoScalingGroup.new(
            desired_capacity: 100,
            max_size: 100
          )
        ]
        Aws.config[:autoscaling] = {
          stub_responses: {
            describe_auto_scaling_groups: lambda do |_|
              Aws::AutoScaling::Types::AutoScalingGroupsType.new(
                auto_scaling_groups: @auto_scaling_groups,
              )
            end,
            update_auto_scaling_group: lambda do |_|
              # no error
            end,
            detach_instances: lambda do |_|
              # no error
            end
          }
        }

        arns = (1..100).to_a.map {|n| sprintf("arn:aws:ecs:ap-northeast-1:xxx:container-instance/%03d", n) }
        availability_zones = [
          Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "zone-a"),
          Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "zone-b"),
          Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "zone-c")
        ]
        container_instances = arns.map do |arn|
          Aws::ECS::Types::ContainerInstance.new(
            container_instance_arn: arn,
            running_tasks_count: rand(1..10),
            attributes: [availability_zones.sample],
            ec2_instance_id: "ec2-#{arn}"
          )
        end
        task_arns = (1..10).to_a.map {|n| sprintf("task-arn%02d", n) }
        tasks = task_arns.map do |arn|
          group = ["family:#{arn}", "dummy:#{arn}"].sample
          Aws::ECS::Types::Task.new(task_arn: arn, group: group)
        end
        Aws.config[:ecs] = {
          stub_responses: {
            list_container_instances: lambda do |_|
              Aws::ECS::Types::ListContainerInstancesResponse.new(container_instance_arns: arns)
            end,
            describe_container_instances: lambda do |_|
              Aws::ECS::Types::DescribeContainerInstancesResponse.new(container_instances: container_instances)
            end,
            update_container_instances_state: lambda do |_|
              # no error
            end,
            list_tasks: lambda do |_|
              Aws::ECS::Types::ListTasksResponse.new(task_arns: task_arns)
            end,
            describe_tasks: lambda do |_|
              Aws::ECS::Types::DescribeTasksResponse.new(tasks: tasks)
            end,
            stop_task: lambda do |_|
              # no error
            end
          }
        }
        # Must stub after set :stub_responses to Aws.config[:ecs]
        ecs_client = instance_fluctuation_manager.send(:ecs_client)
        allow(ecs_client).to receive(:wait_until)
        expect(ecs_client).to receive(:stop_task).at_most(arns.size * tasks.size).times

        Aws.config[:ec2] = {
          stub_responses: {
            terminate_instances: {}
          }
        }
        ec2_client = instance_fluctuation_manager.send(:ec2_client)
        allow(ec2_client).to receive(:wait_until)
      end

      context "desired capacity is multiple of 3" do
        let(:instance_fluctuation_manager) do
          described_class.new(
            region: "ap-northeast-1",
            cluster: "cluster",
            auto_scaling_group_name: "asg-cluster",
            desired_capacity: 60,
            logger: ::Logger.new(logdev)
          )
        end

        it "succeeded in decreasing instances" do
          instance_fluctuation_manager.decrease
          log = logdev.string
          expect(log).to include("Decreasing desired capacity of asg-cluster: 100 => 60")
          expect(log).to include("Succeeded in decreasing instances!")
          instance_size_per_az = log.lines.grep(/AZ balance/).last.scan(/AZ balance: \{"zone-a"=>(\d+), "zone-b"=>(\d+), "zone-c"=>(\d+)\}/).flatten.map(&:to_i)
          expect(instance_size_per_az).to contain_exactly(20, 20, 20)
        end
      end

      context "desired capacity is odd number" do
        let(:instance_fluctuation_manager) do
          described_class.new(
            region: "ap-northeast-1",
            cluster: "cluster",
            auto_scaling_group_name: "asg-cluster",
            desired_capacity: 53,
            logger: ::Logger.new(logdev)
          )
        end

        it "succeeded in decreasing instances" do
          instance_fluctuation_manager.decrease
          log = logdev.string
          expect(log).to include("Decreasing desired capacity of asg-cluster: 100 => 53")
          expect(log).to include("Succeeded in decreasing instances!")
          instance_size_per_az = log.lines.grep(/AZ balance/).last.scan(/AZ balance: \{"zone-a"=>(\d+), "zone-b"=>(\d+), "zone-c"=>(\d+)\}/).flatten.map(&:to_i)
          expect(instance_size_per_az).to contain_exactly(17, 18, 18)
        end
      end
    end

    context "with DEREGISTERING status" do
      let(:instance_fluctuation_manager) do
        described_class.new(
          region: "ap-northeast-1",
          cluster: "cluster",
          auto_scaling_group_name: "asg-cluster",
          desired_capacity: 0,
          logger: ::Logger.new(logdev)
        )
      end
      let(:auto_scaling_groups) do
        [
          Aws::AutoScaling::Types::AutoScalingGroup.new(
            desired_capacity: 1,
            max_size: 5
          )
        ]
      end
      let(:arns) do
        2.times.map { |i| "arn:aws:ecs:ap-northeast-1:xxx:container-instance/00#{i}" }
      end
      let(:ec2_instance_ids) do
        2.times.map { |i| "ec2-#{arns[i]}" }
      end
      let(:container_instances) do
        [
          Aws::ECS::Types::ContainerInstance.new(
            container_instance_arn: arns[0],
            running_tasks_count: 1,
            attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "zone-a")],
            ec2_instance_id: ec2_instance_ids[0],
            status: 'ACTIVE',
          ),
          Aws::ECS::Types::ContainerInstance.new(
            container_instance_arn: arns[1],
            running_tasks_count: 0,
            attributes: [Aws::ECS::Types::Attribute.new(name: "ecs.availability-zone", value: "zone-a")],
            ec2_instance_id: ec2_instance_ids[1],
            status: 'DEREGISTERING',
          )
        ]
      end
      let(:task_arns) do
        2.times.map {|i| sprintf("task-arn%02d", i) }
      end
      let(:tasks) do
        task_arns.map do |arn|
          group = ["family:#{arn}", "dummy:#{arn}"].sample
          Aws::ECS::Types::Task.new(task_arn: arn, group: group)
        end
      end

      before do
        Aws.config[:autoscaling] = {
          stub_responses: {
            describe_auto_scaling_groups: lambda do |_|
              Aws::AutoScaling::Types::AutoScalingGroupsType.new(
                auto_scaling_groups: auto_scaling_groups,
              )
            end,
            update_auto_scaling_group: lambda do |_|
              # no error
            end,
            detach_instances: lambda do |_|
              # no error
            end
          }
        }

        Aws.config[:ecs] = {
          stub_responses: {
            list_container_instances: lambda do |_|
              Aws::ECS::Types::ListContainerInstancesResponse.new(container_instance_arns: arns)
            end,
            describe_container_instances: lambda do |_|
              Aws::ECS::Types::DescribeContainerInstancesResponse.new(container_instances: container_instances)
            end,
            update_container_instances_state: lambda do |_|
              # no error
            end,
            list_tasks: lambda do |_|
              Aws::ECS::Types::ListTasksResponse.new(task_arns: task_arns)
            end,
            describe_tasks: lambda do |_|
              Aws::ECS::Types::DescribeTasksResponse.new(tasks: tasks)
            end,
            stop_task: lambda do |_|
              # no error
            end
          }
        }
        Aws.config[:ec2] = {
          stub_responses: {
            terminate_instances: {}
          }
        }

        # Must stub after set :stub_responses to Aws.config[:ecs]
        ecs_client = instance_fluctuation_manager.send(:ecs_client)
        allow(ecs_client).to receive(:wait_until)
        expect(ecs_client).to receive(:stop_task).at_most(2).times


        ec2_client = instance_fluctuation_manager.send(:ec2_client)
        allow(ec2_client).to receive(:wait_until)
      end

      it "succeeded in decreasing instances" do
        # terminate instances whose status is not 'DEREGISTERING'
        ec2_client = instance_fluctuation_manager.send(:ec2_client)
        expect(ec2_client).to receive(:terminate_instances).with(instance_ids: [ec2_instance_ids[0]])

        instance_fluctuation_manager.decrease
        log = logdev.string
        expect(log).to include("Decreasing desired capacity of asg-cluster: 1 => 0")
        expect(log).to include("Succeeded in decreasing instances!")
      end
    end
  end
end
