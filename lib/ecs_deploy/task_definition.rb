require "open3"

module EcsDeploy
  class TaskDefinition
    DIGEST_SUFFIX = /@sha256:[0-9a-f]{64}\z/
    DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/

    def self.deregister(arn, region: nil)
      region ||= EcsDeploy.config.default_region
      params ||= EcsDeploy.config.ecs_client_params
      client = region ? Aws::ECS::Client.new(params.merge(region: region)) : Aws::ECS::Client.new(params)
      client.deregister_task_definition({
        task_definition: arn,
      })
      EcsDeploy.logger.info "deregistered task definition [#{arn}] [#{client.config.region}] [#{Paint['OK', :green]}]"
    end

    def initialize(task_definition_name:, region: nil, use_digest: false, docker_buildx_env: nil, **options)
      @task_definition_name = task_definition_name
      @use_digest = use_digest
      @docker_buildx_env = (EcsDeploy.config.docker_buildx_env || {})
        .merge(docker_buildx_env || {})
        .map { |k, v| [k.to_s, v&.to_s] }.to_h
      region ||= EcsDeploy.config.default_region
      params ||= EcsDeploy.config.ecs_client_params

      @options = options.dup
      @options[:network_mode] ||= "bridge"
      @options[:volumes] ||= []
      @options[:container_definitions] ||= []
      @options[:placement_constraints] ||= []
      @options[:runtime_platform] ||= {}

      @options[:container_definitions] = @options[:container_definitions].map do |cd|
        if cd[:docker_labels]
          cd[:docker_labels] = cd[:docker_labels].map { |k, v| [k.to_s, v] }.to_h
        end
        if cd.dig(:log_configuration, :options)
          cd[:log_configuration][:options] = cd.dig(:log_configuration, :options).map { |k, v| [k.to_s, v] }.to_h
        end
        cd
      end
      @options[:cpu] = @options[:cpu]&.to_s
      @options[:memory] = @options[:memory]&.to_s

      @client = region ? Aws::ECS::Client.new(params.merge(region: region)) : Aws::ECS::Client.new(params)
      @region = @client.config.region
    end

    def recent_task_definition_arns
      resp = @client.list_task_definitions(
        family_prefix: @task_definition_name,
        sort: "DESC"
      )
      resp.task_definition_arns
    rescue
      []
    end

    def register
      options = @options.merge(family: @task_definition_name)
      options[:container_definitions] = apply_digests(options[:container_definitions]) if @use_digest
      res = @client.register_task_definition(options)
      EcsDeploy.logger.info "registered task definition [#{@task_definition_name}] [#{@region}] [#{Paint['OK', :green]}]"
      res.task_definition
    end

    private

    def apply_digests(container_definitions)
      (container_definitions || []).map do |cd|
        image = cd[:image]
        next cd if image.nil? || image.empty?

        resolved = resolve_image_with_digest(image)
        EcsDeploy.logger.info "resolved image [#{image}] -> [#{resolved}]" if resolved != image
        cd.merge(image: resolved)
      end
    end

    def resolve_image_with_digest(image)
      return image if image =~ DIGEST_SUFFIX

      "#{repository_without_tag(image)}@#{fetch_manifest_digest(image)}"
    end

    # "registry:5000/ns/repo:tag" -> "registry:5000/ns/repo"
    # "registry:5000/ns/repo"     -> "registry:5000/ns/repo"
    # "repo:tag"                  -> "repo"
    def repository_without_tag(image)
      name_start = (idx = image.rindex("/")) ? idx + 1 : 0
      colon = image.index(":", name_start)
      colon ? image[0...colon] : image
    end

    def fetch_manifest_digest(image)
      EcsDeploy.logger.debug "docker buildx imagetools inspect --format '{{.Manifest.Digest}}' #{image}"
      stdout, stderr, status =
        Open3.capture3(@docker_buildx_env, "docker", "buildx", "imagetools", "inspect", "--format", "{{.Manifest.Digest}}", image)
      unless status.success?
        raise EcsDeploy::Error, "docker buildx imagetools inspect failed for '#{image}': #{stderr.strip}"
      end
      digest = stdout.strip
      unless digest =~ DIGEST_FORMAT
        raise EcsDeploy::Error, "Unexpected digest for '#{image}': #{digest.inspect}"
      end
      digest
    rescue Errno::ENOENT => e
      raise EcsDeploy::Error, "docker command not found: #{e.message}"
    end
  end
end
