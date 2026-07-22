group "default" {
  targets = ["fuzzingbrain-base"]
}

target "fuzzingbrain-base" {
  context    = "."
  dockerfile = "oss-crs/dockerfiles/base.Dockerfile"
}
