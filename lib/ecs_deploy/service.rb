require 'timeout'

module EcsDeploy
  class Service
    CHECK_INTERVAL = 5
    attr_reader :cluster, :region, :service_name

    def initialize(
      cluster:, service_name:, task_definition_name: nil, revision: nil,
      elb_name: nil, elb_service_port: nil, elb_healthcheck_port: nil, elb_container_name: nil,
      desired_count: nil, deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 100},
      region: nil
    )
      @cluster = cluster
      @service_name = service_name
      @task_definition_name = task_definition_name || service_name
      @elb_name = elb_name
      @elb_service_port = elb_service_port
      @elb_healthcheck_port = elb_healthcheck_port
      @elb_container_name = elb_container_name
      @desired_count = desired_count
      @deployment_configuration = deployment_configuration
      @revision = revision
      @region = region || EcsDeploy.config.default_region || ENV["AWS_DEFAULT_REGION"]
      @response = nil

      @client = Aws::ECS::Client.new(region: @region)
    end

    def current_task_definition_arn
      res = @client.describe_services(cluster: @cluster, services: [@service_name])
      res.services[0].task_definition
    end

    def deploy
      res = @client.describe_services(cluster: @cluster, services: [@service_name])
      service_options = {
        cluster: @cluster,
        task_definition: task_definition_name_with_revision,
        deployment_configuration: @deployment_configuration,
      }
      if res.services.empty?
        service_options.merge!({
          service_name: @service_name,
          desired_count: @desired_count.to_i,
        })
        if @elb_name
          service_options.merge!({
            role: EcsDeploy.config.ecs_service_role,
            load_balancers: [
              {
                load_balancer_name: @elb_name,
                container_name: @elb_container_name,
                container_port: @elb_service_port,
              }
            ],
          })
        end
        @response = @client.create_service(service_options)
        EcsDeploy.logger.info "create service [#{@service_name}] [#{@region}] [#{Paint['OK', :green]}]"
      else
        service_options.merge!({service: @service_name})
        service_options.merge!({desired_count: @desired_count}) if @desired_count
        @response = @client.update_service(service_options)
        EcsDeploy.logger.info "update service [#{@service_name}] [#{@region}] [#{Paint['OK', :green]}]"
      end
    end

    def wait_running
      return if @response.nil?

      service = @response.service
      deployment = nil

      @client.wait_until(:services_stable, cluster: @cluster, services: [service.service_name]) do |w|
        w.delay = 10

        w.before_attempt do
          EcsDeploy.logger.info "wait service stable [#{service.service_name}]"
        end
      end
    end

    def self.wait_all_running(services)
      services.group_by { |s| [s.cluster, s.region] }.each do |(cl, region), ss|
        client = Aws::ECS::Client.new(region: region)
        service_names = ss.map(&:service_name)
        client.wait_until(:services_stable, cluster: cl, services: service_names) do |w|
          w.before_attempt do
            EcsDeploy.logger.info "wait service stable [#{service_names.join(", ")}]"
          end
        end
      end
    end

    private

    def task_definition_name_with_revision
      suffix = @revision ? ":#{@revision}" : ""
      "#{@task_definition_name}#{suffix}"
    end
  end
end
