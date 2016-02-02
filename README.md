# fluent-plugin-kubernetes_metadata_filter, a plugin for [Fluentd](http://fluentd.org)
[![Circle CI](https://circleci.com/gh/fabric8io/fluent-plugin-kubernetes_metadata_filter.svg?style=svg)](https://circleci.com/gh/fabric8io/fluent-plugin-kubernetes_metadata_filter)
[![Code Climate](https://codeclimate.com/github/fabric8io/fluent-plugin-kubernetes_metadata_filter/badges/gpa.svg)](https://codeclimate.com/github/fabric8io/fluent-plugin-kubernetes_metadata_filter)
[![Test Coverage](https://codeclimate.com/github/fabric8io/fluent-plugin-kubernetes_metadata_filter/badges/coverage.svg)](https://codeclimate.com/github/fabric8io/fluent-plugin-kubernetes_metadata_filter)

## Installation

    gem install fluent-plugin-kubernetes_metadata_filter

## Configuration

Configuration options for fluent.conf are:

* `kubernetes_url` - URL to the API server. Set this to retrieve further kubernetes metadata for logs from kubernetes API server
* `apiVersion` - API version to use (default: `v1`)
* `ca_file` - path to CA file for Kubernetes server certificate validation
* `verify_ssl` - validate SSL certificates (default: `true`)
* `client_cert` - path to a client cert file to authenticate to the API server
* `client_key` - path to a client key file to authenticate to the API server
* `bearer_token_file` - path to a file containing the bearer token to use for authentication
* `tag_to_kubernetes_name_regexp` - the regular expression used to extract kubernetes metadata (pod name, container name, namespace) from the current fluentd tag.
This must used named capture groups for `container_name`, `pod_name` & `namespace` (default: `\.(?<pod_name>[^\._]+)_(?<namespace>[^_]+)_(?<container_name>.+)-(?<docker_id>[a-z0-9]{64})\.log$</pod>)`)
* `cache_size` - size of the cache of Kubernetes metadata to reduce requests to the API server (default: `1000`)
* `cache_ttl` - TTL in seconds of each cached element. Set to negative value to disable TTL eviction (default: `3600` - 1 hour)
* `watch` - set up a watch on pods on the API server for updates to metadata (default: `true`)
* `merge_json_log` - merge logs in JSON format as top level keys (default: `true`)
* `de_dot` - replace dots in labels with configured `de_dot_separator`, required for ElasticSearch 2.x compatibility (default: `true`)
* `de_dot_separator` - separator to use if `de_dot` is enabled (default: `_`)

```
<source>
  type tail
  path /var/log/containers/*.log
  pos_file fluentd-docker.pos
  time_format %Y-%m-%dT%H:%M:%S
  tag kubernetes.*
  format json
  read_from_head true
</source>

<filter kubernetes.var.lib.docker.containers.*.*.log>
  type kubernetes_metadata
</filter>

<match **>
  type stdout
</match>
```

## Example input/output

Kubernetes creates symlinks to Docker log files in `/var/log/containers/*.log`. Docker logs in JSON format.

Assuming following inputs are coming from a log file:

```
{
  "log": "2015/05/05 19:54:41 \n",
  "stream": "stderr",
  "time": "2015-05-05T19:54:41.240447294Z"
}
```

Then output becomes as belows
```
{
  "log": "2015/05/05 19:54:41 \n",
  "stream": "stderr",
  "docker": {
    "id": "df14e0d5ae4c07284fa636d739c8fc2e6b52bc344658de7d3f08c36a2e804115",
  }
  "kubernetes": {
    "host": "jimmi-redhat.localnet",
    "pod_name":"fabric8-console-controller-98rqc",
    "container_name": "fabric8-console-container",
    "namespace": "default",
    "uid": "c76927af-f563-11e4-b32d-54ee7527188d",
    "labels": {
      "component": "fabric8Console"
    }
  }
}
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## Copyright
  Copyright (c) 2015 jimmidyson
