# Exercise the required jobs' actual shell steps and needs bindings without
# starting any of the compilers or graphics runners they depend on.
require "yaml"

jobs = YAML.load_file(".github/workflows/build.yml").fetch("jobs")
routes = {
  "docs" => [],
  "game" => %w[game fmt graphics],
  "shader baseline" => %w[shaders],
  "graphics runner" => %w[graphics],
}
selectors = {
  "fmt" => "fmt",
  "compile" => "game",
  "unit-test-matrix" => "game",
  "shader-validation" => "shaders",
  "integration-test" => "graphics",
}

def run_gate(job, results, selected)
  raise "gate must run after failures and skips" unless job.fetch("if") == "always()"
  bindings = {}
  job.fetch("needs").each do |dependency|
    bindings["needs.#{dependency}.result"] = results.fetch(dependency)
    next unless dependency == "changes"

    %w[fmt game shaders graphics].each do |flag|
      bindings["needs.changes.outputs.#{flag}"] = selected.include?(flag).to_s
    end
  end
  step = job.fetch("steps").fetch(0)
  env = step.fetch("env").transform_values do |template|
    template.gsub(/\$\{\{ (.*?) \}\}/) { bindings.fetch(Regexp.last_match(1)) }
  end
  system(env, "bash", "-e", "-c", step.fetch("run"), out: File::NULL)
end

routes.each do |route, selected|
  results = selectors.transform_values { |flag| selected.include?(flag) ? "success" : "skipped" }
  results.merge!("changes" => "success", "build" => "success")
  { "build" => %w[changes fmt compile],
    "unit-test" => %w[changes build unit-test-matrix shader-validation integration-test] }.each do |gate, inputs|
    job = jobs.fetch(gate)
    abort "#{route}: #{gate} rejected expected results" unless run_gate(job, results, selected)
    inputs.select { |input| results.fetch(input) == "success" }.each do |input|
      %w[failure cancelled skipped].each do |status|
        if run_gate(job, results.merge(input => status), selected)
          abort "#{route}: #{gate} accepted #{status} from #{input}"
        end
      end
    end
  end
end
puts "Required gates passed docs, game, shader-only and graphics-only fixtures."
