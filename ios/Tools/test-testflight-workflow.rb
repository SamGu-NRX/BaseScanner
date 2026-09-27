# Runs the TestFlight workflow's "Select project", "Configure the integration build" and "Check
# build inputs" steps, as written in .github/workflows/testflight.yml, against a copy of the
# repository's tracked iOS files, then asks xcodebuild what the written config resolves to. Nothing
# here signs, uploads or reads a secret. From the repository root:
#   ruby ios/Tools/test-testflight-workflow.rb
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
WORKFLOW = YAML.load_file(File.join(ROOT, ".github/workflows/testflight.yml"))
STEPS = WORKFLOW.fetch("jobs").fetch("upload").fetch("steps")
PROJECT = YAML.load_file(File.join(ROOT, "ios/project.yml"))
LOCAL_CONFIG = "ios/Config/Integration.local.xcconfig"
EXAMPLE_URL = "https://api.example.test/v1"

$failures = 0

def check(label, ok, detail = nil)
  puts "#{ok ? 'ok  ' : 'FAIL'} #{label}"
  puts "     #{detail}" if !ok && detail
  $failures += 1 unless ok
end

def script(name)
  step = STEPS.find { |s| s["name"] == name } or abort("No step named '#{name}' in testflight.yml")
  step.fetch("run")
end

# A checkout holding the tracked files under ios/ plus a stand-in Measure Lab project, which lives
# on another branch.
def checkout
  Dir.mktmpdir("testflight-test") do |dir|
    files, status = Open3.capture2("git", "-C", ROOT, "ls-files", "-z", "ios")
    abort("git ls-files failed") unless status.success?
    files.split("\0").each do |file|
      next unless File.file?(File.join(ROOT, file))
      FileUtils.mkdir_p(File.join(dir, File.dirname(file)))
      FileUtils.cp(File.join(ROOT, file), File.join(dir, file))
    end
    FileUtils.mkdir_p(File.join(dir, "experiments/measure-lab"))
    FileUtils.touch(File.join(dir, "experiments/measure-lab/project.yml"))
    FileUtils.mkdir_p(File.join(dir, "runner-temp"))
    yield dir
  end
end

# Runs one step the way GitHub's default shell does (bash -e), with only the env the job gives it.
def run_step(dir, name, env)
  base = {
    "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin", "HOME" => ENV.fetch("HOME"),
    "GITHUB_ENV" => File.join(dir, "github-env"), "GITHUB_REF_NAME" => "test-branch",
    "RUNNER_TEMP" => File.join(dir, "runner-temp")
  }
  out, status = Open3.capture2e(base.merge(env), "/bin/bash", "-e", "-c", script(name),
                                chdir: dir, unsetenv_others: true)
  [status.success?, out]
end

def github_env(dir)
  path = File.join(dir, "github-env")
  return {} unless File.exist?(path)
  File.readlines(path, chomp: true).map { |line| line.split("=", 2) }.to_h
end

# Select project, then configure, as the job does; returns [configure ok, output, env, config text].
def prepare(dir, app, url: nil, send: "false")
  selected, out = run_step(dir, "Select project", "APP" => app)
  return [false, out, {}, nil] unless selected
  env = github_env(dir)
  step_env = env.merge("APP" => app, "SEND_DEVICE_PHOTOS" => send, "HOUSESCAN_CAPTURE_API_URL" => url.to_s)
  ok, out = run_step(dir, "Configure the integration build", step_env)
  config = File.join(dir, LOCAL_CONFIG)
  [ok, out, env, File.exist?(config) ? File.read(config) : nil]
end

def expected_config(send)
  "// Written by the TestFlight workflow for this run.\n" \
    "HOUSESCAN_CAPTURE_API_URL = https:/$()/api.example.test/v1\n" \
    "HOUSESCAN_CAPTURE_SEND_DEVICE_DATA = #{send}\n"
end

puts "Endpoint binding"
endpoint_step = STEPS.find { |step| step["name"] == "Configure the integration build" }
check("only the integration selection receives the endpoint secret",
      endpoint_step.dig("env", "HOUSESCAN_CAPTURE_API_URL") == "${{ inputs.app == 'house-scan-integration' && secrets.HOUSESCAN_CAPTURE_API_URL || '' }}")

