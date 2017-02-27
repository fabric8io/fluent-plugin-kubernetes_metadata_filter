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
* `preserve_json_log` - preserve JSON logs in raw form in the `log` key, only used if the previous option is true (default: `true`)
* `de_dot` - replace dots in labels with configured `de_dot_separator`, required for ElasticSearch 2.x compatibility (default: `true`)
* `de_dot_separator` - separator to use if `de_dot` is enabled (default: `_`)
* `use_journal` - If false (default), messages are expected to be formatted and tagged as if read by the fluentd in\_tail plugin with wildcard filename.  If true, messages are expected to be formatted as if read from the systemd journal.  The `MESSAGE` field has the full message.  The `CONTAINER_NAME` field has the encoded k8s metadata (see below).  The `CONTAINER_ID_FULL` field has the full container uuid.  This requires docker to use the `--log-driver=journald` log driver.
* `container_name_to_kubernetes_regexp` - The regular expression used to extract the k8s metadata encoded in the journal `CONTAINER_NAME` field (default: `'^k8s_(?<container_name>[^\.]+)\.(?<container_hash>[a-z0-9]{8})_(?<pod_name>[^_]+)_(?<namespace>[^_]+)_(?<pod_id>[^_]+)_(?<pod_randhex>[a-z0-9]{8})$'`)
* `annotation_match` - Array of regular expressions matching annotation field names. Matched annotations are added to a log record.

Reading from the JSON formatted log files with `in_tail` and wildcard filenames:
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

<filter kubernetes.var.log.containers.**.log>
  type kubernetes_metadata
</filter>

<match **>
  type stdout
</match>
```

Reading from the systemd journal (requires the fluentd `fluent-plugin-systemd` and `systemd-journal` plugins, and requires docker to use the `--log-driver=journald` log driver):
```
<source>
  type systemd
  path /run/log/journal
  pos_file journal.pos
  tag journal
  read_from_head true
</source>

# probably want to use something like fluent-plugin-rewrite-tag-filter to
# retag entries from k8s
<match journal>
  @type rewrite_tag_filter
  rewriterule1 CONTAINER_NAME ^k8s_ kubernetes.journal.container
  ...
</match>

<filter kubernetes.**>
  type kubernetes_metadata
  use_journal true
</filter>

<match **>
  type stdout
</match>
```

## Example input/output

Kubernetes creates symlinks to Docker log files in `/var/log/containers/*.log`. Docker logs in JSON format.

Assuming following inputs are coming from a log file named `/var/log/containers/fabric8-console-controller-98rqc_default_fabric8-console-container-df14e0d5ae4c07284fa636d739c8fc2e6b52bc344658de7d3f08c36a2e804115.log`:

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
    "pod_id": "c76927af-f563-11e4-b32d-54ee7527188d",
    "container_name": "fabric8-console-container",
    "namespace_name": "default",
    "namespace_id": "23437884-8e08-4d95-850b-e94378c9b2fd",
    "labels": {
      "component": "fabric8Console"
    }
  }
}
```

If using journal input, from docker configured with `--log-driver=journald`, the input looks like the `journalctl -o export` format:
```
# The stream identification is encoded into the PRIORITY field as an
# integer: 6, or github.com/coreos/go-systemd/journal.Info, marks stdout,
# while 3, or github.com/coreos/go-systemd/journal.Err, marks stderr.
PRIORITY=6
CONTAINER_ID=b6cbb6e73c0a
CONTAINER_ID_FULL=b6cbb6e73c0ad63ab820e4baa97cdc77cec729930e38a714826764ac0491341a
CONTAINER_NAME=k8s_registry.a49f5318_docker-registry-1-hhoj0_default_ae3a9bdc-1f66-11e6-80a2-fa163e2fff3a_799e4035
MESSAGE=172.17.0.1 - - [21/May/2016:16:52:05 +0000] "GET /healthz HTTP/1.1" 200 0 "" "Go-http-client/1.1"
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Test it (`GEM_HOME=vendor bundle install; GEM_HOME=vendor bundle exec rake test`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create new Pull Request

## Copyright
  Copyright (c) 2015 jimmidyson
