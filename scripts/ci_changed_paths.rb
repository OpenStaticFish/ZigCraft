# Emit both sides of renames. Build definition edits select the full suite,
# except when the only semantic changes are job runner labels.
require "open3"
require "yaml"

# Compare syntax trees rather than Ruby values: e.g. `on` and `yes` are
# distinct Actions environment strings even though Psych loads both as true.
def field(mapping, name)
  return unless mapping&.mapping?

  pair = mapping.children.each_slice(2).find { |key, _| key.scalar? && key.value == name }
  pair&.last
end

def workflow_definition(source)
  stream = Psych.parse_stream(source)
  # An anchored label (or job) could also supply an executable value elsewhere.
  return stream.yaml if stream.any? { |node| node.respond_to?(:anchor) && node.anchor }

  jobs = field(stream.children.first&.root, "jobs")
  if jobs&.mapping?
    jobs.children.each_slice(2) do |_, job|
      runner = field(job, "runs-on")
      labels = runner&.mapping? ? field(runner, "labels") : runner
      next unless labels

      values = labels.sequence? ? labels.children : [labels]
      next unless values.all? { |v| v.scalar? && !v.tag && !v.value.include?("${{") }

      # Keep the runs-on mapping and its group; normalize literal labels only.
      if labels.sequence?
        labels.children.replace([Psych::Nodes::Scalar.new("runner-label")])
      else
        labels.value = "runner-label"
      end
    end
  end
  stream.yaml
end

base, head = ARGV
paths, status = Open3.capture2("git", "diff", "--name-only", "--no-renames", "-z", base, head, "--")
abort "Cannot compare #{base} and #{head}" unless status.success?
changed = paths.split("\0")
build_file = ".github/workflows/build.yml"
if changed.include?(build_file)
  definitions = [base, head].map do |revision|
    source, result = Open3.capture2("git", "show", "#{revision}:#{build_file}")
    next unless result.success? # Added/deleted workflow: run the full suite.

    workflow_definition(source)
  end
  changed.delete(build_file) if definitions.all? && definitions.first == definitions.last
end
changed.each { |path| STDOUT.write(path, "\0") }