puts "Selection"
{
  "house-scan" => %w[ios HouseScan HouseScan Release HouseScanKit],
  "house-scan-integration" => ["ios", "HouseScan", "HouseScan Integration", "Integration Release", "HouseScanKit"],
  "measure-lab" => %w[experiments/measure-lab MeasureLab MeasureLab Release Geometry]
}.each do |app, (dir_name, name, scheme, configuration, packages)|
  checkout do |dir|
    ok, out, env, = prepare(dir, app, url: app == "house-scan-integration" ? EXAMPLE_URL : nil)
    want = { "PROJECT_DIR" => dir_name, "PROJECT_NAME" => name, "PROJECT_SCHEME" => scheme,
             "BUILD_CONFIGURATION" => configuration, "ALLOWED_LOCAL_PACKAGES" => packages }
    check("#{app} selects #{scheme} / #{configuration}", ok && env == want, "#{env.inspect}\n#{out}")
  end
end
checkout do |dir|
  ok, out = run_step(dir, "Select project", "APP" => "house-scan-beta")
  check("an unknown app fails", !ok && out.include?("Unknown app"), out)
end

puts "Ordinary apps leave the integration config alone"
%w[house-scan measure-lab].each do |app|
  checkout do |dir|
    ok, out, _, config = prepare(dir, app, url: EXAMPLE_URL)
    check("#{app} writes no Integration.local.xcconfig", ok && config.nil?, out)
    ok, out, _, config = prepare(dir, app, send: "true")
    check("#{app} refuses the device-photo opt-in", !ok && config.nil? && out.include?("applies only to house-scan-integration"), out)
  end
end

puts "Integration config"
checkout do |dir|
  ok, out, _, config = prepare(dir, "house-scan-integration", url: EXAMPLE_URL)
  check("default writes the endpoint with split slashes and device data NO", ok && config == expected_config("NO"), "#{config.inspect}\n#{out}")
  check("the log does not show the endpoint", !out.sub("::add-mask::#{EXAMPLE_URL}", "").include?("api.example.test"), out)
end
checkout do |dir|
  ok, out, _, config = prepare(dir, "house-scan-integration", url: EXAMPLE_URL, send: "true")
  check("the opt-in writes device data YES", ok && config == expected_config("YES"), "#{config.inspect}\n#{out}")
end
checkout do |dir|
  ok, out, _, config = prepare(dir, "house-scan-integration", url: "https://api.example.test:8443/api/v1/")
  check("a port and a trailing slash are accepted", ok && config&.include?("= https:/$()/api.example.test:8443/api/v1/\n"), out)
end
checkout do |dir|
  File.write(File.join(dir, LOCAL_CONFIG), "HOUSESCAN_CAPTURE_SEND_DEVICE_DATA = YES\n")
  ok, out, _, config = prepare(dir, "house-scan-integration", url: EXAMPLE_URL)
  check("an Integration.local.xcconfig already in the checkout fails", !ok && config == "HOUSESCAN_CAPTURE_SEND_DEVICE_DATA = YES\n", out)
end
checkout do |dir|
  ok, out, _, config = prepare(dir, "house-scan-integration", send: "yes")
  check("an opt-in other than true or false fails", !ok && config.nil?, out)
end

puts "Missing or unsafe endpoints fail without writing or printing it"
{
  "missing" => "",
  "http" => "http://api.example.test/v1",
  "another scheme" => "ftp://api.example.test/v1",
  "no host" => "https:///v1",
  "credentials" => "https://user:pass@api.example.test/v1",
  "fragment" => "https://api.example.test/v1#frag",
  "query" => "https://api.example.test/v1?key=value",
  "newline and a second setting" => "#{EXAMPLE_URL}\nHOUSESCAN_CAPTURE_SEND_DEVICE_DATA = YES",
  "carriage return" => "#{EXAMPLE_URL}\r",
  "tab" => "https://api.example.test/\tv1",
  "control character" => "https://api.example.test/\x01v1",
  "trailing space" => "#{EXAMPLE_URL} ",
  "xcconfig expansion" => "https://api.example.test/$(inherited)",
  "xcconfig comment in the path" => "https://api.example.test//v1",
  "xcconfig include" => "https://api.example.test/v1\n#include \"/tmp/x.xcconfig\"",
  "semicolon" => "https://api.example.test/v1;x",
  "quote" => "https://api.example.test/\"v1",
  "equals sign" => "https://api.example.test/v1=x",
  "port 0" => "https://api.example.test:0/v1",
  "port above 65535" => "https://api.example.test:70000/v1",
  "host starting with a dash" => "https://-api.example.test/v1"
}.each do |label, url|
  checkout do |dir|
    ok, out, _, config = prepare(dir, "house-scan-integration", url: url)
    check("#{label} fails", !ok && config.nil? && !out.include?("api.example.test") && out.include?("::error::"), out)
  end
