require "spec_helper"

RSpec.describe EcsDeploy::TaskDefinition do
  let(:ecs_client) { Aws::ECS::Client.new(stub_responses: true, region: "us-east-1") }

  before do
    allow(Aws::ECS::Client).to receive(:new).and_return(ecs_client)
    described_class.digest_cache.clear
  end

  # digest of 64 hex chars
  let(:digest) { "sha256:#{"a" * 64}" }

  def stub_imagetools(image, stdout:, success: true, env: {})
    status = instance_double(Process::Status, success?: success)
    allow(Open3).to receive(:capture3)
      .with(env, "docker", "buildx", "imagetools", "inspect", "--format", "{{.Manifest.Digest}}", image)
      .and_return([stdout, "", status])
  end

  def registered_images
    req = ecs_client.api_requests.find { |r| r[:operation_name] == :register_task_definition }
    req[:params][:container_definitions].map { |cd| cd[:image] }
  end

  describe "#register" do
    context "when use_digest is not set" do
      it "passes the image through unchanged and does not invoke docker" do
        expect(Open3).not_to receive(:capture3)

        described_class.new(
          task_definition_name: "td",
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        ).register

        expect(registered_images).to eq(["registry/repo:tag"])
      end
    end

    context "when use_digest is true" do
      it "replaces a normal image's tag with the resolved digest" do
        stub_imagetools("registry/repo:tag", stdout: "#{digest}\n")

        described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        ).register

        expect(registered_images).to eq(["registry/repo@#{digest}"])
      end

      it "keeps the registry port and strips only the tag" do
        stub_imagetools("registry:5000/ns/app:v1", stdout: "#{digest}\n")

        described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [{ name: "app", image: "registry:5000/ns/app:v1" }],
        ).register

        expect(registered_images).to eq(["registry:5000/ns/app@#{digest}"])
      end

      it "leaves an already digest-pinned image untouched without invoking docker" do
        expect(Open3).not_to receive(:capture3)

        image = "registry/repo@#{digest}"
        described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [{ name: "app", image: image }],
        ).register

        expect(registered_images).to eq([image])
      end

      it "appends the digest to a tag-less image" do
        stub_imagetools("registry/repo", stdout: "#{digest}\n")

        described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [{ name: "app", image: "registry/repo" }],
        ).register

        expect(registered_images).to eq(["registry/repo@#{digest}"])
      end

      it "resolves each container definition independently" do
        digest2 = "sha256:#{"b" * 64}"
        stub_imagetools("registry/repo1:tag", stdout: "#{digest}\n")
        stub_imagetools("registry/repo2:tag", stdout: "#{digest2}\n")

        described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [
            { name: "app1", image: "registry/repo1:tag" },
            { name: "app2", image: "registry/repo2:tag" },
          ],
        ).register

        expect(registered_images).to eq(["registry/repo1@#{digest}", "registry/repo2@#{digest2}"])
      end

      it "passes docker_buildx_env to the docker command" do
        env = { "DOCKER_CONFIG" => "/tmp/docker" }
        stub_imagetools("registry/repo:tag", stdout: "#{digest}\n", env: env)

        described_class.new(
          task_definition_name: "td",
          use_digest: true,
          docker_buildx_env: env,
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        ).register

        expect(registered_images).to eq(["registry/repo@#{digest}"])
      end

      it "stringifies docker_buildx_env keys and values" do
        stub_imagetools("registry/repo:tag", stdout: "#{digest}\n", env: { "FOO" => "1" })

        described_class.new(
          task_definition_name: "td",
          use_digest: true,
          docker_buildx_env: { FOO: 1 },
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        ).register

        expect(registered_images).to eq(["registry/repo@#{digest}"])
      end

      it "merges the global docker_buildx_env with the per-task one, task taking precedence" do
        allow(EcsDeploy.config).to receive(:docker_buildx_env)
          .and_return({ "DOCKER_CONFIG" => "/global", "HTTP_PROXY" => "http://proxy" })
        merged = { "DOCKER_CONFIG" => "/task", "HTTP_PROXY" => "http://proxy" }
        stub_imagetools("registry/repo:tag", stdout: "#{digest}\n", env: merged)

        described_class.new(
          task_definition_name: "td",
          use_digest: true,
          docker_buildx_env: { "DOCKER_CONFIG" => "/task" },
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        ).register

        expect(registered_images).to eq(["registry/repo@#{digest}"])
      end

      it "caches the resolved digest per image and inspects it only once per process" do
        stub_imagetools("registry/repo:tag", stdout: "#{digest}\n")

        2.times do
          described_class.new(
            task_definition_name: "td",
            use_digest: true,
            container_definitions: [{ name: "app", image: "registry/repo:tag" }],
          ).register
        end

        expect(Open3).to have_received(:capture3).once
      end

      it "does not cache when resolution fails" do
        status = instance_double(Process::Status, success?: false)
        allow(Open3).to receive(:capture3).and_return(["", "boom", status])

        td = described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        )

        expect { td.register }.to raise_error(EcsDeploy::Error)
        expect(described_class.digest_cache).to be_empty
      end

      it "raises EcsDeploy::Error when the docker command fails" do
        status = instance_double(Process::Status, success?: false)
        allow(Open3).to receive(:capture3).and_return(["", "manifest unknown", status])

        td = described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        )

        expect { td.register }.to raise_error(EcsDeploy::Error, /imagetools inspect failed/)
      end

      it "raises EcsDeploy::Error when docker is not installed" do
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

        td = described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        )

        expect { td.register }.to raise_error(EcsDeploy::Error, /docker command not found/)
      end

      it "raises EcsDeploy::Error when the output is not a valid digest" do
        stub_imagetools("registry/repo:tag", stdout: "not-a-digest\n")

        td = described_class.new(
          task_definition_name: "td",
          use_digest: true,
          container_definitions: [{ name: "app", image: "registry/repo:tag" }],
        )

        expect { td.register }.to raise_error(EcsDeploy::Error, /Unexpected digest/)
      end
    end
  end

  describe "#repository_without_tag" do
    subject(:td) { described_class.new(task_definition_name: "td") }

    {
      "registry:5000/ns/repo:tag" => "registry:5000/ns/repo",
      "registry:5000/ns/repo"     => "registry:5000/ns/repo",
      "registry/ns/repo:tag"      => "registry/ns/repo",
      "registry/ns/repo"          => "registry/ns/repo",
      "repo:tag"                  => "repo",
      "repo"                      => "repo",
    }.each do |input, expected|
      it "strips the tag from #{input.inspect}" do
        expect(td.send(:repository_without_tag, input)).to eq(expected)
      end
    end
  end
end
