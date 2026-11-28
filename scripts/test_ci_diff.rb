require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

# Run the shipped Actions step, so changing the event ranges or diff flags
# changes the code under test as well.
workflow = YAML.load_file(".github/workflows/ci-changes.yml")
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
  wanted = %w[game fmt graphics shaders].to_h { |job| [job, expected.include?(job).to_s] }
  abort "#{event}: expected #{wanted}, got #{decisions}" unless decisions == wanted
end

Dir.mktmpdir do |dir|
  Dir.chdir(dir) do
    git("init", "-q", "-b", "dev")
    git("config", "user.email", "ci@example.invalid")
    git("config", "user.name", "CI fixture")
    FileUtils.mkdir_p(["scripts", "src", ".github/workflows"])
    FileUtils.cp(%w[ci_changes.py ci_changed_paths.rb].map { |f| File.join(__dir__, f) }, "scripts")
    build = ".github/workflows/build.yml"
    File.write(build, "jobs:\n  compile:\n    runs-on: ubuntu-latest\n    steps:\n      - run: zig build\n")
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
    check_route(step, "pull_request", "dev", %w[fmt game graphics])
    File.write(build, File.read(build).sub("zig build", "zig build test"))
    git("commit", "-qam", "change executable step")
    check_route(step, "push", "HEAD^", %w[fmt game graphics shaders])
    File.write("README.md", "docs only")
    git("commit", "-qam", "docs after game changes")
    check_route(step, "push", "HEAD^", [])
  end
end
puts "Git diff routing passed for diverged PRs, renames, runner labels, build commands and consecutive pushes."