end

puts "The build-input guard accepts the written config"
checkout do |dir|
  ok, out, env, = prepare(dir, "house-scan-integration", url: EXAMPLE_URL)
  guard_ok, guard_out = run_step(dir, "Check build inputs", env)
  check("Check build inputs passes for house-scan-integration", ok && guard_ok, "#{out}\n#{guard_out}")
end

puts "Names match ios/project.yml"
scheme = PROJECT.fetch("schemes").fetch("HouseScan Integration")
check("scheme 'HouseScan Integration' archives Integration Release", scheme.dig("archive", "config") == "Integration Release")
check("scheme 'HouseScan' archives Release", PROJECT.dig("schemes", "HouseScan", "archive", "config") == "Release")
check("configuration 'Integration Release' is a release configuration", PROJECT.dig("configs", "Integration Release") == "release")
check("HouseScanKit is the only package", PROJECT.fetch("packages").keys == ["HouseScanKit"])
check("Integration Release uses Config/Integration.xcconfig",
      PROJECT.dig("targets", "HouseScan", "configFiles", "Integration Release") == "Config/Integration.xcconfig")
check("Integration.xcconfig includes Integration.local.xcconfig",
      File.read(File.join(ROOT, "ios/Config/Integration.xcconfig")).include?("#include? \"Integration.local.xcconfig\""))

puts "xcodebuild reads the written config"
def settings(dir, scheme, configuration)
  out, status = Open3.capture2e("xcodebuild", "-showBuildSettings", "-project", File.join(dir, "ios/HouseScan.xcodeproj"),
                                "-scheme", scheme, "-configuration", configuration, "-disableAutomaticPackageResolution",
                                "BUNDLE_ID_PREFIX=test.example")
  abort("xcodebuild -showBuildSettings failed:\n#{out}") unless status.success?
  # The first target listed is the app; the UI test bundle follows.
  app = out.split(/^Build settings for action/).find { |block| block.include?("TARGET_NAME = HouseScan\n") }
  app.scan(/^\s+(\w+) = (.*)$/).to_h
end
checkout do |dir|
  ok, out, = prepare(dir, "house-scan-integration", url: EXAMPLE_URL)
  abort("configure failed:\n#{out}") unless ok
  integration = settings(dir, "HouseScan Integration", "Integration Release")
  check("integration endpoint resolves to #{EXAMPLE_URL}", integration["HOUSESCAN_CAPTURE_API_URL"] == EXAMPLE_URL, integration["HOUSESCAN_CAPTURE_API_URL"].inspect)
  check("integration device data is NO", integration["HOUSESCAN_CAPTURE_SEND_DEVICE_DATA"] == "NO")
  check("integration bundle id is <prefix>.housescan.integration", integration["PRODUCT_BUNDLE_IDENTIFIER"] == "test.example.housescan.integration",
        integration["PRODUCT_BUNDLE_IDENTIFIER"].inspect)
  check("integration display name is House Scan Integration", integration["HOUSESCAN_DISPLAY_NAME"] == "House Scan Integration")
  client = settings(dir, "HouseScan", "Release")
  check("client build has no endpoint", client["HOUSESCAN_CAPTURE_API_URL"].to_s.empty?, client["HOUSESCAN_CAPTURE_API_URL"].inspect)
  check("client build is not the integration build", client["HOUSESCAN_INTEGRATION_BUILD"] == "NO")
  check("client bundle id is <prefix>.housescan", client["PRODUCT_BUNDLE_IDENTIFIER"] == "test.example.housescan", client["PRODUCT_BUNDLE_IDENTIFIER"].inspect)
end

puts($failures.zero? ? "All checks passed." : "#{$failures} check(s) failed.")
exit($failures.zero? ? 0 : 1)
