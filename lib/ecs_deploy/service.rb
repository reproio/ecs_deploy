require 'timeout'

module EcsDeploy
  class Service
    CHECK_INTERVAL = 5

    def initialize(
      handler:, cluster:, service_name:, task_definition_name: nil, revision: nil,
      elb_name: nil, elb_service_port: nil, elb_healthcheck_port: nil, elb_container_name: nil,
      desired_count: nil, deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 100},
      regions: []
    )
      @handler = handler
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
      @regions = regions
      @responses = {}
    end

    def deploy
      @handler.clients.each do |region, client|
        next if !@regions.empty? && !@regions.include?(region)

        res = client.describe_services(cluster: @cluster, services: [@service_name])
        service_options = {
          cluster: @cluster,
          task_definition: task_definition_name_with_revision,
          deployment_configuration: @deployment_configuration,
        }
        if res.services.empty?
          service_options.merge!({service_name: @service_name})
          if @elb_name
            service_options.merge!({
              role: EcsDeploy.config.ecs_service_role,
              desired_count: @desired_count.to_i,
              load_balancers: [
                {
                  load_balancer_name: @elb_name,
                  container_name: @elb_container_name,
                  container_port: @elb_service_port,
                }
              ],
            })
          end
          @responses[region] = client.create_service(service_options)
          EcsDeploy.logger.info "create service [#{@service_name}] [#{region}] [#{Paint['OK', :green]}]"
        else
          service_options.merge!({service: @service_name})
          service_options.merge!({desired_count: @desired_count}) if @desired_count
          @responses[region] = client.update_service(service_options)
          EcsDeploy.logger.info "update service [#{@service_name}] [#{region}] [#{Paint['OK', :green]}]"
        end
      end
    end

    def wait_running
      return if @responses.empty?

      @responses.each do |region, res|
        client = @handler.clients[region]
        service = res.service
        deployment = nil

        # wait deployment start
        Timeout.timeout(EcsDeploy.config.deploy_wait_timeout) do
          begin
            sleep CHECK_INTERVAL
            service = client.describe_services(cluster: @cluster, services: [service.service_name]).services[0]
          end until service.deployments.find { |d| service.task_definition == d.task_definition }
        end
        EcsDeploy.logger.info "start ECS deployment [#{service.service_name}] [#{region}] [#{Paint['OK', :green]}]"

        Timeout.timeout(EcsDeploy.config.deploy_wait_timeout) do
          begin
            sleep CHECK_INTERVAL
            service = client.describe_services(cluster: @cluster, services: [service.service_name]).services[0]
            deployment = service.deployments.find { |d| service.task_definition == d.task_definition }
            rows = []
            rows << [service.status, deployment.desired_count, deployment.pending_count, deployment.running_count]
            table = Terminal::Table.new headings: ['Status', 'Desired Count', 'Pending Count', 'Running Count'], rows: rows
            puts table
          end until deployment.pending_count == 0 && deployment.desired_count == deployment.running_count
          EcsDeploy.logger.info "finish ECS deployment [#{service.service_name}] [#{region}] [#{Paint['OK', :green]}]"
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
