# Exercise the required jobs' actual shell steps and needs bindings without
# starting any of the compilers or graphics runners they depend on.
require "yaml"

jobs = YAML.load_file(".github/workflows/build.yml").fetch("jobs")
routes = {
  "docs" => [],
  "game" => %w[game fmt graphics],
  "shader baseline" => %w[shaders],
  "game and shader checker" => %w[game fmt graphics shaders],
  "graphics runner" => %w[graphics],
}
selectors = {
  "fmt" => "fmt",
  "compile" => "game",
  "unit-test-matrix" => "game",
  "shader-validation" => "shaders",
  "integration-test" => "graphics",
}

def run_gate(job, results, outputs)
  raise "gate must run after failures and skips" unless job.fetch("if") == "always()"
  bindings = {}
  job.fetch("needs").each do |dependency|
    bindings["needs.#{dependency}.result"] = results.fetch(dependency)
    next unless dependency == "changes"

    outputs.each do |flag, value|
      bindings["needs.changes.outputs.#{flag}"] = value
    end
  end
  step = job.fetch("steps").fetch(0)
  env = step.fetch("env").transform_values do |template|
    template.gsub(/\$\{\{ (.*?) \}\}/) { bindings.fetch(Regexp.last_match(1)) }
  end
  system(env, "bash", "-e", "-c", step.fetch("run"), out: File::NULL)
end

routes.each do |route, selected|
  outputs = selectors.values.uniq.to_h { |flag| [flag, selected.include?(flag).to_s] }
  results = selectors.transform_values { |flag| selected.include?(flag) ? "success" : "skipped" }
  results.merge!("changes" => "success", "build" => "success")
  { "build" => %w[changes fmt compile],
    "unit-test" => %w[changes build unit-test-matrix shader-validation integration-test] }.each do |gate, inputs|
    job = jobs.fetch(gate)
    abort "#{route}: #{gate} rejected expected results" unless run_gate(job, results, outputs)
    inputs.filter_map { |input| selectors[input] }.each do |flag|
      if run_gate(job, results, outputs.merge(flag => ""))
        abort "#{route}: #{gate} accepted missing #{flag} output"
      end
    end
    inputs.select { |input| results.fetch(input) == "success" }.each do |input|
      %w[failure cancelled skipped].each do |status|
        if run_gate(job, results.merge(input => status), outputs)
          abort "#{route}: #{gate} accepted #{status} from #{input}"
        end
      end
    end
  end
end
puts "Required gates passed docs, game, shader-only and graphics-only fixtures."
