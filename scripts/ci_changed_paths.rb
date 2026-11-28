# Emit both sides of renames. Build definition edits select the full suite,
# except when the only semantic changes are job runner labels.
require "open3"
require "yaml"

base, head = ARGV
paths, status = Open3.capture2("git", "diff", "--name-only", "--no-renames", "-z", base, head, "--")
abort "Cannot compare #{base} and #{head}" unless status.success?
changed = paths.split("\0")
build_file = ".github/workflows/build.yml"
if changed.include?(build_file)
  definitions = [base, head].map do |revision|
    source, result = Open3.capture2("git", "show", "#{revision}:#{build_file}")
    next unless result.success? # Added/deleted workflow: run the full suite.

    workflow = YAML.safe_load(source, aliases: true)
    workflow.fetch("jobs").each_value { |job| job.delete("runs-on") }
    workflow
  end
  changed.delete(build_file) if definitions.all? && definitions.first == definitions.last
end
changed.each { |path| STDOUT.write(path, "\0") }
