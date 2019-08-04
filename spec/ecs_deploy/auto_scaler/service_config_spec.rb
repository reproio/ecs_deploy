require "spec_helper"

require "ecs_deploy/auto_scaler/service_config"

RSpec.describe EcsDeploy::AutoScaler::ServiceConfig do
  describe "#adjust_desired_count" do
    before do
      allow_any_instance_of(described_class).to receive(:client) { ecs_client }
      allow(ecs_client).to receive(:describe_services).and_return(double(services: [double(desired_count: initial_desired_count)]))
    end

    subject(:service_config) do
      described_class.new({
        "name"    => service_name,
        "cluster" => "cluster",
        "region"  => "ap-northeast-1",
        "step"    => default_step,
        "max_task_count" => 100,
        "min_task_count" => 1,
        "cooldown_time_for_reach_max" => 300,
        "upscale_triggers" => [
          {
            "alarm_name" => "upscale_trigger_with_default_step",
            "region"     => "ap-northeast-1",
            "state"      => "ALARM",
          },
          {
            "alarm_name" => "upscale_trigger_with_step_2",
            "region"     => "ap-northeast-1",
            "state"      => "ALARM",
            "step"       => 2,
          },
          {
            "alarm_name" => "upscale_trigger_with_step_1",
            "region"     => "ap-northeast-1",
            "state"      => "ALARM",
            "step"       => 1,
          },
        ],
        "downscale_triggers" => [
          {
            "alarm_name" => "downscale_trigger_with_step_2",
            "region"     => "ap-northeast-1",
            "state"      => "ALARM",
            "step"       => 2,
          },
        ],
      }, Logger.new(nil))
    end

    let(:service_name) { "service_name" }
    let(:default_step) { 1 }
    let(:initial_desired_count) { 1 }
    let(:ecs_client) { instance_double("Aws::ECS::Client") }

    context "when all triggers match" do
      before do
        (service_config.upscale_triggers + service_config.downscale_triggers).each do |trigger|
          allow(trigger).to receive(:match?).and_return(true)
        end
      end

      it "uses the maximum step of upscale triggers" do
        expect(ecs_client).to receive(:update_service).with(
          cluster: service_config.cluster,
          service: service_config.name,
          desired_count: initial_desired_count + 2,
        )

        service_config.adjust_desired_count
      end
    end

    context "when only a downscale trigger matches" do
      before do
        (service_config.upscale_triggers + service_config.downscale_triggers).each do |trigger|
          allow(trigger).to receive(:match?).and_return(false)
        end
        allow(service_config.downscale_triggers.first).to receive(:match?).and_return(true)
      end

      context "when desired_count - step is greater than or equal to min_task_count" do
        let(:initial_desired_count) { 3 }

        it "decreases desired_count by the step" do
          expect(ecs_client).to receive(:update_service).with(
            cluster: service_config.cluster,
            service: service_config.name,
            desired_count: initial_desired_count - 2,
          )

          expect(ecs_client).to receive(:wait_until).with(:services_stable, cluster: service_config.cluster, services: [service_config.name])
          expect(ecs_client).to receive(:list_tasks).and_return([double(task_arns: ["stopping_task_arn"])], [double(task_arns: [])])
          expect(ecs_client).to receive(:wait_until).with(:tasks_stopped, cluster: service_config.cluster, tasks: ["stopping_task_arn"])

          service_config.adjust_desired_count
        end
      end

      context "when desired_count - step is less than min_task_count" do
        let(:initial_desired_count) { 2 }

        it "decreases desired_count to min_task_count" do
          expect(ecs_client).to receive(:update_service).with(
            cluster: service_config.cluster,
            service: service_config.name,
            desired_count: initial_desired_count - 1,
          )

          expect(ecs_client).to receive(:wait_until).with(:services_stable, cluster: service_config.cluster, services: [service_config.name])
          expect(ecs_client).to receive(:list_tasks).and_return([double(task_arns: ["stopping_task_arn"])], [double(task_arns: [])])
          expect(ecs_client).to receive(:wait_until).with(:tasks_stopped, cluster: service_config.cluster, tasks: ["stopping_task_arn"])

          service_config.adjust_desired_count
        end
      end
    end
  end
end
