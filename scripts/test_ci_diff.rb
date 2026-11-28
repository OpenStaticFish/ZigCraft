require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

# Run the shipped Actions step, so changing the event ranges or diff flags
# changes the code under test as well.
workflow = YAML.safe_load_file(".github/workflows/ci-changes.yml", aliases: true)
step = workflow.dig("jobs", "classify", "steps").find { |s| s["id"] == "filter" }.fetch("run")
def git(*args)
  output, status = Open3.capture2e("git", *args)
  abort output unless status.success?
  output.strip
end

def check_route(step, event, base, expected)
  output = File.expand_path(".git/outputs")
  File.write(output, "")
  env = { "BASE" => base, "HEAD" => git("rev-parse", "HEAD"),
          "GITHUB_EVENT_NAME" => event, "GITHUB_OUTPUT" => output }
  abort "classification failed" unless system(env, "bash", "-eo", "pipefail", "-c", step)
  decisions = File.readlines(output, chomp: true).map { |line| line.split("=") }.to_h
  wanted = %w[game fmt graphics shaders coverage].to_h { |job| [job, expected.include?(job).to_s] }
  abort "#{event}: expected #{wanted}, got #{decisions}" unless decisions == wanted
end

workflow_dir = File.expand_path(".github/workflows")
Dir.mktmpdir do |dir|
  Dir.chdir(dir) do
    git("init", "-q", "-b", "dev")
    git("config", "user.email", "ci@example.invalid")
    git("config", "user.name", "CI fixture")
    FileUtils.mkdir_p(["scripts", "src", ".github/workflows"])
    FileUtils.cp(%w[ci_changes.py ci_changed_paths.rb].map { |f| File.join(__dir__, f) }, "scripts")
    build = ".github/workflows/build.yml"
    coverage = ".github/workflows/coverage.yml"
    File.write(coverage, "jobs:\n  kcov:\n    runs-on: ubuntu-latest\n    steps:\n      - run: kcov report zig build test\n")
    File.write(build, "jobs:\n  compile:\n    runs-on: ubuntu-latest\n    env:\n      MODE: on\n    steps:\n      - run: zig build\n")
    classifier = ".github/workflows/ci-changes.yml"
    FileUtils.cp(File.join(workflow_dir, "ci-changes.yml"), classifier)
    source = "src/file with\nnewline.zig"
    File.write(source, "fixture")
    git("add", ".")
    git("commit", "-qm", "base")
    git("branch", "topic")
    File.write("src/base-only.zig", "base only")
    git("add", ".")
    git("commit", "-qm", "advance base after branch point")
    git("switch", "-q", "topic")
    File.write(build, File.read(build).sub("ubuntu-latest", "ubuntu-24.04"))
    git("commit", "-qam", "change only runner label")
    check_route(step, "pull_request", "dev", [])
    git("mv", source, "README.md")
    git("commit", "-qm", "rename game file to prose")
    check_route(step, "pull_request", "dev", %w[fmt game graphics coverage])
    File.write(build, File.read(build).sub("zig build", "zig build test"))
    git("commit", "-qam", "change executable step")
    check_route(step, "push", "HEAD^", %w[fmt game graphics shaders coverage])
    File.write("README.md", "docs only")
    git("commit", "-qam", "docs after game changes")
    check_route(step, "push", "HEAD^", [])
    File.write(build, File.read(build).sub("MODE: on", "MODE: yes"))
    git("commit", "-qam", "change executable environment string")
    check_route(step, "push", "HEAD^", %w[fmt game graphics shaders coverage])
    File.write(build, File.read(build).sub("runs-on: ubuntu-24.04", "runs-on:\n      group: standard\n      labels: [linux, x64]"))
    git("commit", "-qam", "select runner group")
    check_route(step, "push", "HEAD^", %w[fmt game graphics shaders coverage])
    File.write(build, File.read(build).sub("[linux, x64]", "[linux, arm64]"))
    git("commit", "-qam", "change labels within group")
    check_route(step, "push", "HEAD^", [])
    File.write(build, File.read(build).sub("group: standard", "group: dedicated"))
    git("commit", "-qam", "change runner group")
    check_route(step, "push", "HEAD^", %w[fmt game graphics shaders coverage])
    File.write(coverage, File.read(coverage).sub("kcov report", "kcov new-report"))
    git("commit", "-qam", "change coverage command")
    check_route(step, "push", "HEAD^", %w[coverage])
    File.write(coverage, File.read(coverage).sub("ubuntu-latest", "ubuntu-24.04"))
    git("commit", "-qam", "change only coverage runner label")
    check_route(step, "push", "HEAD^", [])
    FileUtils.mkdir_p(".github/vulkan")
    File.write(".github/vulkan/vk_layer_settings.txt", "fixture")
    git("add", ".github/vulkan")
    git("commit", "-qm", "change only graphics settings")
    check_route(step, "push", "HEAD^", %w[graphics])

    # Exercise the actual gate reader with a valid alias outside the gates.
    extra_job = <<~YAML
      alias-fixture:
        runs-on: ubuntu-latest
        env:
          FIRST: &message hello
          SECOND: *message
        steps:
          - run: echo fixture
    YAML
    File.write(build, File.read(File.join(workflow_dir, "build.yml")) + extra_job.gsub(/^/, "  "))
    gate_test = File.join(__dir__, "test_build_gates.rb")
    abort "gate checks rejected valid aliases" unless system("ruby", gate_test)
    File.write(classifier, File.read(classifier).sub("jobs.classify.outputs.graphics", "jobs.classify.outputs.game"))
    git("add", classifier)
    git("commit", "-qm", "misroute reusable workflow output")
    check_route(step, "push", "HEAD^", %w[fmt game graphics shaders coverage])
    abort "gate fixture accepted miswired graphics" if system("ruby", gate_test, err: File::NULL)
  end
end
puts "Git diff routing passed for diverged PRs, renames, runner labels, build commands and consecutive pushes."
