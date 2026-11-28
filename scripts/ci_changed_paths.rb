# Emit both sides of renames. Ignore label-only edits in routed workflows.
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
(changed & %w[.github/workflows/build.yml .github/workflows/coverage.yml .github/workflows/ci-changes.yml]).each do |workflow|
  definitions = [base, head].map do |revision|
    source, result = Open3.capture2("git", "show", "#{revision}:#{workflow}")
    next unless result.success? # Added/deleted workflow: retain the changed path.

    workflow_definition(source)
  end
  changed.delete(workflow) if definitions.all? && definitions.first == definitions.last
end
changed.each { |path| STDOUT.write(path, "\0") }
